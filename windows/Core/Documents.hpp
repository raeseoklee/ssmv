#pragma once
#include "Markdown.hpp"
#include <filesystem>

namespace ssmv {
inline constexpr std::size_t MaxDocumentBytes = 16 * 1024 * 1024;
struct Document { std::filesystem::path path; std::string source; MarkdownDocument markdown; };
bool validUTF8(std::string_view text);
Document readDocument(const std::filesystem::path& path);
class DocumentLibrary {
public:
    std::size_t open(const std::filesystem::path& path);
    std::size_t insert(Document document);
    const std::vector<Document>& documents() const noexcept { return documents_; }
    void replace(std::size_t index, Document document);
    void remove(std::size_t index);
    void clear() noexcept { documents_.clear(); }
    void sortByName(bool ascending = true);
private:
    std::vector<Document> documents_;
};
}
