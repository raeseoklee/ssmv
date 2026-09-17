#pragma once
#include "Markdown.hpp"
#include <functional>
#include <string>
#include <winrt/Microsoft.UI.Xaml.h>

namespace ssmv {
winrt::Microsoft::UI::Xaml::FrameworkElement renderBlock(
    Block const& block, double fontSize, std::function<void(std::string)> navigate);
}
