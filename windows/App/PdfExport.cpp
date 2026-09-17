#include "PdfExport.hpp"
#include <windows.h>
#include <objbase.h>
#include <winspool.h>
#include <algorithm>
#include <chrono>
#include <climits>
#include <cwctype>
#include <fstream>
#include <thread>
#include <vector>

#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "winspool.lib")
#pragma comment(lib, "ole32.lib")

namespace ssmv::ui {
namespace {
constexpr wchar_t PrinterName[] = L"Microsoft Print to PDF";
thread_local std::atomic_bool const* currentCancellation = nullptr;
BOOL CALLBACK abortPrint(HDC, int) {
    return !currentCancellation || !currentCancellation->load(std::memory_order_relaxed);
}
void checkCancelled(std::atomic_bool const& cancelled) {
    if (cancelled.load(std::memory_order_relaxed)) throw PdfExportCancelled{};
}
void require(bool success, char const* message) {
    if (!success) {
        if (currentCancellation) checkCancelled(*currentCancellation);
        throw std::runtime_error(message);
    }
}
std::wstring unicode(std::string const& source) {
    if (source.empty()) return {};
    require(source.size() <= INT_MAX, "Text is too large to export.");
    auto count = MultiByteToWideChar(CP_UTF8, 0, source.data(), static_cast<int>(source.size()), nullptr, 0);
    require(count > 0, "Unable to decode document text for PDF export.");
    std::wstring text(static_cast<std::size_t>(count), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, source.data(), static_cast<int>(source.size()), text.data(), count);
    for (std::size_t i = 0; (i = text.find(L'\t', i)) != std::wstring::npos; i += 4) text.replace(i, 1, L"    ");
    return text;
}
std::string printText(std::string const& source) {
    std::string result;
    for (auto const& span : parseInline(source)) {
        result += span.text;
        auto kind = classifyLink(span.destination);
        if ((kind == LinkKind::Web || kind == LinkKind::Email) && span.text != span.destination)
            result += " (" + span.destination + ")";
    }
    return result;
}
struct TemporaryFile {
    std::filesystem::path path;
    explicit TemporaryFile(std::filesystem::path const& destination) {
        GUID id{};
        require(SUCCEEDED(CoCreateGuid(&id)), "Unable to create a PDF export file name.");
        wchar_t value[40]{};
        StringFromGUID2(id, value, 40);
        path = std::filesystem::absolute(destination).parent_path() / (std::wstring(L".ssmv-export-") + value + L".pdf");
        HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
        require(file != INVALID_HANDLE_VALUE, "Unable to create a temporary PDF in the selected folder.");
        CloseHandle(file);
    }
    ~TemporaryFile() {
        if (path.empty()) return;
        // A cancelled spool job can take a moment to release its output handle.
        for (unsigned attempt = 0; attempt != 20; ++attempt) {
            if (DeleteFileW(path.c_str()) || GetLastError() == ERROR_FILE_NOT_FOUND) break;
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
    }
};
struct Printer {
    HANDLE handle = nullptr;
    HDC dc = nullptr;
    DWORD job = 0;
    bool inDocument = false;
    explicit Printer() {
        require(OpenPrinterW(const_cast<wchar_t*>(PrinterName), &handle, nullptr) != FALSE,
                "Microsoft Print to PDF is unavailable. Enable Microsoft Print to PDF in Windows Features, then try again.");
        dc = CreateDCW(L"WINSPOOL", PrinterName, nullptr, nullptr);
        if (!dc) {
            ClosePrinter(handle); handle = nullptr;
            throw std::runtime_error("Unable to start Microsoft Print to PDF. Check the Windows print spooler.");
        }
    }
    ~Printer() {
        if (inDocument) AbortDoc(dc);
        if (job) SetJobW(handle, job, 0, nullptr, JOB_CONTROL_DELETE);
        if (dc) DeleteDC(dc);
        if (handle) ClosePrinter(handle);
    }
};
struct Font {
    HDC dc;
    HFONT font;
    HGDIOBJ previous;
    Font(HDC context, int pixels, bool bold = false, bool code = false, bool italic = false)
        : dc(context), font(CreateFontW(-pixels, 0, 0, 0, bold ? FW_BOLD : FW_NORMAL, italic, FALSE, FALSE,
              DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, DEFAULT_QUALITY,
              DEFAULT_PITCH, code ? L"Consolas" : L"Segoe UI")), previous(nullptr) {
        require(font != nullptr, "Unable to create a font for PDF export.");
        previous = SelectObject(dc, font);
    }
    ~Font() { SelectObject(dc, previous); DeleteObject(font); }
};

// Produce only one wrapped line at a time. This keeps very large paragraphs and
// code blocks bounded instead of allocating a second page-sized copy per line.
std::wstring nextLine(HDC dc, std::wstring const& text, std::size_t& offset, int width, bool preserveSpaces) {
    if (offset >= text.size()) return {};
    auto end = text.find(L'\n', offset);
    if (end == std::wstring::npos) end = text.size();
    if (end == offset) { ++offset; return {}; }
    auto available = (std::min)(end - offset, std::size_t{4096});
    int fit = 0;
    SIZE extent{};
    require(GetTextExtentExPointW(dc, text.data() + offset, static_cast<int>(available), width, &fit, nullptr, &extent) != FALSE,
            "Unable to measure document text for PDF export.");
    auto length = static_cast<std::size_t>((std::max)(1, fit));
    length = (std::min)(length, available);
    // Never split a UTF-16 surrogate pair at a wrap boundary.
    if (offset + length < end && text[offset + length - 1] >= 0xd800 && text[offset + length - 1] <= 0xdbff) {
        if (length > 1) --length; else ++length;
    }
    if (!preserveSpaces && offset + length < end) {
        auto boundary = length;
        while (boundary > 0 && !iswspace(text[offset + boundary - 1])) --boundary;
        if (boundary > 0) length = boundary;
    }
    auto line = text.substr(offset, length);
    offset += length;
    if (!preserveSpaces) {
        while (!line.empty() && iswspace(line.back())) line.pop_back();
        while (offset < end && iswspace(text[offset])) ++offset;
    }
    if (offset == end && end < text.size()) ++offset;
    if (!line.empty() && line.back() == L'\r') line.pop_back();
    return line;
}
struct Layout {
    Printer& printer;
    std::atomic_bool const& cancelled;
    int dpi, left, right, top, bottom, y;
    unsigned pages = 0;
    explicit Layout(Printer& p, std::atomic_bool const& stop) : printer(p), cancelled(stop) {
        dpi = GetDeviceCaps(p.dc, LOGPIXELSY);
        int xDpi = GetDeviceCaps(p.dc, LOGPIXELSX);
        require(dpi > 0 && xDpi > 0, "The PDF printer returned invalid page dimensions.");
        left = xDpi * 3 / 4; right = GetDeviceCaps(p.dc, HORZRES) - left;
        top = dpi * 3 / 4; bottom = GetDeviceCaps(p.dc, VERTRES) - top;
        y = top;
        require(right > left && bottom > top, "The PDF printer page is too small.");
    }
    int points(int p) const { return MulDiv(p, dpi, 72); }
    void startPage() {
        checkCancelled(cancelled);
        require(StartPage(printer.dc) > 0, "Unable to start a PDF page.");
        SetBkMode(printer.dc, TRANSPARENT);
        SetTextColor(printer.dc, RGB(30, 30, 30));
        ++pages; y = top;
    }
    void endPage() {
        Font footer(printer.dc, points(9));
        auto text = std::to_wstring(pages);
        RECT rect{left, bottom + points(18), right, bottom + points(36)};
        DrawTextW(printer.dc, text.c_str(), static_cast<int>(text.size()), &rect, DT_RIGHT | DT_SINGLELINE | DT_NOPREFIX);
        require(EndPage(printer.dc) > 0, "Unable to finish a PDF page.");
    }
    void space(int pixels) { y += pixels; }
    void ensure(int height) {
        checkCancelled(cancelled);
        if (y + height <= bottom) return;
        endPage(); startPage();
    }
    void drawLine(std::wstring const& text, int x, int width, int height, bool code = false,
                  TableAlignment alignment = TableAlignment::Left) {
        RECT rect{x, y, x + width, y + height};
        if (code) {
            auto brush = CreateSolidBrush(RGB(244, 244, 244));
            FillRect(printer.dc, &rect, brush); DeleteObject(brush);
        }
        UINT flags = DT_SINGLELINE | DT_NOPREFIX;
        if (alignment == TableAlignment::Center) flags |= DT_CENTER;
        if (alignment == TableAlignment::Right) flags |= DT_RIGHT;
        if (!text.empty()) require(DrawTextW(printer.dc, text.c_str(), static_cast<int>(text.size()), &rect, flags) > 0,
                                   "Unable to draw document text in the PDF.");
    }
    void paragraph(Block const& block) {
        bool heading = block.kind == BlockKind::Heading, code = block.kind == BlockKind::Code;
        int size = heading ? (block.level == 1 ? 24 : block.level == 2 ? 19 : 15) : code ? 10 : 11;
        Font font(printer.dc, points(size), heading, code, block.kind == BlockKind::Quote);
        TEXTMETRICW metrics{};
        require(GetTextMetricsW(printer.dc, &metrics) != FALSE, "Unable to read the PDF font metrics.");
        int lineHeight = metrics.tmHeight + points(code ? 3 : 4);
        auto text = unicode(code ? block.text : printText(block.text));
        int indent = 0;
        if (block.kind == BlockKind::UnorderedListItem || block.kind == BlockKind::OrderedListItem) {
            indent = points(12 + static_cast<int>((std::min)(block.indent, std::size_t{16})) * 3);
            text.insert(0, block.kind == BlockKind::UnorderedListItem ? L"• " : std::to_wstring(block.startNumber) + L". ");
        } else if (block.kind == BlockKind::Quote) indent = points(16);
        if (heading) space(points(8));
        ensure(lineHeight * (heading ? 2 : 1));
        std::size_t offset = 0;
        do {
            ensure(lineHeight);
            auto line = nextLine(printer.dc, text, offset, right - left - indent - (code ? points(8) : 0), code);
            drawLine(line, left + indent, right - left - indent, lineHeight, code);
            y += lineHeight;
        } while (offset < text.size());
        space(points(heading ? 7 : 8));
    }
    void table(Block const& block) {
        if (block.tableRows.empty()) return;
        std::size_t columns = 0;
        for (auto const& row : block.tableRows) columns = (std::max)(columns, row.size());
        if (!columns) return;
        // Keep unusual wide tables legible rather than silently clipping cells.
        require(columns <= 64, "This table has too many columns to fit in a PDF. Reduce it to at most 64 columns.");
        int width = (right - left) / static_cast<int>(columns), padding = (std::min)(points(4), width / 8);
        require(width - 2 * padding >= points(24), "This table is too wide for the PDF page. Reduce its number of columns or choose a wider paper size in Microsoft Print to PDF preferences.");
        for (std::size_t rowIndex = 0; rowIndex < block.tableRows.size(); ++rowIndex) {
            Font font(printer.dc, points(columns > 6 ? 8 : 10), rowIndex == 0);
            TEXTMETRICW metrics{}; GetTextMetricsW(printer.dc, &metrics);
            int lineHeight = metrics.tmHeight + points(4);
            std::vector<std::wstring> cells(columns);
            std::vector<std::size_t> offsets(columns, 0);
            for (std::size_t c = 0; c < block.tableRows[rowIndex].size(); ++c)
                cells[c] = unicode(printText(block.tableRows[rowIndex][c]));
            bool remaining;
            do {
                ensure(lineHeight + padding);
                remaining = false;
                for (std::size_t c = 0; c < columns; ++c) {
                    auto line = nextLine(printer.dc, cells[c], offsets[c], (std::max)(1, width - 2 * padding), false);
                    auto alignment = c < block.alignments.size() ? block.alignments[c] : TableAlignment::Left;
                    drawLine(line, left + static_cast<int>(c) * width + padding, width - 2 * padding, lineHeight, rowIndex == 0, alignment);
                    remaining = remaining || offsets[c] < cells[c].size();
                }
                y += lineHeight;
            } while (remaining);
            auto pen = CreatePen(PS_SOLID, (std::max)(1, points(1) / 2), RGB(205, 205, 205));
            auto old = SelectObject(printer.dc, pen);
            MoveToEx(printer.dc, left, y, nullptr); LineTo(printer.dc, right, y);
            SelectObject(printer.dc, old); DeleteObject(pen);
            y += padding;
        }
        space(points(8));
    }
};
bool completePdf(std::filesystem::path const& path) {
    // EndDoc submits a spool job; it does not promise that the driver has closed
    // the PDF. Require exclusive access and the trailer before committing it.
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, 0, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER size{};
    bool complete = false;
    if (GetFileSizeEx(file, &size) && size.QuadPart > 12) {
        char header[5]{}; DWORD read = 0;
        if (ReadFile(file, header, 5, &read, nullptr) && read == 5 && std::string_view(header, 5) == "%PDF-") {
            LARGE_INTEGER offset{}; offset.QuadPart = (std::max)(0LL, size.QuadPart - 1024);
            SetFilePointerEx(file, offset, nullptr, FILE_BEGIN);
            char tail[1024]{};
            if (ReadFile(file, tail, sizeof(tail), &read, nullptr)) complete = std::string_view(tail, read).find("%%EOF") != std::string_view::npos;
        }
    }
    CloseHandle(file);
    return complete;
}
}
PdfExportResult exportPdf(MarkdownDocument const& snapshot, std::wstring const& title,
                          std::filesystem::path const& destination, std::atomic_bool const& cancelled) {
    checkCancelled(cancelled);
    require(!destination.empty(), "Choose a file name for the PDF export.");
    TemporaryFile temporary(destination);
    // Destroy the printer before the temporary file so failed/cancelled jobs
    // release their handles before cleanup removes incomplete output.
    Printer printer;
    struct CancellationScope {
        std::atomic_bool const* previous;
        explicit CancellationScope(std::atomic_bool const& stop) : previous(currentCancellation) { currentCancellation = &stop; }
        ~CancellationScope() { currentCancellation = previous; }
    } cancellationScope(cancelled);
    require(SetAbortProc(printer.dc, abortPrint) > 0, "Unable to configure PDF export cancellation.");
    DOCINFOW info{}; info.cbSize = sizeof(info);
    info.lpszDocName = title.empty() ? L"SSMV document" : title.c_str();
    info.lpszOutput = temporary.path.c_str();
    auto job = StartDocW(printer.dc, &info);
    require(job > 0, "Unable to start PDF export. Check the Microsoft Print to PDF printer and selected folder.");
    printer.job = static_cast<DWORD>(job); printer.inDocument = true;
    Layout layout(printer, cancelled);
    layout.startPage();
    for (auto const& block : snapshot.blocks) {
        checkCancelled(cancelled);
        if (block.kind == BlockKind::Table) layout.table(block);
        else if (block.kind == BlockKind::Rule) {
            layout.ensure(layout.points(18));
            MoveToEx(printer.dc, layout.left, layout.y + layout.points(6), nullptr);
            LineTo(printer.dc, layout.right, layout.y + layout.points(6));
            layout.space(layout.points(18));
        } else layout.paragraph(block);
    }
    layout.endPage();
    checkCancelled(cancelled);
    require(EndDoc(printer.dc) > 0, "The PDF printer could not finish the document.");
    printer.inDocument = false;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(60);
    while (!completePdf(temporary.path)) {
        checkCancelled(cancelled);
        require(std::chrono::steady_clock::now() < deadline, "The PDF printer did not finish within one minute. Check the print queue, then try again.");
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    checkCancelled(cancelled);
    require(MoveFileExW(temporary.path.c_str(), std::filesystem::absolute(destination).c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != FALSE,
            "The PDF was created but could not replace the selected file. Close that PDF in other applications, then try again.");
    printer.job = 0;
    temporary.path.clear();
    return {layout.pages};
}
}
