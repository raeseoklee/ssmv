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
MarkdownDocument parseMarkdown(std::string_view source) {
    MarkdownDocument result;
    std::string paragraph, code;
    std::size_t paragraphLine = 0, codeLine = 0, lineNumber = 0, fenceLength = 0;
    char fence = 0;
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
        const auto indent = raw.find_first_not_of(' ');
        const bool blockIndent = indent == std::string_view::npos || indent <= 3;
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
        if (line.empty()) { flushParagraph(); continue; }
        const auto hashes = run(line, '#');
        if (blockIndent && hashes >= 1 && hashes <= 6 && (hashes == line.size() || space(line[hashes]))) {
            flushParagraph(); auto title = trim(line.substr(hashes));
            const auto last = title.find_last_not_of('#');
            if (last == std::string_view::npos) title = {};
            else if (last + 1 < title.size() && space(title[last])) title = trim(title.substr(0, last));
            const auto index = result.blocks.size();
            result.blocks.push_back({BlockKind::Heading, std::string(title), static_cast<int>(hashes), lineNumber});
            result.headings.push_back({std::string(title), static_cast<int>(hashes), index}); continue;
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
            flushParagraph(); result.blocks.push_back({BlockKind::UnorderedListItem, std::string(trim(line.substr(2))), 0, lineNumber}); continue;
        }
        std::size_t digits = 0;
        while (digits < line.size() && digits < 9 && line[digits] >= '0' && line[digits] <= '9') ++digits;
        if (digits && digits + 1 < line.size() && (line[digits] == '.' || line[digits] == ')') && space(line[digits + 1])) {
            unsigned number = 0;
            for (std::size_t i = 0; i < digits; ++i) number = number * 10 + static_cast<unsigned>(line[i] - '0');
            flushParagraph(); result.blocks.push_back({BlockKind::OrderedListItem, std::string(trim(line.substr(digits + 2))), 0, lineNumber, number}); continue;
        }
        if (paragraph.empty()) paragraphLine = lineNumber; else paragraph.push_back('\n');
        paragraph.append(raw);
    }
    flushParagraph();
    if (fence) result.blocks.push_back({BlockKind::Code, std::move(code), 0, codeLine});
    return result;
}
}
