#pragma once
#include "../Core/Markdown.hpp"
#include <atomic>
#include <filesystem>
#include <stdexcept>
#include <string>

namespace ssmv::ui {
struct PdfExportCancelled : std::runtime_error {
    PdfExportCancelled() : std::runtime_error("PDF export cancelled.") {}
};
struct PdfExportResult { unsigned pages = 0; };
// Run off the UI thread. The caller owns an immutable document snapshot and the
// cancellation flag for the entire call. Existing destinations change only after
// a complete PDF has been produced. Requires Windows' Microsoft Print to PDF.
PdfExportResult exportPdf(MarkdownDocument const& snapshot, std::wstring const& title,
                          std::filesystem::path const& destination,
                          std::atomic_bool const& cancelled);
}
