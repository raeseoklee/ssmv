#include "Markdown.hpp"
#include <chrono>
#include <iostream>
#include <stdexcept>
using namespace ssmv;
void check(bool condition, const char* message) { if (!condition) throw std::runtime_error(message); }
int main() {
    try {
        auto inlineText = parseInline("plain **bold** *italic* ~~gone~~ `code` \\*literal\\* [**label**](https://example.com/a_(b))");
        bool bold = false, italic = false, strike = false, code = false, link = false;
        for (const auto& span : inlineText) {
            bold |= span.bold && span.text == "bold"; italic |= span.italic && span.text == "italic";
            strike |= span.strikethrough && span.text == "gone"; code |= span.code && span.text == "code";
            link |= span.bold && span.text == "label" && span.destination == "https://example.com/a_(b)";
        }
        check(bold && italic && strike && code && link, "Inline semantic styles and nested link label");
        check(plainInlineText("a_b_c \\*literal\\* **strong *nested* text**") == "a_b_c *literal* strong nested text", "Escapes and nested emphasis");
        check(plainInlineText("*italic **bold** tail*") == "italic bold tail", "Bold nested in italic");
        check(plainInlineText("`a``b`") == "a``b", "Code closing delimiter requires exact run");
        check(plainInlineText("***both***") == "both" && parseInline("***both***")[0].bold && parseInline("***both***")[0].italic, "Combined emphasis");
        check(plainInlineText("`` `raw` ``") == "`raw`", "Multi-backtick code");
        check(plainInlineText("A source-wrapped paragraph\ncontinues on the same display line.") == "A source-wrapped paragraph continues on the same display line.", "Soft source line breaks reflow");
        check(plainInlineText("one \n  two\n\tthree") == "one two three", "Soft breaks discard surrounding indentation");
        check(plainInlineText("one  \n two\\\n three") == "one\ntwo\nthree", "Spaces and backslash preserve explicit hard breaks");
        check(plainInlineText("one\\\\\ntwo") == "one\\ two", "Escaped backslash does not create a hard break");
        check(plainInlineText("one\\\\\\\ntwo") == "one\\\ntwo", "Unescaped final backslash creates a hard break");
        check(plainInlineText("one\r\ntwo  \r\n three\\\r\nfour") == "one two\nthree\nfour", "CRLF uses the same soft and hard break rules");
        check(plainInlineText("`one\r\ntwo\nthree`") == "one two three", "Code span line endings normalize to single spaces");
        check(plainInlineText("`one  \ntwo\\\nthree`") == "one   two\\ three", "Code spans keep literal spaces and backslashes");
        const auto wrappedStyles = parseInline("**bold\ncontinuation** [linked\nlabel](https://example.com)");
        check(wrappedStyles.front().bold && wrappedStyles.front().text == "bold continuation" && wrappedStyles.back().text == "linked label" && wrappedStyles.back().destination == "https://example.com", "Reflow preserves emphasis and link spans");
        const auto wrappedDocument = parseMarkdown("first line\nsecond line  \nthird line\n\n```\nliteral\n  lines\n```\n");
        check(wrappedDocument.blocks.size() == 2 && wrappedDocument.blocks[0].text == "first line\nsecond line  \nthird line", "Block parser retains paragraph source line breaks");
        check(plainInlineText(wrappedDocument.blocks[0].text) == "first line second line\nthird line", "Paragraph rendering distinguishes soft and hard breaks");
        check(wrappedDocument.blocks[1].kind == BlockKind::Code && wrappedDocument.blocks[1].text == "literal\n  lines\n", "Fenced code remains literal");
        check(plainInlineText("<script>alert(1)</script>") == "<script>alert(1)</script>", "Raw HTML is inert text");
        for (const auto* url : {"javascript:alert(1)", "data:text/html,evil", "file:///etc/passwd", "ms-settings:test", "//evil.test/a", "\\\\server\\file", " https://example.com", "https://a\nb"}) check(classifyLink(url) == LinkKind::Unsafe, "Unsafe scheme/path");
        check(classifyLink("https://example.com") == LinkKind::Web && classifyLink("HTTP://example.com") == LinkKind::Web, "Web URLs");
        check(classifyLink("mailto:a@example.com") == LinkKind::Email && classifyLink("#heading") == LinkKind::Anchor && classifyLink("../other.md") == LinkKind::Relative, "Safe link categories");
        check(parseInline("[label](javascript:alert(1))")[0].destination.empty(), "Unsafe link retains label without activation");
        auto doc = parseMarkdown("# **Bold** [link](https://example.com)\n\nSetext *title*\n===\n\n| Name | Count | Middle |\n| :--- | ---: | :---: |\n| a\\|b | `x|y` | yes |\n\n- root\n  - nested\n    3. deeper\n");
        check(doc.headings.size() == 2 && doc.headings[0].text == "Bold link" && doc.headings[1].text == "Setext title", "Outline plain titles");
        const auto& table = doc.blocks[2];
        check(table.kind == BlockKind::Table && table.tableRows.size() == 2 && table.tableRows[1][0] == "a\\|b" && table.tableRows[1][1] == "`x|y`", "Table escaped/code pipes");
        check(table.alignments[0] == TableAlignment::Left && table.alignments[1] == TableAlignment::Right && table.alignments[2] == TableAlignment::Center, "Table alignment");
        check(doc.blocks[3].indent == 0 && doc.blocks[4].indent == 2 && doc.blocks[5].indent == 4 && doc.blocks[5].startNumber == 3, "Nested list indentation");
        check(parseMarkdown("a | b\n--- | ---\nx | y\n\nz | w").blocks.size() == 2, "Blank ends table");
        check(parseMarkdown("a | b\n--- | --- | ---").blocks[0].kind == BlockKind::Paragraph, "Mismatched table is plain text");
        check(parseMarkdown("Title\n---").blocks[0].kind == BlockKind::Heading, "Setext before thematic break");
        check(parseMarkdown("---").blocks[0].kind == BlockKind::Rule, "Standalone thematic break");
        check(plainInlineText("**unclosed [a](broken") == "**unclosed [a](broken", "Unclosed markup preserved");
        const auto start = std::chrono::steady_clock::now();
        std::string adversarial;
        for (int i = 0; i < 100000; ++i) adversarial += "[x ";
        check(plainInlineText(adversarial) == adversarial, "Adversarial unmatched labels bounded");
        check(plainInlineText(std::string(300000, '*')) == std::string(300000, '*'), "Unmatched delimiter runs bounded");
        check(std::chrono::steady_clock::now() - start < std::chrono::seconds(10), "Linear scan budget");
        const auto longStart = std::chrono::steady_clock::now();
        const std::string longLabel(8 * 1024 * 1024, 'a');
        const std::string longDestination = "https://example.com/" + std::string(8 * 1024 * 1024, 'b');
        auto longSpans = parseInline("[" + longLabel + "](" + longDestination + ")");
        check(longSpans.size() == 1 && longSpans[0].text == longLabel && longSpans[0].destination.empty(), "Oversize destination inert; long label preserved");
        const std::string maxDestination = "https://example.com/" + std::string(MaxInlineLinkBytes - 20, 'c');
        longSpans = parseInline("[" + longLabel + "](" + maxDestination + ")");
        check(longSpans.size() == 1 && longSpans[0].text == longLabel && longSpans[0].destination == maxDestination, "Large literal label merges once");
        std::string escapedLabel;
        for (int i = 0; i < 100000; ++i) escapedLabel += "\\*";
        longSpans = parseInline("[" + escapedLabel + "](" + maxDestination + ")");
        check(longSpans.size() == 1 && longSpans[0].text == std::string(100000, '*'), "Escaped label merges without repeated destination comparison");
        std::string formattedLabel;
        for (int i = 0; i < 10000; ++i) formattedLabel += "**b** plain ";
        auto amplified = "[" + formattedLabel + "](" + maxDestination + ")";
        longSpans = parseInline(amplified);
        check(longSpans.size() == 1 && longSpans[0].text == amplified && longSpans[0].destination.empty(), "Copied link metadata budget falls back to inert source");
        longSpans = parseInline(formattedLabel);
        check(longSpans.size() == 1 && longSpans[0].text == formattedLabel && !longSpans[0].bold, "Span count budget falls back to inert source");
        check(classifyLink(std::string(MaxInlineLinkBytes + 1, 'a')) == LinkKind::Unsafe, "Link length ceiling");
        check(std::chrono::steady_clock::now() - longStart < std::chrono::seconds(10), "Long label and metadata amplification bounded");
        std::cout << "Markdown tests passed\n";
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
