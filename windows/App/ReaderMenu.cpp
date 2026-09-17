#include "ReaderMenu.hpp"
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Microsoft.UI.Xaml.Input.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.System.h>
#include <algorithm>
#include <utility>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
using namespace Microsoft::UI::Xaml::Input;
using namespace Windows::System;

namespace ssmv {
namespace {
void identify(DependencyObject const& item, hstring const& id) {
    Automation::AutomationProperties::SetAutomationId(item, id);
}

void shortcut(MenuFlyoutItem const& item, VirtualKey key,
              VirtualKeyModifiers modifiers, hstring const& text) {
    KeyboardAccelerator accelerator;
    accelerator.Key(key);
    accelerator.Modifiers(modifiers);
    // MenuFlyoutItem invokes its Click action through native accelerator handling.
    item.KeyboardAccelerators().Append(accelerator);
    item.KeyboardAcceleratorTextOverride(text);
    Automation::AutomationProperties::SetAcceleratorKey(item, text);
}

MenuFlyoutItem command(hstring const& text, hstring const& id,
                       std::function<void()> action, wchar_t const* glyph = nullptr) {
    MenuFlyoutItem item;
    item.Text(text);
    identify(item, id);
    if (glyph) {
        FontIcon icon;
        icon.Glyph(glyph);
        icon.FontSize(16);
        item.Icon(icon);
    }
    item.Click([action = std::move(action)](auto const&, auto const&) {
        if (action) action();
    });
    return item;
}

MenuBarItem menu(hstring const& text, hstring const& accessKey, hstring const& id) {
    MenuBarItem item;
    item.Title(text);
    item.AccessKey(accessKey);
    identify(item, id);
    return item;
}
}

void ReaderMenu::update(int theme, bool sidebarShown, bool outlineShown, bool hasDocument) {
    if (!bar) return;
    sidebar.IsChecked(sidebarShown);
    outline.IsChecked(outlineShown);
    auto selectedTheme = std::clamp(theme, 0, 2);
    for (size_t index = 0; index < themes.size(); ++index)
        themes[index].IsChecked(static_cast<int>(index) == selectedTheme);
    for (auto const& item : documentCommands) item.IsEnabled(hasDocument);
}

ReaderMenu makeReaderMenu(MenuActions actions) {
    ReaderMenu result;
    result.bar = MenuBar();
    result.bar.Padding({8, 0, 8, 0});
    identify(result.bar, L"reader.menu");
    auto file = menu(L"File", L"F", L"menu.file");
    auto edit = menu(L"Edit", L"E", L"menu.edit");
    auto view = menu(L"View", L"V", L"menu.view");
    auto const control = VirtualKeyModifiers::Control;
    auto const controlShift = control | VirtualKeyModifiers::Shift;
    auto add = [&](MenuBarItem const& group, MenuFlyoutItem item, bool needsDocument = false) {
        group.Items().Append(item);
        if (needsDocument) result.documentCommands.push_back(item);
        return item;
    };
    auto item = add(file, command(L"Open…", L"action.open", actions.open, L"\uE8E5"));
    shortcut(item, VirtualKey::O, control, L"Ctrl+O");
    item = add(file, command(L"Open from Clipboard", L"action.clipboard", actions.clipboard, L"\uE77F"));
    shortcut(item, VirtualKey::V, controlShift, L"Ctrl+Shift+V");
    file.Items().Append(MenuFlyoutSeparator());
    item = add(file, command(L"Save a Copy…", L"action.saveCopy", actions.saveCopy, L"\uE74E"), true);
    shortcut(item, VirtualKey::S, controlShift, L"Ctrl+Shift+S");
    item = add(file, command(L"Reload", L"action.reload", actions.reload, L"\uE72C"), true);
    shortcut(item, VirtualKey::R, control, L"Ctrl+R");
    add(file, command(L"Show in File Explorer", L"action.reveal", actions.reveal, L"\uE838"), true);
    add(file, command(L"Cancel Loading", L"action.cancelLoading", actions.cancelLoading));
    file.Items().Append(MenuFlyoutSeparator());
    item = add(file, command(L"Remove Document", L"action.removeSelected", actions.removeSelected, L"\uE738"), true);
    shortcut(item, VirtualKey::W, control, L"Ctrl+W");
    add(file, command(L"Remove All Documents…", L"action.removeAll", actions.removeAll));
    file.Items().Append(MenuFlyoutSeparator());
    item = add(file, command(L"Exit", L"action.close", actions.close));
    item.KeyboardAcceleratorTextOverride(L"Alt+F4"); // Owned by the native window.

    item = add(edit, command(L"Find…", L"action.find", actions.find, L"\uE721"), true);
    shortcut(item, VirtualKey::F, control, L"Ctrl+F");
    item = add(edit, command(L"Find Next", L"action.findNext", actions.findNext), true);
    shortcut(item, VirtualKey::F3, VirtualKeyModifiers::None, L"F3");
    item = add(edit, command(L"Find Previous", L"action.findPrevious", actions.findPrevious), true);
    shortcut(item, VirtualKey::F3, VirtualKeyModifiers::Shift, L"Shift+F3");
    edit.Items().Append(MenuFlyoutSeparator());
    item = add(edit, command(L"Copy Document Text", L"action.copyDocument", actions.copyDocument, L"\uE8C8"), true);
    shortcut(item, VirtualKey::C, controlShift, L"Ctrl+Shift+C");

    result.sidebar = ToggleMenuFlyoutItem();
    result.sidebar.Text(L"Sidebar");
    identify(result.sidebar, L"action.toggleSidebar");
    result.sidebar.Click([action = actions.toggleSidebar](auto const&, auto const&) { if (action) action(); });
    shortcut(result.sidebar, VirtualKey::L, controlShift, L"Ctrl+Shift+L");
    view.Items().Append(result.sidebar);
    result.outline = ToggleMenuFlyoutItem();
    result.outline.Text(L"Document Outline");
    identify(result.outline, L"action.toggleOutline");
    result.outline.Click([action = actions.toggleOutline](auto const&, auto const&) { if (action) action(); });
    shortcut(result.outline, VirtualKey::O, controlShift, L"Ctrl+Shift+O");
    view.Items().Append(result.outline);
    MenuFlyoutSubItem sort;
    sort.Text(L"Sort Documents");
    sort.Items().Append(command(L"Name, A to Z", L"action.sortAscending", [action = actions.sort] { if (action) action(true); }));
    sort.Items().Append(command(L"Name, Z to A", L"action.sortDescending", [action = actions.sort] { if (action) action(false); }));
    view.Items().Append(sort);
    view.Items().Append(MenuFlyoutSeparator());
    item = add(view, command(L"Increase Text Size", L"action.increaseSize", actions.increaseSize, L"\uE8A3"), true);
    shortcut(item, VirtualKey::Add, control, L"Ctrl++");
    item = add(view, command(L"Decrease Text Size", L"action.decreaseSize", actions.decreaseSize, L"\uE71F"), true);
    shortcut(item, VirtualKey::Subtract, control, L"Ctrl+−");
    item = add(view, command(L"Actual Text Size", L"action.resetSize", actions.resetSize), true);
    shortcut(item, VirtualKey::Number0, control, L"Ctrl+0");
    MenuFlyoutSubItem appearance;
    appearance.Text(L"Appearance");
    identify(appearance, L"menu.appearance");
    std::array<hstring, 3> const names{L"System", L"Light", L"Dark"};
    std::array<hstring, 3> const ids{L"theme.system", L"theme.light", L"theme.dark"};
    for (size_t index = 0; index < result.themes.size(); ++index) {
        RadioMenuFlyoutItem radio;
        radio.Text(names[index]);
        radio.GroupName(L"SSMV.Appearance");
        identify(radio, ids[index]);
        radio.Click([action = actions.setTheme, index](auto const&, auto const&) {
            if (action) action(static_cast<int>(index));
        });
        result.themes[index] = radio;
        appearance.Items().Append(radio);
    }
    view.Items().Append(appearance);
    view.Items().Append(MenuFlyoutSeparator());
    item = add(view, command(L"Full Screen", L"action.fullscreen", actions.fullscreen, L"\uE740"));
    shortcut(item, VirtualKey::F11, VirtualKeyModifiers::None, L"F11");
    result.bar.Items().Append(file);
    result.bar.Items().Append(edit);
    result.bar.Items().Append(view);
    result.update(0, true, true, false);
    return result;
}
}
