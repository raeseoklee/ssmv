#include "Session.hpp"
#include <chrono>
#include <fstream>
#include <iostream>
#include <limits>
#include <stdexcept>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#endif
using namespace ssmv;
namespace fs = std::filesystem;
namespace {
void check(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
template<class F> void rejects(F fn) {
    bool rejected = false; try { fn(); } catch (const std::exception&) { rejected = true; }
    check(rejected, "Expected invalid session to be rejected");
}
void write(const fs::path& path, const std::string& bytes) {
    std::ofstream out(path, std::ios::binary); out.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
}
std::string read(const fs::path& path) { std::ifstream in(path, std::ios::binary); return {std::istreambuf_iterator<char>(in), {}}; }
}
int main() {
    const auto directory = fs::temp_directory_path() / ("ssmv-session-tests-" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    fs::create_directories(directory);
    try {
        Session session;
        session.documents = {{"C:\\Documents\\한국어 😀.md", 42, 123.25}, {"/tmp/a space\nand newline.md", 1, 0}};
        session.selectedPath = session.documents[1].path;
        session.expandedPaths = {session.documents[0].path};
        session.theme = 2; session.fontSize = 19.5; session.outlineEnabled = false; session.sidebarVisible = false;
        const auto bytes = serializeSession(session);
        check(parseSession(bytes) == session, "Unicode, newline, insertion order and reading positions must roundtrip");
        check(parseSession(serializeSession(Session{})) == Session{}, "Empty session must roundtrip");
        for (std::size_t length = 0; length < bytes.size(); ++length) rejects([&] { parseSession(std::string_view(bytes).substr(0, length)); });
        auto changed = bytes; changed[7] = '2'; rejects([&] { parseSession(changed); });
        rejects([&] { parseSession(bytes + "trailing"); });
        rejects([&] { parseSession(std::string(MaxSessionBytes + 1, 'x')); });
        changed = bytes; changed[20] = 2; rejects([&] { parseSession(changed); });
        auto bad = session; bad.documents[0].path = std::string("bad\0.md", 7); rejects([&] { serializeSession(bad); });
        bad = session; bad.documents[0].path = "\xc0\xaf.md"; rejects([&] { serializeSession(bad); });
        changed = bytes; const auto unicode = changed.find("한국어"); changed[unicode] = '\xff'; rejects([&] { parseSession(changed); });
        bad = session; bad.theme = 3; rejects([&] { serializeSession(bad); });
        bad = session; bad.fontSize = std::numeric_limits<double>::quiet_NaN(); rejects([&] { serializeSession(bad); });
        bad = session; bad.documents[0].scrollOffset = -1; rejects([&] { serializeSession(bad); });
        bad = session; bad.documents[0].scrollOffset = std::numeric_limits<double>::infinity(); rejects([&] { serializeSession(bad); });
        bad = session; bad.selectedPath = "missing.md"; rejects([&] { serializeSession(bad); });
        bad = session; bad.documents.push_back(bad.documents[0]); rejects([&] { serializeSession(bad); });
        bad = session; bad.expandedPaths.push_back("missing.md"); rejects([&] { serializeSession(bad); });
        bad = Session{}; for (std::size_t i = 0; i <= MaxSessionDocuments; ++i) bad.documents.push_back({std::to_string(i) + ".md"});
        rejects([&] { serializeSession(bad); });
        bad.documents.pop_back(); check(parseSession(serializeSession(bad)) == bad, "Maximum document count must roundtrip");
        const auto copy = directory / "source-copy.md";
        const std::string raw = "\xef\xbb\xbf# 원본\r\n\r\nexact bytes\n";
        writeFileAtomically(copy, raw); check(read(copy) == raw, "Atomic document copy preserves BOM and line endings");
        writeFileAtomically(copy, "replacement"); check(read(copy) == "replacement", "Atomic document overwrite");
        rejects([&] { writeFileAtomically(copy, std::string(16 * 1024 * 1024 + 1, 'x')); });
        check(read(copy) == "replacement", "Oversized copy leaves prior file untouched");
        const auto path = directory / "nested" / "session.bin";
        check(!readSession(path), "Missing store must be distinct from corrupt store");
        saveSession(path, session); check(readSession(path) == session, "Disk save and restore");
        auto next = session; next.documents.erase(next.documents.begin()); next.expandedPaths.clear(); next.theme = 1;
        saveSession(path, next); check(readSession(path) == next, "Atomic replacement must update session");
        const auto prior = read(path);
        bad = next; bad.theme = 4; rejects([&] { saveSession(path, bad); });
        check(read(path) == prior, "Rejected save must retain prior store exactly");
        write(path, "corrupt"); rejects([&] { readSession(path); }); rejects([&] { saveSession(path, session); });
        check(read(path) == "corrupt", "Corrupt store must never be silently overwritten");
        fs::remove(path); fs::create_directory(path); rejects([&] { saveSession(path, session); });
        check(fs::is_directory(path), "Save cannot replace a directory"); fs::remove(path);
        saveSession(path, session);
#ifdef _WIN32
        // Readers that deny delete-sharing force MoveFileExW to fail after the
        // temporary file has been written; the old file must remain intact.
        HANDLE locked = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        check(locked != INVALID_HANDLE_VALUE, "Existing session lock");
        bool failed = false; try { saveSession(path, next); } catch (const std::exception&) { failed = true; }
        bool copyFailed = false; try { writeFileAtomically(path, raw); } catch (const std::exception&) { copyFailed = true; }
        CloseHandle(locked);
        check(copyFailed, "Atomic raw write must report replacement failure");
        check(failed && readSession(path) == session, "Failed atomic replace must retain prior bytes");
#else
        // A read-only directory prevents creation of the same-directory temporary.
        // Skip for root, whose filesystem privileges bypass this failure mechanism.
        fs::permissions(path.parent_path(), fs::perms::owner_read | fs::perms::owner_exec);
        bool failed = false; try { saveSession(path, next); } catch (const std::exception&) { failed = true; }
        bool copyFailed = false; try { writeFileAtomically(path, raw); } catch (const std::exception&) { copyFailed = true; }
        fs::permissions(path.parent_path(), fs::perms::owner_all);
        if (failed) check(copyFailed, "Atomic raw write must report creation failure");
        if (failed) check(readSession(path) == session, "I/O failure must preserve previous valid session");
#endif
        for (const auto& item : fs::directory_iterator(path.parent_path())) check(item.path() == path, "No temporary session files should remain");
        fs::remove_all(directory);
        std::cout << "Session persistence tests passed\n";
    } catch (const std::exception& error) { std::error_code ignored; fs::permissions(directory / "nested", fs::perms::owner_all, ignored); fs::remove_all(directory, ignored); std::cerr << error.what() << '\n'; return 1; }
}
