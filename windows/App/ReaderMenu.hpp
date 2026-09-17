#pragma once

#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <array>
#include <functional>
#include <vector>

namespace ssmv {
struct MenuActions {
    std::function<void()> open, clipboard, saveCopy, reload, cancelLoading;
    std::function<void()> removeSelected, removeAll, reveal, close;
    std::function<void()> find, findNext, findPrevious, copyDocument;
    std::function<void()> increaseSize, decreaseSize, resetSize;
    std::function<void()> toggleSidebar, toggleOutline, fullscreen;
    std::function<void(int)> setTheme;
    std::function<void(bool)> sort;
};

struct ReaderMenu {
    winrt::Microsoft::UI::Xaml::Controls::MenuBar bar{nullptr};
    winrt::Microsoft::UI::Xaml::Controls::ToggleMenuFlyoutItem sidebar{nullptr}, outline{nullptr};
    std::array<winrt::Microsoft::UI::Xaml::Controls::RadioMenuFlyoutItem, 3> themes{nullptr, nullptr, nullptr};
    std::vector<winrt::Microsoft::UI::Xaml::Controls::MenuFlyoutItem> documentCommands;
    void update(int theme, bool sidebarShown, bool outlineShown, bool hasDocument);
};

ReaderMenu makeReaderMenu(MenuActions actions);
}
