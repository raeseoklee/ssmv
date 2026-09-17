#include "RemoteDocument.hpp"
#include "../Core/Documents.hpp"
#include "../Core/Session.hpp"
#include <windows.h>
#include <winhttp.h>
#include <bcrypt.h>
#include <winrt/Windows.Foundation.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cctype>
#include <cwctype>
#include <fstream>
#include <stdexcept>
#include <vector>
#pragma comment(lib, "winhttp.lib")
#pragma comment(lib, "bcrypt.lib")

namespace ssmv {
namespace {
using winrt::Windows::Foundation::Uri;
struct Handle {
    HINTERNET value = nullptr;
    ~Handle() { if (value) WinHttpCloseHandle(value); }
    Handle(Handle const&) = delete;
    Handle& operator=(Handle const&) = delete;
    explicit Handle(HINTERNET handle) : value(handle) {
        if (!value) throw std::runtime_error("Could not connect to the document server.");
    }
};
void require(BOOL success) {
    if (!success) throw std::runtime_error("The document request failed or timed out. Check the URL and connection.");
}
std::wstring lower(std::wstring text) {
    std::transform(text.begin(), text.end(), text.begin(), [](wchar_t c) { return std::towlower(c); });
    return text;
}
Uri checked(std::wstring const& text) {
    if (text.empty() || text.size() > 8192 || text.find_first_of(L"\r\n\t\\") != std::wstring::npos)
        throw std::runtime_error("Enter a valid HTTPS Markdown URL.");
    Uri uri(text);
    if (uri.SchemeName() != L"https" || uri.Host().empty() || !uri.UserName().empty() || !uri.Password().empty())
        throw std::runtime_error("Only HTTPS URLs without embedded credentials are supported.");
    auto authorityEnd = text.find_first_of(L"/?#", text.find(L"://") + 3);
    auto authority = text.substr(text.find(L"://") + 3, authorityEnd - (text.find(L"://") + 3));
    if (authority.find(L'@') != std::wstring::npos)
        throw std::runtime_error("URLs with embedded credentials are not supported.");
    return uri;
}
std::wstring header(HINTERNET request, DWORD name) {
    DWORD bytes = 0;
    if (!WinHttpQueryHeaders(request, name, WINHTTP_HEADER_NAME_BY_INDEX, nullptr, &bytes, WINHTTP_NO_HEADER_INDEX)) {
        if (GetLastError() == ERROR_WINHTTP_HEADER_NOT_FOUND) return {};
        if (GetLastError() != ERROR_INSUFFICIENT_BUFFER) require(FALSE);
    }
    std::vector<wchar_t> buffer(bytes / sizeof(wchar_t) + 1);
    require(WinHttpQueryHeaders(request, name, WINHTTP_HEADER_NAME_BY_INDEX, buffer.data(), &bytes, WINHTTP_NO_HEADER_INDEX));
    return std::wstring(buffer.data());
}
std::string key(std::wstring const& url) {
    auto utf8 = winrt::to_string(url);
    std::array<unsigned char, 32> digest{};
    if (BCryptHash(BCRYPT_SHA256_ALG_HANDLE, nullptr, 0, reinterpret_cast<PUCHAR>(utf8.data()),
                   static_cast<ULONG>(utf8.size()), digest.data(), static_cast<ULONG>(digest.size())) < 0)
        throw std::runtime_error("Could not identify the downloaded document.");
    constexpr char digits[] = "0123456789abcdef";
    std::string result;
    for (auto byte : digest) { result += digits[byte >> 4]; result += digits[byte & 15]; }
    return result;
}
}

std::wstring normalizeRemoteURL(std::wstring const& text) {
    auto uri = checked(text);
    std::wstring result(uri.AbsoluteUri());
    if (lower(std::wstring(uri.Host())) == L"github.com") {
        std::wstring path(uri.Path());
        auto first = path.find(L'/', 1);
        auto second = first == std::wstring::npos ? first : path.find(L'/', first + 1);
        if (second != std::wstring::npos && path.compare(second, 6, L"/blob/") == 0)
            result = L"https://raw.githubusercontent.com" + path.substr(0, second) + path.substr(second + 5);
    }
    auto fragment = result.find(L'#');
    if (fragment != std::wstring::npos) result.resize(fragment);
    return std::wstring(checked(result).AbsoluteUri());
}
std::wstring resolveRemoteLink(std::wstring const& source, std::wstring const& link) {
    auto combined = checked(source).CombineUri(link);
    return std::wstring(checked(std::wstring(combined.AbsoluteUri())).AbsoluteUri());
}
std::filesystem::path downloadRemoteDocument(std::wstring const& input,
    std::filesystem::path const& cacheDirectory, std::shared_ptr<std::atomic_bool> const& cancelled) {
    auto original = normalizeRemoteURL(input);
    auto url = original;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(30);
    auto check = [&] {
        if (cancelled && cancelled->load()) throw std::runtime_error("Document loading cancelled.");
        if (std::chrono::steady_clock::now() > deadline) throw std::runtime_error("The document request timed out.");
    };
    Handle session(WinHttpOpen(L"SSMV", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_NO_PROXY_NAME,
                               WINHTTP_NO_PROXY_BYPASS, 0));
    require(WinHttpSetTimeouts(session.value, 5000, 5000, 5000, 5000));
    std::string body;
    for (unsigned redirects = 0; ; ++redirects) {
        check();
        auto uri = checked(url);
        Handle connection(WinHttpConnect(session.value, uri.Host().c_str(), static_cast<INTERNET_PORT>(uri.Port()), 0));
        auto target = std::wstring(uri.Path()) + std::wstring(uri.Query());
        Handle request(WinHttpOpenRequest(connection.value, L"GET", target.c_str(), nullptr, WINHTTP_NO_REFERER,
                                          WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE));
        DWORD disabled = WINHTTP_DISABLE_REDIRECTS | WINHTTP_DISABLE_AUTHENTICATION | WINHTTP_DISABLE_COOKIES;
        require(WinHttpSetOption(request.value, WINHTTP_OPTION_DISABLE_FEATURE, &disabled, sizeof(disabled)));
        DWORD decompression = WINHTTP_DECOMPRESSION_FLAG_ALL;
        require(WinHttpSetOption(request.value, WINHTTP_OPTION_DECOMPRESSION, &decompression, sizeof(decompression)));
        require(WinHttpSendRequest(request.value, L"Accept: text/markdown, text/plain;q=0.9\r\n", DWORD(-1),
                                   WINHTTP_NO_REQUEST_DATA, 0, 0, 0));
        check();
        require(WinHttpReceiveResponse(request.value, nullptr));
        DWORD status = 0, statusBytes = sizeof(status);
        require(WinHttpQueryHeaders(request.value, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                                    WINHTTP_HEADER_NAME_BY_INDEX, &status, &statusBytes, WINHTTP_NO_HEADER_INDEX));
        if (status == 301 || status == 302 || status == 303 || status == 307 || status == 308) {
            if (redirects >= 5) throw std::runtime_error("The document URL redirected too many times.");
            auto location = header(request.value, WINHTTP_QUERY_LOCATION);
            if (location.empty()) throw std::runtime_error("The server returned an invalid redirect.");
            url = normalizeRemoteURL(resolveRemoteLink(url, location));
            continue;
        }
        if (status != 200) throw std::runtime_error("The server did not return a document (HTTP " + std::to_string(status) + ").");
        auto type = lower(header(request.value, WINHTTP_QUERY_CONTENT_TYPE));
        if (!(type.empty() || type.starts_with(L"text/plain") || type.starts_with(L"text/markdown") ||
              type.starts_with(L"text/x-markdown") || type.starts_with(L"application/octet-stream")))
            throw std::runtime_error("This URL is not a Markdown text document. Use its raw Markdown URL.");
        std::array<char, 32768> bytes{};
        for (;;) {
            check();
            DWORD read = 0;
            require(WinHttpReadData(request.value, bytes.data(), static_cast<DWORD>(bytes.size()), &read));
            if (!read) break;
            if (body.size() + read > MaxDocumentBytes) throw std::runtime_error("Remote documents must be 16 MiB or smaller.");
            body.append(bytes.data(), read);
        }
        break;
    }
    check();
    if (body.starts_with("\xEF\xBB\xBF")) body.erase(0, 3);
    if (body.empty() || !validUTF8(body) || std::any_of(body.begin(), body.end(), [](unsigned char c) { return c < 32 && c != '\t' && c != '\r' && c != '\n'; }))
        throw std::runtime_error("The downloaded document must contain UTF-8 Markdown text.");
    auto first = body.find_first_not_of(" \r\n\t");
    auto prefix = body.substr(first == std::string::npos ? 0 : first, 256);
    std::transform(prefix.begin(), prefix.end(), prefix.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    if (prefix.starts_with("<!doctype html") || prefix.starts_with("<html"))
        throw std::runtime_error("The URL returned a web page. Use its raw Markdown URL.");
    auto folder = cacheDirectory / key(url);
    std::filesystem::create_directories(folder);
    auto filename = std::filesystem::path(std::wstring(checked(url).Path())).filename().wstring();
    if (filename.empty()) filename = L"Remote document.md";
    for (auto& c : filename) if (c < 32 || std::wstring_view(L"<>:\"/\\|?*").find(c) != std::wstring_view::npos) c = L'_';
    if (filename.size() > 120) filename.resize(120);
    if (std::filesystem::path(filename).extension() != L".md") filename += L".md";
    auto stem = lower(filename.substr(0, filename.find(L'.')));
    while (!stem.empty() && stem.back() == L' ') stem.pop_back();
    if (stem == L"con" || stem == L"prn" || stem == L"aux" || stem == L"nul" ||
        (stem.size() == 4 && (stem.starts_with(L"com") || stem.starts_with(L"lpt")) && ((stem[3] >= L'1' && stem[3] <= L'9') || stem[3] == L'\u00b9' || stem[3] == L'\u00b2' || stem[3] == L'\u00b3')))
        filename.insert(0, L"_");
    auto path = folder / filename;
    std::uintmax_t total = body.size();
    for (auto const& entry : std::filesystem::recursive_directory_iterator(cacheDirectory)) {
        if (entry.is_regular_file() && entry.path() != path) total += entry.file_size();
        if (total > 256 * 1024 * 1024) throw std::runtime_error("Remote documents exceed the 256 MiB storage limit.");
    }
    // The final URL participates in the directory identity. A cancelled refresh
    // cannot change the base URL of an existing cached document.
    check();
    // Metadata first: a document is never published without its remote base URL.
    writeFileAtomically(path.wstring() + L".url", winrt::to_string(url));
    check();
    writeFileAtomically(path, body);
    return path;
}
std::optional<std::wstring> remoteDocumentSource(std::filesystem::path const& path) {
    auto metadata = std::filesystem::path(path.wstring() + L".url");
    std::error_code ec;
    auto size = std::filesystem::file_size(metadata, ec);
    if (ec || size == 0 || size > 8192) return std::nullopt;
    std::ifstream stream(metadata, std::ios::binary);
    std::string text(static_cast<std::size_t>(size), '\0');
    if (!stream.read(text.data(), static_cast<std::streamsize>(text.size())) || !validUTF8(text)) return std::nullopt;
    try { return normalizeRemoteURL(std::wstring(winrt::to_hstring(text))); }
    catch (...) { return std::nullopt; }
}
}
