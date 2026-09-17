#include "Session.hpp"
#include "Documents.hpp"
#include <atomic>
#include <bit>
#include <chrono>
#include <cmath>
#include <fstream>
#include <stdexcept>
#include <unordered_set>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <fcntl.h>
#include <unistd.h>
#endif

namespace ssmv {
namespace {
constexpr std::string_view Magic = "SSMVSES1";
[[noreturn]] void invalid() { throw std::runtime_error("The saved session is invalid or unsupported; it has not been overwritten."); }
void validate(const Session& value) {
    if (value.documents.size() > MaxSessionDocuments || value.expandedPaths.size() > MaxSessionDocuments || value.theme > 2 ||
        !std::isfinite(value.fontSize) || value.fontSize < 8 || value.fontSize > 72) invalid();
    std::unordered_set<std::string> paths;
    for (const auto& item : value.documents) {
        if (item.path.empty() || item.path.size() > 32768 || !validUTF8(item.path) || !paths.insert(item.path).second ||
            !std::isfinite(item.scrollOffset) || item.scrollOffset < 0 || item.scrollOffset > 1e12) invalid();
    }
    if (!value.selectedPath.empty() && !paths.contains(value.selectedPath)) invalid();
    std::unordered_set<std::string> expanded;
    for (const auto& path : value.expandedPaths) if (!paths.contains(path) || !expanded.insert(path).second) invalid();
}
void number(std::string& out, std::uint64_t value, unsigned size) {
    for (unsigned i = 0; i < size; ++i) out.push_back(static_cast<char>((value >> (i * 8)) & 255));
}
void text(std::string& out, const std::string& value) {
    number(out, value.size(), 4); out += value;
    if (out.size() > MaxSessionBytes) invalid();
}
struct Reader {
    std::string_view bytes;
    std::uint64_t number(unsigned size) {
        if (bytes.size() < size) invalid();
        std::uint64_t value = 0;
        for (unsigned i = 0; i < size; ++i) value |= static_cast<std::uint64_t>(static_cast<unsigned char>(bytes[i])) << (i * 8);
        bytes.remove_prefix(size); return value;
    }
    std::string text() {
        const auto size = number(4);
        if (size > 32768 || size > bytes.size()) invalid();
        std::string value(bytes.substr(0, static_cast<std::size_t>(size)));
        bytes.remove_prefix(static_cast<std::size_t>(size)); return value;
    }
    bool boolean() { const auto value = number(1); if (value > 1) invalid(); return value != 0; }
};
}
std::string serializeSession(const Session& value) {
    validate(value);
    std::string out(Magic);
    number(out, value.theme, 4); number(out, std::bit_cast<std::uint64_t>(value.fontSize), 8);
    number(out, value.outlineEnabled, 1); number(out, value.sidebarVisible, 1);
    text(out, value.selectedPath); number(out, value.documents.size(), 4);
    for (const auto& item : value.documents) {
        text(out, item.path); number(out, item.bodyPage, 4); number(out, std::bit_cast<std::uint64_t>(item.scrollOffset), 8);
    }
    number(out, value.expandedPaths.size(), 4);
    for (const auto& path : value.expandedPaths) text(out, path);
    if (out.size() > MaxSessionBytes) invalid();
    return out;
}
Session parseSession(std::string_view bytes) {
    if (bytes.size() > MaxSessionBytes || !bytes.starts_with(Magic)) invalid();
    Reader in{bytes.substr(Magic.size())}; Session value;
    value.theme = static_cast<std::uint32_t>(in.number(4)); value.fontSize = std::bit_cast<double>(in.number(8));
    value.outlineEnabled = in.boolean(); value.sidebarVisible = in.boolean(); value.selectedPath = in.text();
    const auto count = in.number(4); if (count > MaxSessionDocuments) invalid();
    for (std::uint64_t i = 0; i < count; ++i) {
        SessionDocument item; item.path = in.text(); item.bodyPage = static_cast<std::uint32_t>(in.number(4));
        item.scrollOffset = std::bit_cast<double>(in.number(8)); value.documents.push_back(std::move(item));
    }
    const auto expanded = in.number(4); if (expanded > MaxSessionDocuments) invalid();
    for (std::uint64_t i = 0; i < expanded; ++i) value.expandedPaths.push_back(in.text());
    if (!in.bytes.empty()) invalid();
    validate(value); return value;
}
std::optional<Session> readSession(const std::filesystem::path& path) {
    std::error_code error;
    const auto status = std::filesystem::symlink_status(path, error);
    if (status.type() == std::filesystem::file_type::not_found) return std::nullopt;
    if (error || !std::filesystem::is_regular_file(status)) throw std::runtime_error("The session file cannot be read safely.");
    if (std::filesystem::file_size(path) > MaxSessionBytes) invalid();
    std::ifstream input(path, std::ios::binary);
    if (!input) throw std::runtime_error("The session file could not be opened.");
    std::string bytes; char buffer[8192];
    while (input) {
        input.read(buffer, sizeof buffer); bytes.append(buffer, static_cast<std::size_t>(input.gcount()));
        if (bytes.size() > MaxSessionBytes) invalid();
    }
    if (!input.eof()) throw std::runtime_error("The session file could not be read completely.");
    return parseSession(bytes);
}
void saveSession(const std::filesystem::path& path, const Session& session) {
    const auto bytes = serializeSession(session);
    (void)readSession(path); // Preserve corrupt stores rather than silently resetting them.
    if (!path.parent_path().empty()) std::filesystem::create_directories(path.parent_path());
    writeFileAtomically(path, bytes);
}
void writeFileAtomically(const std::filesystem::path& path, std::string_view bytes) {
    if (bytes.size() > MaxDocumentBytes) throw std::runtime_error("Files must be 16 MiB or smaller.");
    static std::atomic_uint64_t counter{0};
    auto temporary = path;
    temporary += ".tmp-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()) + "-" + std::to_string(counter++);
#ifdef _WIN32
    HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) throw std::runtime_error("A temporary file could not be created.");
    DWORD written = 0;
    bool ok = WriteFile(file, bytes.data(), static_cast<DWORD>(bytes.size()), &written, nullptr) && written == bytes.size();
    if (ok) ok = FlushFileBuffers(file) != 0;
    if (!CloseHandle(file)) ok = false;
    if (ok) ok = MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
#else
    const int file = ::open(temporary.c_str(), O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (file < 0) throw std::runtime_error("A temporary file could not be created.");
    std::size_t offset = 0; bool ok = true;
    while (offset < bytes.size()) {
        const auto count = ::write(file, bytes.data() + offset, bytes.size() - offset);
        if (count <= 0) { ok = false; break; }
        offset += static_cast<std::size_t>(count);
    }
    if (ok) ok = ::fsync(file) == 0;
    if (::close(file) != 0) ok = false;
    if (ok) ok = ::rename(temporary.c_str(), path.c_str()) == 0;
#endif
    if (!ok) {
        std::error_code ignored; std::filesystem::remove(temporary, ignored);
        throw std::runtime_error("The file could not be saved; the previous file was retained.");
    }
}
}
