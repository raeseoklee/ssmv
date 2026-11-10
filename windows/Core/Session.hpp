#pragma once
#include <cstdint>
#include <filesystem>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace ssmv {
inline constexpr std::size_t MaxSessionBytes = 1024 * 1024;
inline constexpr std::size_t MaxSessionDocuments = 1024;
using CategoryID = std::uint32_t;
inline constexpr std::size_t MaxCategories = 256;
struct Category {
    CategoryID id = 0, parent = 0;
    std::string name;
    bool expanded = true;
    bool operator==(const Category&) const = default;
};
struct SessionDocument {
    std::string path;
    std::uint32_t bodyPage = 0;
    double scrollOffset = 0;
    CategoryID category = 0;
    bool operator==(const SessionDocument&) const = default;
};
struct Session {
    std::vector<SessionDocument> documents;
    std::string selectedPath;
    std::uint32_t theme = 0; // System, light, dark.
    double fontSize = 16;
    bool outlineEnabled = true;
    bool sidebarVisible = true;
    std::vector<std::string> expandedPaths;
    std::vector<Category> categories;
    CategoryID createCategory(CategoryID parent, std::string name);
    void renameCategory(CategoryID id, std::string name);
    void moveCategory(CategoryID id, CategoryID parent);
    void removeCategory(CategoryID id);
    void moveDocument(std::string const& path, CategoryID category);
    bool canParent(CategoryID id, CategoryID parent) const;
    bool operator==(const Session&) const = default;
};
std::string serializeSession(const Session& session);
Session parseSession(std::string_view bytes);
// Missing returns nullopt. Invalid data and I/O failures throw; callers must
// disable automatic saving until the user explicitly resolves that failure.
std::optional<Session> readSession(const std::filesystem::path& path);
// Refuses to overwrite an invalid existing session. Never touches documents.
void saveSession(const std::filesystem::path& path, const Session& session);
// Writes exactly these bytes to a caller-authorized destination (up to 16 MiB).
// Does not create parent directories or interpret the destination as a session.
void writeFileAtomically(const std::filesystem::path& path, std::string_view bytes);
}
