#pragma once
#include <atomic>
#include <filesystem>
#include <memory>
#include <optional>
#include <string>

namespace ssmv {
// Network work is synchronous; call from a background thread. Cancellation is
// observed between reads, with each blocking network operation bounded to 5 s.
std::wstring normalizeRemoteURL(std::wstring const& url);
std::wstring resolveRemoteLink(std::wstring const& source, std::wstring const& link);
std::filesystem::path downloadRemoteDocument(std::wstring const& url,
    std::filesystem::path const& cacheDirectory,
    std::shared_ptr<std::atomic_bool> const& cancelled = {});
std::optional<std::wstring> remoteDocumentSource(std::filesystem::path const& path);
}
