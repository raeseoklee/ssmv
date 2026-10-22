#pragma once
#include "../Core/Markdown.hpp"
#include <atomic>
#include <filesystem>
#include <stdexcept>
#include <string>
#include <map>
#include <vector>
#include <cstdint>

namespace ssmv::ui {
struct PdfExportCancelled : std::runtime_error {
    PdfExportCancelled() : std::runtime_error("PDF export cancelled.") {}
};
using PdfDiagrams = std::map<std::size_t, std::vector<uint8_t>>;
struct PdfExportResult { unsigned pages = 0; };
// Run off the UI thread. The caller owns an immutable document snapshot and the
// cancellation flag for the entire call. Existing destinations change only after
// a complete PDF has been produced. Requires Windows' Microsoft Print to PDF.
PdfExportResult exportPdf(MarkdownDocument const& snapshot, std::wstring const& title,
                          std::filesystem::path const& destination,
                          std::atomic_bool const& cancelled, PdfDiagrams const& diagrams = {});
}
