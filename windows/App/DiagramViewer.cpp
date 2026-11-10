#include "DiagramViewer.hpp"
#include <windows.h>
#include <filesystem>
#include <chrono>
#include <stdexcept>
#include <winrt/Windows.Data.Json.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Graphics.h>
#include <winrt/Microsoft.UI.Windowing.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Microsoft.Web.WebView2.Core.h>
using namespace winrt;
using namespace Windows::Foundation;
using namespace Windows::Data::Json;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
using namespace Microsoft::Web::WebView2::Core;
using namespace std::chrono_literals;

namespace ssmv::ui {
std::shared_ptr<DiagramViewer> DiagramViewer::open(std::string source, bool dark) {
    if (source.size() > 65536) throw std::runtime_error("Diagram exceeds the 64 KiB limit.");
    auto viewer = std::make_shared<DiagramViewer>();
    viewer->window_ = Window();
    viewer->window_.Title(L"Diagram — SSMV");
    viewer->window_.AppWindow().Resize({1100, 800});
    Grid root;
    root.RequestedTheme(dark ? ElementTheme::Dark : ElementTheme::Light);
    Automation::AutomationProperties::SetAutomationId(root, L"diagram.viewer");
    viewer->browser_ = WebView2();
    // WebView2 needs a visible, arranged host to initialize the composition controller.
    root.Children().Append(viewer->browser_);
    viewer->status_ = TextBlock();
    viewer->status_.Text(L"Loading diagram…");
    viewer->status_.IsHitTestVisible(false);
    viewer->status_.TextWrapping(TextWrapping::Wrap);
    viewer->status_.Margin({24, 24, 24, 24});
    root.Children().Append(viewer->status_);
    viewer->window_.Content(root);
    std::weak_ptr<DiagramViewer> weak = viewer;
    viewer->window_.Closed([weak](auto const&, auto const&) { if (auto self = weak.lock()) self->dispose(); });
    viewer->window_.AppWindow().Changed([weak](auto const&, auto const&) { if (auto self = weak.lock()) self->syncFullscreen(); });
    viewer->window_.Activate();
    viewer->load(std::move(source), dark);
    return viewer;
}

DiagramViewer::~DiagramViewer() { try { close(); } catch (...) {} }
void DiagramViewer::dispose() {
    closed_ = true;
    if (browser_) { auto browser = browser_; browser_ = nullptr; browser.Close(); }
    if (window_) window_.Content(nullptr);
    status_ = nullptr;
}
void DiagramViewer::close() {
    if (!closed_ && window_) window_.Close();
    dispose();
    window_ = nullptr;
}
void DiagramViewer::toggleFullscreen() {
    if (closed_ || !window_) return;
    using Kind = Microsoft::UI::Windowing::AppWindowPresenterKind;
    auto app = window_.AppWindow();
    app.SetPresenter(app.Presenter().Kind() == Kind::FullScreen ? Kind::Default : Kind::FullScreen);
    syncFullscreen();
}
fire_and_forget DiagramViewer::syncFullscreen() {
    auto lifetime = shared_from_this();
    if (closed_ || !browser_ || !browser_.CoreWebView2()) co_return;
    try {
        auto full = window_.AppWindow().Presenter().Kind() == Microsoft::UI::Windowing::AppWindowPresenterKind::FullScreen;
        co_await browser_.ExecuteScriptAsync(full ? L"window.ssmvSetFullscreen?.(true)" : L"window.ssmvSetFullscreen?.(false)");
    } catch (...) { /* Closing the native window cancels pending script work. */ }
}

fire_and_forget DiagramViewer::load(std::string source, bool dark) {
    auto lifetime = shared_from_this();
    apartment_context ui;
    auto deadline = std::chrono::steady_clock::now() + 20s;
    auto bounded = [this, deadline](auto operation) -> IAsyncAction {
        apartment_context context;
        while (operation.Status() == AsyncStatus::Started) {
            if (closed_ || std::chrono::steady_clock::now() >= deadline) {
                operation.Cancel();
                throw std::runtime_error("Diagram loading timed out. Close this window and try again.");
            }
            co_await resume_after(30ms); co_await context;
        }
        if (closed_) throw hresult_canceled();
    };
    try {
        auto browser = browser_;
        auto initialization = browser.EnsureCoreWebView2Async();
        co_await bounded(initialization); initialization.GetResults();
        auto core = browser.CoreWebView2();
        wchar_t executable[32768]{}; GetModuleFileNameW(nullptr, executable, 32768);
        auto folder = std::filesystem::path(executable).parent_path() / L"mermaid";
        core.SetVirtualHostNameToFolderMapping(L"ssmv.invalid", folder.wstring(), CoreWebView2HostResourceAccessKind::DenyCors);
        core.Settings().AreDevToolsEnabled(false);
        core.Settings().AreDefaultContextMenusEnabled(false);
        core.Settings().IsStatusBarEnabled(false);
        core.Settings().IsZoomControlEnabled(false);
        core.Settings().AreBrowserAcceleratorKeysEnabled(false);
        core.NavigationStarting([](auto const&, auto const& event) { if (event.Uri() != L"https://ssmv.invalid/viewer.html") event.Cancel(true); });
        core.NewWindowRequested([](auto const&, auto const& event) { event.Handled(true); });
        core.PermissionRequested([](auto const&, auto const& event) { event.State(CoreWebView2PermissionState::Deny); });
        core.AddWebResourceRequestedFilter(L"*", CoreWebView2WebResourceContext::All);
        core.WebResourceRequested([](auto const& sender, auto const& event) {
            auto uri = std::wstring(event.Request().Uri());
            if (uri.rfind(L"https://ssmv.invalid/", 0) != 0 && uri.rfind(L"data:", 0) != 0 && uri.rfind(L"blob:", 0) != 0)
                event.Response(sender.Environment().CreateWebResourceResponse(nullptr, 403, L"Forbidden", L""));
        });
        std::weak_ptr<DiagramViewer> weak = lifetime;
        core.WebMessageReceived([weak](auto const&, auto const& event) {
            if (event.Source() != L"https://ssmv.invalid/viewer.html") return;
            if (auto self = weak.lock(); self && !self->closed_) {
                try {
                    auto message = JsonObject::Parse(event.WebMessageAsJson());
                    auto action = message.GetNamedString(L"action", L"");
                    if (action == L"fullscreen") self->toggleFullscreen();
                    else if (action == L"close") self->close();
                    else if (action == L"escape") {
                        if (self->window_.AppWindow().Presenter().Kind() == Microsoft::UI::Windowing::AppWindowPresenterKind::FullScreen) self->toggleFullscreen();
                        else self->close();
                    }
                } catch (...) { /* Ignore malformed or stale page messages. */ }
            }
        });
        core.Navigate(L"https://ssmv.invalid/viewer.html");
        for (;;) {
            auto ready = browser.ExecuteScriptAsync(L"typeof window.ssmvOpenDiagram === 'function'");
            co_await bounded(ready);
            if (ready.GetResults() == L"true") break;
            if (std::chrono::steady_clock::now() >= deadline) throw std::runtime_error("The diagram viewer did not load.");
            co_await resume_after(30ms); co_await ui;
        }
        browser.Visibility(Visibility::Visible);
        browser.UpdateLayout();
        auto quoted = JsonValue::CreateStringValue(to_hstring(source)).Stringify();
        auto render = browser.ExecuteScriptAsync(L"window.ssmvViewerReady=null;window.ssmvOpenDiagram(" + quoted + (dark ? L",true" : L",false") + L").then(()=>window.ssmvViewerReady=true).catch(()=>window.ssmvViewerReady=false);");
        co_await bounded(render); render.GetResults();
        for (;;) {
            auto result = browser.ExecuteScriptAsync(L"window.ssmvViewerReady");
            co_await bounded(result);
            auto value = result.GetResults();
            if (value == L"false") throw std::runtime_error("Unable to open this diagram. Its source remains available in the document.");
            if (value == L"true") break;
            if (std::chrono::steady_clock::now() >= deadline) throw std::runtime_error("Diagram loading timed out.");
            co_await resume_after(30ms); co_await ui;
        }
        status_.Visibility(Visibility::Collapsed);
        browser.Focus(FocusState::Programmatic);
        syncFullscreen();
    } catch (...) {
        if (!closed_) {
            hstring message = L"Unable to open the diagram. Check that Microsoft Edge WebView2 Runtime is installed.";
            try { throw; }
            catch (std::exception const& error) { message = to_hstring(error.what()); }
            catch (...) {}
            if (browser_) { auto browser = browser_; browser_ = nullptr; browser.Visibility(Visibility::Collapsed); browser.Close(); }
            if (status_) { status_.Text(message); status_.Visibility(Visibility::Visible); }
        }
    }
}
}
