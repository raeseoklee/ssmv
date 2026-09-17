#pragma once
#include <cstddef>
#include <string>
#include <string_view>
#include <vector>

namespace ssmv {
enum class BlockKind { Paragraph, Heading, Code, UnorderedListItem, OrderedListItem, Quote, Rule, Table };
enum class TableAlignment { Left, Center, Right };
enum class LinkKind { Unsafe, Web, Email, Anchor, Relative };
struct InlineSpan {
    std::string text;
    bool bold = false, italic = false, strikethrough = false, code = false;
    std::string destination;
};
// Classification is not permission to launch: resolve Relative/Anchor against the
// document source; only explicitly supported external schemes may reach the OS.
LinkKind classifyLink(std::string_view destination);
// Bounded Markdown subset. Unsupported/malformed syntax remains inert text.
std::vector<InlineSpan> parseInline(std::string_view source);
std::string plainInlineText(std::string_view source);
struct Block {
    BlockKind kind;
    std::string text;
    int level = 0;
    std::size_t line = 0;
    unsigned startNumber = 1;
    std::size_t indent = 0; // Leading list indentation in columns (tab stops: four).
    // Table cells retain inline source; the first row is the header.
    std::vector<std::vector<std::string>> tableRows = {};
    std::vector<TableAlignment> alignments = {};
};
struct Heading { std::string text; int level; std::size_t blockIndex; };
struct MarkdownDocument { std::vector<Block> blocks; std::vector<Heading> headings; };
MarkdownDocument parseMarkdown(std::string_view source);
}
