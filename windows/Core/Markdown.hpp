#pragma once
#include <cstddef>
#include <string>
#include <string_view>
#include <vector>

namespace ssmv {
enum class BlockKind { Paragraph, Heading, Code, UnorderedListItem, OrderedListItem, Quote, Rule };
struct Block {
    BlockKind kind;
    std::string text;
    int level = 0;
    std::size_t line = 0;
    unsigned startNumber = 1;
};
struct Heading { std::string text; int level; std::size_t blockIndex; };
struct MarkdownDocument { std::vector<Block> blocks; std::vector<Heading> headings; };
MarkdownDocument parseMarkdown(std::string_view source);
}
