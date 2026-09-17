#include "Markdown.hpp"
#include <algorithm>
#include <cctype>

namespace ssmv {
namespace {
std::string_view trim(std::string_view value) {
    while (!value.empty() && (value.front() == ' ' || value.front() == '\t')) value.remove_prefix(1);
    while (!value.empty() && (value.back() == ' ' || value.back() == '\t')) value.remove_suffix(1);
    return value;
}
std::size_t run(std::string_view line, char character) {
    std::size_t count = 0;
    while (count < line.size() && line[count] == character) ++count;
    return count;
}
bool space(char c) { return c == ' ' || c == '\t'; }
}
LinkKind classifyLink(std::string_view destination) {
    if (destination.empty()) return LinkKind::Unsafe;
    for (unsigned char c : destination) if (c <= 32 || c == 127 || c == '\\') return LinkKind::Unsafe;
    if (destination.front() == '#') return LinkKind::Anchor;
    if (destination.front() == '/' || destination.front() == '%') return LinkKind::Unsafe;
    const auto colon = destination.find(':');
    const auto slash = destination.find('/');
    if (colon != std::string_view::npos && (slash == std::string_view::npos || colon < slash)) {
        std::string scheme(destination.substr(0, colon));
        for (char& c : scheme) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
        if ((scheme == "https" || scheme == "http") && destination.substr(colon + 1, 2) == "//" && destination.size() > colon + 3) return LinkKind::Web;
        if (scheme == "mailto" && destination.size() > colon + 1) return LinkKind::Email;
        return LinkKind::Unsafe;
    }
    return LinkKind::Relative;
}
namespace {
// Every search shares a linear budget; malformed delimiters cannot cause quadratic work.
struct InlineParser {
    std::vector<InlineSpan> spans;
    std::size_t budget;
    void append(std::string_view text, const InlineSpan& style) {
        if (text.empty()) return;
        if (!spans.empty()) {
            auto& last = spans.back();
            if (last.bold == style.bold && last.italic == style.italic && last.strikethrough == style.strikethrough && last.code == style.code && last.destination == style.destination) { last.text.append(text); return; }
        }
        spans.push_back(style); spans.back().text = text;
    }
    std::size_t find(std::string_view source, std::string_view token, std::size_t start) {
        for (auto i = start; i + token.size() <= source.size() && budget; ++i) {
            --budget;
            if (source[i] == '\\' && i + 1 < source.size()) { ++i; continue; }
            if (source.substr(i, token.size()) == token) return i;
        }
        return std::string_view::npos;
    }
    std::size_t findMarker(std::string_view source, char marker, std::size_t count, std::size_t start) {
        for (auto i = start; i < source.size() && budget;) {
            --budget;
            if (source[i] == '\\' && marker != '`' && i + 1 < source.size()) { i += 2; continue; }
            if (source[i] != marker) { ++i; continue; }
            const auto length = run(source.substr(i), marker);
            budget -= std::min(budget, length - 1);
            if (length == count) return i;
            i += length;
        }
        return std::string_view::npos;
    }
    void parse(std::string_view source, InlineSpan style = {}, unsigned depth = 0) {
        if (depth >= 16 || !budget) { append(source, style); return; }
        for (std::size_t i = 0; i < source.size();) {
            if (!budget) { append(source.substr(i), style); break; }
            --budget;
            const char c = source[i];
            if (c == '\\' && i + 1 < source.size() && std::ispunct(static_cast<unsigned char>(source[i + 1]))) { append(source.substr(i + 1, 1), style); i += 2; continue; }
            if (c == '`') {
                auto length = run(source.substr(i), '`');
                auto end = findMarker(source, c, length, i + length);
                if (end != std::string_view::npos) {
                    auto code = style; code.code = true;
                    std::string content(source.substr(i + length, end - i - length));
                    std::replace(content.begin(), content.end(), '\n', ' ');
                    if (content.size() >= 2 && content.front() == ' ' && content.back() == ' ' && content.find_first_not_of(' ') != std::string::npos) content = content.substr(1, content.size() - 2);
                    append(content, code); i = end + length; continue;
                }
                append(source.substr(i, length), style); i += length; continue;
            }
            if (c == '[' && style.destination.empty()) {
                const auto labelEnd = find(source, "](", i + 1);
                if (labelEnd != std::string_view::npos) {
                    auto end = labelEnd + 2; unsigned nesting = 1;
                    while (end < source.size() && budget && nesting) {
                        --budget;
                        if (source[end] == '(') ++nesting;
                        else if (source[end] == ')') --nesting;
                        if (nesting) ++end;
                    }
                    if (!nesting) {
                        auto target = trim(source.substr(labelEnd + 2, end - labelEnd - 2));
                        if (target.size() > 2 && target.front() == '<' && target.back() == '>') target = target.substr(1, target.size() - 2);
                        auto link = style;
                        if (classifyLink(target) != LinkKind::Unsafe) link.destination = target;
                        parse(source.substr(i + 1, labelEnd - i - 1), link, depth + 1); i = end + 1; continue;
                    }
                }
            }
            if (c == '*' || c == '_' || (c == '~' && i + 1 < source.size() && source[i + 1] == '~')) {
                const auto markerRun = run(source.substr(i), c);
                auto count = std::min<std::size_t>(markerRun, c == '~' ? 2 : 3);
                const bool innerUnderscore = c == '_' && i && std::isalnum(static_cast<unsigned char>(source[i - 1]));
                if (!innerUnderscore && i + count < source.size() && !std::isspace(static_cast<unsigned char>(source[i + count]))) {
                    const auto end = findMarker(source, c, count, i + count);
                    if (end != std::string_view::npos && end > i + count && !std::isspace(static_cast<unsigned char>(source[end - 1]))) {
                        auto emphasis = style;
                        if (c == '~') emphasis.strikethrough = true;
                        else { if (count >= 2) emphasis.bold = true; if (count == 1 || count == 3) emphasis.italic = true; }
                        parse(source.substr(i + count, end - i - count), emphasis, depth + 1); i = end + count; continue;
                    }
                }
                append(source.substr(i, markerRun), style); i += markerRun; continue;
            }
            append(source.substr(i, 1), style); ++i;
        }
    }
};
std::vector<std::string> tableCells(std::string_view line) {
    line = trim(line);
    if (!line.empty() && line.front() == '|') line.remove_prefix(1);
    if (!line.empty() && line.back() == '|' && (line.size() < 2 || line[line.size() - 2] != '\\')) line.remove_suffix(1);
    std::vector<std::string> cells;
    std::size_t start = 0, codeRun = 0;
    for (std::size_t i = 0; i < line.size(); ++i) {
        if (line[i] == '\\' && i + 1 < line.size()) { ++i; continue; }
        if (line[i] == '`') { const auto length = run(line.substr(i), '`'); if (!codeRun) codeRun = length; else if (codeRun == length) codeRun = 0; i += length - 1; continue; }
        if (line[i] == '|' && !codeRun) { cells.emplace_back(trim(line.substr(start, i - start))); start = i + 1; }
    }
    cells.emplace_back(trim(line.substr(start))); return cells;
}
std::vector<TableAlignment> tableSeparator(std::string_view line) {
    if (line.find('|') == std::string_view::npos) return {};
    std::vector<TableAlignment> result;
    for (const auto& cell : tableCells(line)) {
        auto value = std::string_view(cell);
        const bool left = !value.empty() && value.front() == ':', right = !value.empty() && value.back() == ':';
        if (left) value.remove_prefix(1);
        if (right && !value.empty()) value.remove_suffix(1);
        if (value.size() < 3 || value.find_first_not_of('-') != std::string_view::npos) return {};
        result.push_back(left && right ? TableAlignment::Center : right ? TableAlignment::Right : TableAlignment::Left);
    }
    return result;
}
}
std::vector<InlineSpan> parseInline(std::string_view source) {
    InlineParser parser{{}, source.size() * 24 + 1}; parser.parse(source); return std::move(parser.spans);
}
std::string plainInlineText(std::string_view source) {
    std::string text; for (const auto& span : parseInline(source)) text += span.text; return text;
}

MarkdownDocument parseMarkdown(std::string_view source) {
    MarkdownDocument result;
    std::string paragraph, code;
    std::size_t paragraphLine = 0, codeLine = 0, lineNumber = 0, fenceLength = 0;
    char fence = 0;
    bool tableActive = false;
    auto flushParagraph = [&] {
        if (!paragraph.empty()) result.blocks.push_back({BlockKind::Paragraph, std::move(paragraph), 0, paragraphLine});
        paragraph.clear();
    };
    while (!source.empty()) {
        ++lineNumber;
        const auto end = source.find('\n');
        auto raw = source.substr(0, end);
        if (!raw.empty() && raw.back() == '\r') raw.remove_suffix(1);
        if (end == std::string_view::npos) source = {}; else source.remove_prefix(end + 1);
        auto line = trim(raw);
        std::size_t indent = 0;
        for (char c : raw) { if (c == ' ') ++indent; else if (c == '\t') indent += 4 - indent % 4; else break; }
        const bool blockIndent = indent <= 3;
        if (fence) {
            if (blockIndent && run(line, fence) >= fenceLength && trim(line.substr(run(line, fence))).empty()) {
                result.blocks.push_back({BlockKind::Code, std::move(code), 0, codeLine});
                code.clear(); fence = 0;
            } else { code.append(raw); code.push_back('\n'); }
            continue;
        }
        if (blockIndent && !line.empty() && (line.front() == '`' || line.front() == '~') && run(line, line.front()) >= 3) {
            const auto length = run(line, line.front());
            if (line.front() != '`' || line.substr(length).find('`') == std::string_view::npos) {
                flushParagraph(); fence = line.front(); fenceLength = length; codeLine = lineNumber; continue;
            }
        }
        if (line.empty()) { flushParagraph(); tableActive = false; continue; }
        if (!paragraph.empty() && blockIndent && (line.front() == '=' || line.front() == '-') && line.find_first_not_of(line.front()) == std::string_view::npos) {
            const int level = line.front() == '=' ? 1 : 2;
            const auto index = result.blocks.size();
            result.headings.push_back({plainInlineText(paragraph), level, index});
            result.blocks.push_back({BlockKind::Heading, std::move(paragraph), level, paragraphLine});
            paragraph.clear(); continue;
        }
        if (!paragraph.empty() && paragraph.find('\n') == std::string::npos && paragraph.find('|') != std::string::npos) {
            auto alignments = tableSeparator(line);
            auto header = tableCells(paragraph);
            if (!alignments.empty() && alignments.size() == header.size()) {
                Block table{BlockKind::Table, paragraph, 0, paragraphLine};
                table.tableRows.push_back(std::move(header)); table.alignments = std::move(alignments);
                paragraph.clear(); result.blocks.push_back(std::move(table)); tableActive = true; continue;
            }
        }
        if (tableActive && paragraph.empty() && !result.blocks.empty() && result.blocks.back().kind == BlockKind::Table && line.find('|') != std::string_view::npos) {
            auto cells = tableCells(line); cells.resize(result.blocks.back().alignments.size());
            result.blocks.back().tableRows.push_back(std::move(cells)); continue;
        }
        tableActive = false;
        const auto hashes = run(line, '#');
        if (blockIndent && hashes >= 1 && hashes <= 6 && (hashes == line.size() || space(line[hashes]))) {
            flushParagraph(); auto title = trim(line.substr(hashes));
            const auto last = title.find_last_not_of('#');
            if (last == std::string_view::npos) title = {};
            else if (last + 1 < title.size() && space(title[last])) title = trim(title.substr(0, last));
            const auto index = result.blocks.size();
            result.blocks.push_back({BlockKind::Heading, std::string(title), static_cast<int>(hashes), lineNumber});
            result.headings.push_back({plainInlineText(title), static_cast<int>(hashes), index}); continue;
        }
        bool rule = blockIndent && (line.front() == '-' || line.front() == '*' || line.front() == '_');
        std::size_t marks = 0;
        if (rule) for (char c : line) { if (c == line.front()) ++marks; else if (!space(c)) rule = false; }
        if (rule && marks >= 3) { flushParagraph(); result.blocks.push_back({BlockKind::Rule, {}, 0, lineNumber}); continue; }
        if (blockIndent && line.front() == '>') {
            flushParagraph(); line.remove_prefix(1); if (!line.empty() && space(line.front())) line.remove_prefix(1);
            result.blocks.push_back({BlockKind::Quote, std::string(line), 0, lineNumber}); continue;
        }
        if (line.size() >= 2 && (line[0] == '-' || line[0] == '+' || line[0] == '*') && space(line[1])) {
            flushParagraph(); result.blocks.push_back({BlockKind::UnorderedListItem, std::string(trim(line.substr(2))), 0, lineNumber, 1, indent}); continue;
        }
        std::size_t digits = 0;
        while (digits < line.size() && digits < 9 && line[digits] >= '0' && line[digits] <= '9') ++digits;
        if (digits && digits + 1 < line.size() && (line[digits] == '.' || line[digits] == ')') && space(line[digits + 1])) {
            unsigned number = 0;
            for (std::size_t i = 0; i < digits; ++i) number = number * 10 + static_cast<unsigned>(line[i] - '0');
            flushParagraph(); result.blocks.push_back({BlockKind::OrderedListItem, std::string(trim(line.substr(digits + 2))), 0, lineNumber, number, indent}); continue;
        }
        if (paragraph.empty()) paragraphLine = lineNumber; else paragraph.push_back('\n');
        paragraph.append(raw);
    }
    flushParagraph();
    if (fence) result.blocks.push_back({BlockKind::Code, std::move(code), 0, codeLine});
    return result;
}
}
