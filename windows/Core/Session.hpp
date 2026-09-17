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
struct SessionDocument {
    std::string path;
    std::uint32_t bodyPage = 0;
    double scrollOffset = 0;
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
