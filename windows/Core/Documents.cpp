#include "Documents.hpp"
#include <algorithm>
#include <cctype>
#include <fstream>
#include <stdexcept>

namespace ssmv {
bool validUTF8(std::string_view text) {
    for (std::size_t i = 0; i < text.size();) {
        auto byte = static_cast<unsigned char>(text[i++]);
        if (byte < 0x80) { if (byte == 0) return false; continue; }
        unsigned count = 0, value = 0, minimum = 0;
        if (byte >= 0xc2 && byte <= 0xdf) { count = 1; value = byte & 0x1f; minimum = 0x80; }
        else if (byte >= 0xe0 && byte <= 0xef) { count = 2; value = byte & 0x0f; minimum = 0x800; }
        else if (byte >= 0xf0 && byte <= 0xf4) { count = 3; value = byte & 7; minimum = 0x10000; }
        else return false;
        if (text.size() - i < count) return false;
        while (count--) { byte = static_cast<unsigned char>(text[i++]); if ((byte & 0xc0) != 0x80) return false; value = (value << 6) | (byte & 0x3f); }
        if (value < minimum || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) return false;
    }
    return true;
}
namespace {
std::string pathText(const std::filesystem::path& path) {
    const auto bytes = path.u8string();
    return std::string(reinterpret_cast<const char*>(bytes.data()), bytes.size());
}
std::string lower(std::string value) {
    for (char& c : value) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return value;
}
std::filesystem::path documentPath(const std::filesystem::path& path) {
    const auto extension = lower(pathText(path.extension()));
    if (extension != ".md" && extension != ".markdown" && extension != ".mdown") throw std::runtime_error("Choose a Markdown file (.md, .markdown, or .mdown).");
    auto canonical = std::filesystem::canonical(path);
    if (!std::filesystem::is_regular_file(canonical)) throw std::runtime_error("The selected item is not a regular file.");
    return canonical;
}
}
Document readDocument(const std::filesystem::path& path) {
    Document document;
    document.path = documentPath(path);
    if (std::filesystem::file_size(document.path) > MaxDocumentBytes) throw std::runtime_error("Markdown files must be 16 MiB or smaller.");
    std::ifstream stream(document.path, std::ios::binary);
    if (!stream) throw std::runtime_error("The document could not be opened.");
    char buffer[65536];
    while (stream) {
        stream.read(buffer, sizeof buffer);
        const auto count = static_cast<std::size_t>(stream.gcount());
        if (document.source.size() + count > MaxDocumentBytes) throw std::runtime_error("Markdown files must be 16 MiB or smaller.");
        document.source.append(buffer, count);
    }
    if (!stream.eof()) throw std::runtime_error("The document could not be read completely.");
    if (!validUTF8(document.source)) throw std::runtime_error("The document must contain valid UTF-8 text without null bytes.");
    std::string_view text = document.source;
    if (text.starts_with("\xef\xbb\xbf")) text.remove_prefix(3);
    document.markdown = parseMarkdown(text);
    return document;
}
std::size_t DocumentLibrary::open(const std::filesystem::path& path) {
    const auto canonical = documentPath(path);
    for (std::size_t i = 0; i < documents_.size(); ++i) {
        std::error_code error;
        if (documents_[i].path == canonical || std::filesystem::equivalent(documents_[i].path, canonical, error)) return i;
    }
    return insert(readDocument(canonical));
}
std::size_t DocumentLibrary::insert(Document document) {
    for (std::size_t i = 0; i < documents_.size(); ++i) {
        std::error_code error;
        if (documents_[i].path == document.path || std::filesystem::equivalent(documents_[i].path, document.path, error)) return i;
    }
    documents_.push_back(std::move(document));
    return documents_.size() - 1;
}
void DocumentLibrary::replace(std::size_t index, Document document) {
    if (index >= documents_.size() || documents_[index].path != document.path) throw std::invalid_argument("Reload must preserve document identity.");
    documents_[index] = std::move(document);
}
void DocumentLibrary::remove(std::size_t index) {
    if (index >= documents_.size()) throw std::out_of_range("Document index is out of range.");
    documents_.erase(documents_.begin() + static_cast<std::ptrdiff_t>(index));
}
void DocumentLibrary::sortByName(bool ascending) {
    std::stable_sort(documents_.begin(), documents_.end(), [ascending](const auto& a, const auto& b) {
        const auto left = lower(pathText(a.path.filename())), right = lower(pathText(b.path.filename()));
        return ascending ? left < right : left > right;
    });
}
}
