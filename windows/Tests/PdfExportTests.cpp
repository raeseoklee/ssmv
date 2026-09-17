#include "../App/PdfExport.hpp"
#include <windows.h>
#include <winspool.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Data.Pdf.h>
#include <winrt/Windows.Storage.h>
#include <chrono>
#include <fstream>
#include <iostream>
#include <thread>

#pragma comment(lib, "windowsapp.lib")
using namespace ssmv;
namespace {
void expect(bool condition, char const* message) { if (!condition) throw std::runtime_error(message); }
std::string read(std::filesystem::path const& path) {
    std::ifstream file(path, std::ios::binary);
    return {std::istreambuf_iterator<char>(file), std::istreambuf_iterator<char>()};
}
}
int wmain(int argc, wchar_t** argv) {
    try {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        wchar_t configured[MAX_PATH]{};
        GetEnvironmentVariableW(L"SSMV_PDF_TEST_OUTPUT", configured, MAX_PATH);
        auto folder = argc > 1 ? std::filesystem::path(argv[1]) : *configured ? std::filesystem::path(configured) : std::filesystem::temp_directory_path() / L"SSMV PDF tests";
        std::filesystem::create_directories(folder);
        std::atomic_bool cancelled{true};
        auto output = folder / L"PDF export 한글.pdf";
        { std::ofstream sentinel(output, std::ios::binary); sentinel << "existing destination"; }
        auto document = parseMarkdown("# PDF export\n\nEnglish and 한국어 가나다 문서, 日本語 and 中文.\n\n"
                                      "| Column | 내용 |\n| --- | --- |\n| First | 가나다 |\n\n");
        bool didCancel = false;
        try { ui::exportPdf(document, L"Cancelled export", output, cancelled); }
        catch (ui::PdfExportCancelled const&) { didCancel = true; }
        expect(didCancel, "Pre-cancelled export must report cancellation.");
        expect(read(output) == "existing destination", "Cancellation must preserve the existing destination.");
        std::cout << "PASS: cancellation preserves existing destination\n";

        cancelled = false;
        std::string markdown = "# SSMV PDF export\n\nEnglish and 한국어 가나다 문서, 日本語 and 中文.\n\n"
                               "| Column | 내용 |\n| --- | --- |\n| First | 가나다 |\n\n"
                               "> A quoted paragraph\n\n- A list item\n\n```cpp\nint answer = 42;\n```\n\n";
        for (unsigned i = 0; i < 150; ++i)
            markdown += "## Section " + std::to_string(i) + "\n\nA wrapped paragraph of Unicode text: 한국어 문서를 PDF로 저장합니다. "
                        "This line checks that the export paginates the complete snapshot instead of only the visible section.\n\n";
        document = parseMarkdown(markdown);
        auto result = ui::exportPdf(document, L"SSMV Unicode PDF", output, cancelled);
        expect(result.pages > 2, "Long documents must export multiple pages.");
        expect(read(output).starts_with("%PDF-"), "Export must write an actual PDF.");
        auto file = winrt::Windows::Storage::StorageFile::GetFileFromPathAsync(std::filesystem::absolute(output).wstring()).get();
        auto pdf = winrt::Windows::Data::Pdf::PdfDocument::LoadFromFileAsync(file).get();
        expect(pdf.PageCount() == result.pages, "Windows PDF parser page count must match the rendered export.");
        auto page = pdf.GetPage(0);
        expect(page.Size().Width > 0 && page.Size().Height > 0, "PDF pages must have valid dimensions.");
        page.Close();
        page = nullptr; pdf = nullptr; file = nullptr;
        std::cout << "PASS: Windows PDF parser loaded " << result.pages << " pages including Unicode and tables\n";

        // Cancel a large job while it is rendering, not only before it starts.
        { std::ofstream sentinel(output, std::ios::binary); sentinel << "keep on cancellation"; }
        auto huge = document;
        for (unsigned i = 0; i < 8; ++i) huge.blocks.insert(huge.blocks.end(), document.blocks.begin(), document.blocks.end());
        std::thread cancelThread([&] { std::this_thread::sleep_for(std::chrono::milliseconds(250)); cancelled = true; });
        didCancel = false;
        try { ui::exportPdf(huge, L"Cancel during rendering", output, cancelled); }
        catch (ui::PdfExportCancelled const&) { didCancel = true; }
        catch (...) { cancelThread.join(); throw; }
        cancelThread.join();
        expect(didCancel, "Cancellation during rendering must be reported.");
        expect(read(output) == "keep on cancellation", "Cancellation during rendering must preserve the existing destination.");
        for (auto const& item : std::filesystem::directory_iterator(folder))
            expect(!item.path().filename().wstring().starts_with(L".ssmv-export-"), "Export must remove its temporary PDF after cancellation.");
        std::cout << "PASS: cancellation during rendering preserves destination and removes temporary output\n";
        // Leave a real PDF artifact for visual inspection after the destructive
        // preservation assertions have completed.
        cancelled = false;
        ui::exportPdf(document, L"SSMV Unicode PDF", output, cancelled);
        return 0;
    } catch (winrt::hresult_error const& error) {
        std::wcerr << L"PDF test failure: " << error.message().c_str() << L'\n';
    } catch (std::exception const& error) {
        std::cerr << "PDF test failure: " << error.what() << '\n';
    }
    return 1;
}
