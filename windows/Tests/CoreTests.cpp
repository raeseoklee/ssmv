#include "Documents.hpp"
#include <chrono>
#include <fstream>
#include <iostream>
#include <stdexcept>

using namespace ssmv;
namespace fs = std::filesystem;
void check(bool condition, const char* message) { if (!condition) throw std::runtime_error(message); }
template<class F> void rejects(F fn) { bool rejected = false; try { fn(); } catch (const std::exception&) { rejected = true; } check(rejected, "Expected rejection"); }
void write(const fs::path& path, std::string_view source) { std::ofstream stream(path, std::ios::binary); stream.write(source.data(), static_cast<std::streamsize>(source.size())); }
int main() {
    const auto directory = fs::temp_directory_path() / ("ssmv-core-tests-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    fs::create_directories(directory);
    try {
        const auto parsed = parseMarkdown("# Title\r\n\r\nFirst line\nsecond line\n\n```md\n# Hidden\n~~~\n```\n## Child ##\n- bullet\n2. numbered\n> quote\n---\n<script>alert(1)</script>\n");
        check(parsed.headings.size() == 2, "Fenced headings must not enter outline");
        check(parsed.headings[1].text == "Child" && parsed.headings[1].level == 2, "Heading closing markers");
        check(parsed.blocks[1].text == "First line\nsecond line", "Paragraph preservation");
        check(parsed.blocks[2].kind == BlockKind::Code && parsed.blocks[2].text == "# Hidden\n~~~\n", "Fence boundaries");
        check(parsed.blocks[4].kind == BlockKind::UnorderedListItem, "Bullet list");
        check(parsed.blocks[5].kind == BlockKind::OrderedListItem, "Ordered list");
        check(parsed.blocks[6].kind == BlockKind::Quote, "Quote");
        check(parsed.blocks[7].kind == BlockKind::Rule, "Rule");
        check(parsed.blocks.back().text == "<script>alert(1)</script>", "HTML must remain plain text");
        check(parseMarkdown("````\n# code\n```\n").headings.empty(), "Short closing fence is not a close");
        check(parseMarkdown("####### plain\n#nospace\n").headings.empty(), "Invalid headings remain plain");
        check(parseMarkdown("").blocks.empty(), "Empty document");
        check(parseMarkdown("42. item").blocks[0].startNumber == 42, "Ordered list start is preserved");
        check(parseMarkdown("# ###").headings[0].text.empty(), "Closing-only heading is empty");
        const auto a = directory / "A.md", b = directory / "b.MARKDOWN", c = directory / fs::path(u8"문서.mdown");
        const std::string original = "\xef\xbb\xbf# Heading\nsource stays untouched\n";
        write(a, original); write(b, "# B"); write(c, "# 한국어 😀");
        DocumentLibrary library;
        check(library.open(b) == 0 && library.open(a) == 1 && library.open(c) == 2, "Insertion ordering");
        check(library.open(directory / "." / "A.md") == 1 && library.documents().size() == 3, "Canonical deduplication");
        check(library.documents()[1].source == original && library.documents()[1].markdown.headings[0].text == "Heading", "BOM source preserved, parsing strips BOM");
        for (int i = 0; i < 5; ++i) {
            check(library.open(a) == 1 && library.open(b) == 0 && library.open(c) == 2, "Repeated opens preserve insertion indices");
            (void)library.documents()[1].markdown.headings; check(library.documents()[0].path == fs::canonical(b), "Outline access must preserve order"); }
        library.sortByName(); check(library.documents()[0].path == fs::canonical(a), "Explicit ascending sort");
        library.sortByName(false); check(library.documents().back().path == fs::canonical(a), "Descending sort");
        library.remove(0); library.clear();
        check(fs::exists(a) && fs::exists(b) && fs::exists(c), "Library removal must not delete source");
        check(readDocument(a).source == original, "Source bytes must remain unchanged");
        rejects([&] { library.remove(0); });
        write(directory / "bad.md", std::string("\xc0\xaf", 2)); rejects([&] { readDocument(directory / "bad.md"); });
        write(directory / "bad.md", std::string("\xed\xa0\x80", 3)); rejects([&] { readDocument(directory / "bad.md"); });
        write(directory / "bad.md", std::string("\xf4\x90\x80\x80", 4)); rejects([&] { readDocument(directory / "bad.md"); });
        write(directory / "bad.md", std::string("a\0b", 3)); rejects([&] { readDocument(directory / "bad.md"); });
        write(directory / "bad.md", std::string("\xe2\x82", 2)); rejects([&] { readDocument(directory / "bad.md"); });
        write(directory / "limit.md", std::string(MaxDocumentBytes, 'x')); check(readDocument(directory / "limit.md").source.size() == MaxDocumentBytes, "Exact size limit accepted");
        write(directory / "large.md", std::string(MaxDocumentBytes + 1, 'x')); rejects([&] { readDocument(directory / "large.md"); });
        rejects([&] { readDocument(directory / "missing.md"); });
        write(directory / "plain.txt", "text"); rejects([&] { readDocument(directory / "plain.txt"); });
        fs::create_directory(directory / "folder.md"); rejects([&] { readDocument(directory / "folder.md"); });
        library.insert(readDocument(a)); library.insert(readDocument(a)); check(library.documents().size() == 1, "Background insert deduplication");
        fs::remove_all(directory);
        std::cout << "SSMV core tests passed\n";
        return 0;
    } catch (const std::exception& error) {
        fs::remove_all(directory);
        std::cerr << error.what() << '\n';
        return 1;
    }
}
