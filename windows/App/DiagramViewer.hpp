#pragma once
#include <memory>
#include <string>
#include <winrt/Windows.Foundation.h>
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>

namespace ssmv::ui {
// A single, explicitly opened interactive browser; ordinary document rendering stays native.
class DiagramViewer : public std::enable_shared_from_this<DiagramViewer> {
public:
    static std::shared_ptr<DiagramViewer> open(std::string source, bool dark);
    ~DiagramViewer();
    void close();
private:
    winrt::Microsoft::UI::Xaml::Window window_{nullptr};
    winrt::Microsoft::UI::Xaml::Controls::WebView2 browser_{nullptr};
    winrt::Microsoft::UI::Xaml::Controls::TextBlock status_{nullptr};
    bool closed_ = false;
    void dispose();
    void toggleFullscreen();
    winrt::fire_and_forget load(std::string source, bool dark);
    winrt::fire_and_forget syncFullscreen();
};
}
