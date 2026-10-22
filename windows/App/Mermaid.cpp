#include "Mermaid.hpp"
#include <windows.h>
#include <filesystem>
#include <chrono>
#include <stdexcept>
#include <winrt/Microsoft.Web.WebView2.Core.h>
#include <winrt/Microsoft.UI.Xaml.Media.Imaging.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Data.Json.h>
#include <winrt/Windows.Security.Cryptography.h>
#include <winrt/Windows.Storage.Streams.h>
using namespace winrt;
using namespace Windows::Foundation;
using namespace Windows::Data::Json;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
using namespace Microsoft::Web::WebView2::Core;
using namespace Windows::Storage::Streams;
using namespace std::chrono_literals;
namespace ssmv::ui {
Mermaid::~Mermaid() { if (idle_) idle_.Stop(); releaseBrowser(); }
void Mermaid::releaseBrowser() {
    if (!browser_) return;
    uint32_t index = 0;
    if (layer_ && host_.Children().IndexOf(layer_, index)) host_.Children().RemoveAt(index);
    layer_ = nullptr;
    browser_.Close(); browser_ = nullptr; ready_ = false;
}

IAsyncAction Mermaid::render(std::string source, bool dark, std::shared_ptr<Diagram> output) {
    apartment_context ui;
    auto cancellation = co_await get_cancellation_token();
    cancellation.enable_propagation();
    if (source.size() > 65536) throw std::runtime_error("Diagram exceeds rendering limit.");
    std::string key = (dark ? "dark:" : "light:") + source;
    auto deadline = std::chrono::steady_clock::now() + 20s;
    while (busy_) {
        if (std::chrono::steady_clock::now() > deadline) throw std::runtime_error("Diagram renderer is busy.");
        co_await resume_after(30ms); co_await ui;
    }
    busy_ = true;
    if (!idle_) {
        idle_ = host_.DispatcherQueue().CreateTimer(); idle_.Interval(15s); idle_.IsRepeating(true);
        idle_.Tick([this](auto const&, auto const&) { if (!busy_) { idle_.Stop(); releaseBrowser(); } });
    }
    idle_.Stop(); idle_.Start();
    struct Unlock { bool& flag; ~Unlock() { flag = false; } } unlock{busy_};
    for (auto const& entry : cache_) if (entry.first == key) { *output = entry.second; co_return; }
    if (!browser_) {
        browser_ = WebView2(); browser_.Width(2048); browser_.Height(4096);
        browser_.Opacity(0); browser_.IsHitTestVisible(false);
        browser_.HorizontalAlignment(HorizontalAlignment::Left);
        browser_.VerticalAlignment(VerticalAlignment::Top);
        layer_ = Canvas(); layer_.Width(0); layer_.Height(0); layer_.IsHitTestVisible(false);
        layer_.Children().Append(browser_); host_.Children().Append(layer_);
        co_await browser_.EnsureCoreWebView2Async();
        auto core = browser_.CoreWebView2();
        wchar_t executable[32768]{}; GetModuleFileNameW(nullptr, executable, 32768);
        auto folder = std::filesystem::path(executable).parent_path() / L"mermaid";
        core.SetVirtualHostNameToFolderMapping(L"ssmv.invalid", folder.wstring(), CoreWebView2HostResourceAccessKind::DenyCors);
        core.Settings().AreDevToolsEnabled(false);
        core.Settings().AreDefaultContextMenusEnabled(false);
        core.Settings().IsStatusBarEnabled(false);
        core.NavigationStarting([](auto const&, auto const& event) {
            if (event.Uri() != L"https://ssmv.invalid/index.html") event.Cancel(true);
        });
        core.NewWindowRequested([](auto const&, auto const& event) { event.Handled(true); });
        core.PermissionRequested([](auto const&, auto const& event) { event.State(CoreWebView2PermissionState::Deny); });
        core.AddWebResourceRequestedFilter(L"*", CoreWebView2WebResourceContext::All);
        core.WebResourceRequested([](auto const& sender, auto const& event) {
            auto uri = std::wstring(event.Request().Uri());
            if (uri.rfind(L"https://ssmv.invalid/", 0) != 0 && uri.rfind(L"data:", 0) != 0 && uri.rfind(L"blob:", 0) != 0)
                event.Response(sender.Environment().CreateWebResourceResponse(nullptr, 403, L"Forbidden", L""));
        });
        core.NavigationCompleted([this](auto const&, auto const& event) { ready_ = event.IsSuccess(); });
        core.Navigate(L"https://ssmv.invalid/index.html");
    }
    while (!ready_) {
        if (std::chrono::steady_clock::now() > deadline) throw std::runtime_error("Diagram renderer did not start.");
        co_await resume_after(30ms); co_await ui;
    }
    auto request = ++request_;
    auto quoted = JsonValue::CreateStringValue(to_hstring(source)).Stringify();
    co_await browser_.ExecuteScriptAsync(L"window.ssmvRequest=" + to_hstring(request) + L";window.ssmvResult=null;((id)=>window.ssmvRender(" + quoted + (dark ? L",true" : L",false") + L").then(x=>{if(window.ssmvRequest===id)window.ssmvResult=x}).catch(()=>{if(window.ssmvRequest===id)window.ssmvResult={error:true}}))(window.ssmvRequest);");
    for (;;) {
        if (std::chrono::steady_clock::now() > deadline) throw std::runtime_error("Diagram rendering timed out.");
        auto raw = co_await browser_.ExecuteScriptAsync(L"window.ssmvResult");
        if (raw != L"null") {
            auto result = JsonObject::Parse(raw);
            if (result.HasKey(L"error")) throw std::runtime_error("Unable to render diagram.");
            output->width = result.GetNamedNumber(L"width"); output->height = result.GetNamedNumber(L"height");
            if (output->width <= 0 || output->width > 2048 || output->height <= 0 || output->height > 4096) throw std::runtime_error("Invalid diagram dimensions.");
            browser_.Width(output->width); browser_.Height(output->height); browser_.UpdateLayout();
            co_await resume_after(100ms); co_await ui;
            InMemoryRandomAccessStream capture;
            co_await browser_.CoreWebView2().CapturePreviewAsync(CoreWebView2CapturePreviewImageFormat::Png, capture);
            if (capture.Size() > 32 * 1024 * 1024) throw std::runtime_error("Diagram image is too large.");
            capture.Seek(0); DataReader reader(capture);
            auto length = static_cast<uint32_t>(capture.Size());
            co_await reader.LoadAsync(length); output->png.resize(length); reader.ReadBytes(output->png);
            size_t bytesHeld = output->png.size();
            for (auto const& entry : cache_) bytesHeld += entry.second.png.size();
            while (!cache_.empty() && (cache_.size() >= 8 || bytesHeld > 16 * 1024 * 1024)) { bytesHeld -= cache_.front().second.png.size(); cache_.erase(cache_.begin()); }
            if (output->png.size() <= 16 * 1024 * 1024) cache_.emplace_back(std::move(key), *output);
            co_return;
        }
        co_await resume_after(30ms); co_await ui;
    }
}
IAsyncAction setDiagramImage(Border target, Diagram diagram) {
    InMemoryRandomAccessStream stream;
    DataWriter writer(stream); writer.WriteBytes(diagram.png); co_await writer.StoreAsync(); writer.DetachStream(); stream.Seek(0);
    Media::Imaging::BitmapImage bitmap; co_await bitmap.SetSourceAsync(stream);
    Image image; image.Source(bitmap); image.Stretch(Media::Stretch::Uniform);
    image.MaxWidth(diagram.width); image.HorizontalAlignment(HorizontalAlignment::Left);
    Automation::AutomationProperties::SetAutomationId(image, L"reader.mermaid");
    Automation::AutomationProperties::SetName(image, L"Mermaid diagram");
    target.Child(image);
}
}
