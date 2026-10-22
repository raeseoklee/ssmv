#pragma once
#include <memory>
#include <functional>
#include <string>
#include <vector>
#include <winrt/Windows.Foundation.h>
#include <winrt/Microsoft.UI.Dispatching.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>

namespace ssmv::ui {
struct Diagram { std::vector<uint8_t> png; double width = 0, height = 0; uint64_t decodedBytes = 0; };
// One browser per window, created only when a Mermaid block is encountered.
class Mermaid {
public:
    explicit Mermaid(winrt::Microsoft::UI::Xaml::Controls::Grid const& host) : host_(host) {}
    ~Mermaid();
    winrt::Windows::Foundation::IAsyncAction render(std::string source, bool dark, std::shared_ptr<Diagram> output, std::function<bool()> cancelled = {});
private:
    winrt::Microsoft::UI::Xaml::Controls::Grid host_;
    winrt::Microsoft::UI::Xaml::Controls::WebView2 browser_{nullptr};
    winrt::Microsoft::UI::Xaml::Controls::Canvas layer_{nullptr};
    bool busy_ = false;
    uint64_t request_ = 0;
    winrt::Microsoft::UI::Dispatching::DispatcherQueueTimer idle_{nullptr};
    void releaseBrowser();
    std::vector<std::pair<std::string, Diagram>> cache_;
};
winrt::Windows::Foundation::IAsyncAction setDiagramImage(winrt::Microsoft::UI::Xaml::Controls::Border target, Diagram diagram);
}
