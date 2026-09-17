#include "../App/RemoteDocument.hpp"
#include "../Core/Documents.hpp"
#include "../Core/Session.hpp"
#include <winrt/base.h>
#include <chrono>
#include <iostream>
#include <stdexcept>

namespace {
void expect(bool value, char const* message) { if (!value) throw std::runtime_error(message); }
template<class Action> void rejects(Action action) {
    bool rejected = false;
    try { action(); } catch (...) { rejected = true; }
    expect(rejected, "Invalid remote input was accepted");
}
}
int main(int argc, char**) {
    winrt::init_apartment();
    auto folder = std::filesystem::temp_directory_path() / (L"ssmv-remote-test-" + std::to_wstring(std::chrono::steady_clock::now().time_since_epoch().count()));
    try {
        using namespace ssmv;
        expect(normalizeRemoteURL(L"https://github.com/raeseoklee/ssmv/blob/main/Examples/Windows.md#heading") ==
               L"https://raw.githubusercontent.com/raeseoklee/ssmv/main/Examples/Windows.md", "GitHub normalization failed");
        expect(resolveRemoteLink(L"https://example.com/docs/readme.md", L"../guide.md#intro") ==
               L"https://example.com/guide.md#intro", "Relative link resolution failed");
        for (auto url : {L"http://example.com/test.md", L"file:///tmp/a.md", L"https://user:secret@example.com/a.md",
                         L"https://@example.com/a.md", L"https://example.com/\r\na.md"})
            rejects([&] { normalizeRemoteURL(url); });
        rejects([&] { resolveRemoteLink(L"https://example.com/a.md", L"http://example.com/b.md"); });
        auto cancelled = std::make_shared<std::atomic_bool>(true);
        rejects([&] { downloadRemoteDocument(L"https://example.com/a.md", folder, cancelled); });
        expect(!std::filesystem::exists(folder), "Cancelled download created cache files");
        std::filesystem::create_directories(folder);
        auto local = folder / L"offline.md";
        writeFileAtomically(local, "# Offline\n");
        writeFileAtomically(local.wstring() + L".url", "https://example.com/docs/offline.md");
        expect(remoteDocumentSource(local) == L"https://example.com/docs/offline.md", "Cached source was not restored");
        expect(readDocument(local).source == "# Offline\n", "Offline content not readable");
        writeFileAtomically(local.wstring() + L".url", "file:///C:/secret");
        expect(!remoteDocumentSource(local), "Invalid source metadata was accepted");
        if (argc > 1) {
            auto path = downloadRemoteDocument(L"https://github.com/raeseoklee/ssmv/blob/main/Examples/Windows.md", folder);
            expect(readDocument(path).source.find("#") != std::string::npos, "Public Markdown was not downloaded");
            expect(remoteDocumentSource(path) == L"https://raw.githubusercontent.com/raeseoklee/ssmv/main/Examples/Windows.md",
                   "Final source was not cached");
            auto again = downloadRemoteDocument(L"https://github.com/raeseoklee/ssmv/blob/main/Examples/Windows.md", folder);
            expect(path == again, "Repeat URL did not reuse cached document identity");
            auto raw = downloadRemoteDocument(L"https://raw.githubusercontent.com/raeseoklee/ssmv/main/Examples/Windows.md", folder);
            expect(path == raw, "GitHub and raw URLs did not share the final URL cache identity");
            rejects([&] { downloadRemoteDocument(L"https://github.com/raeseoklee/ssmv", folder); });
            std::cout << "Public HTTPS download, cache refresh and HTML rejection passed.\n";
        }
        std::filesystem::remove_all(folder);
        std::cout << "Remote URL validation, cancellation, relative links and offline metadata passed.\n";
        return 0;
    } catch (winrt::hresult_error const& error) {
        std::cerr << winrt::to_string(error.message()) << '\n';
    } catch (std::exception const& error) { std::cerr << error.what() << '\n'; }
    std::filesystem::remove_all(folder);
    return 1;
}
