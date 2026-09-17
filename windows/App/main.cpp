#include <windows.h>
#undef GetCurrentTime
#include <shellapi.h>
#include <shobjidl.h>
#include <shlobj.h>
#include <microsoft.ui.xaml.window.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.ApplicationModel.DataTransfer.h>
#include <winrt/Windows.Storage.h>
#include <winrt/Windows.Storage.Pickers.h>
#include <winrt/Windows.System.h>
#include <winrt/Windows.UI.Text.h>
#include <winrt/Windows.UI.h>
#include <winrt/Windows.UI.Core.h>
#include <winrt/Windows.Graphics.h>
#include <winrt/Windows.UI.Xaml.Interop.h>
#include <winrt/Microsoft.UI.Xaml.Markup.h>
#include <winrt/Microsoft.UI.Xaml.XamlTypeInfo.h>
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include <winrt/Microsoft.UI.Xaml.Input.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>
#include "Documents.hpp"
#include "Session.hpp"
#include "MarkdownView.hpp"
#include "Activation.hpp"
#include "ReaderMenu.hpp"
#include "DocumentTree.hpp"
#include "RemoteDocument.hpp"
#include "PdfExport.hpp"
#include <atomic>
#include <chrono>
#include <winrt/Microsoft.UI.Dispatching.h>
#include <winrt/Microsoft.UI.Input.h>
#include <winrt/Microsoft.UI.Windowing.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Windows.Storage.Streams.h>
#include <algorithm>
#include <optional>
#include <deque>
#include <set>
#include <vector>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
using namespace Microsoft::UI::Xaml::Controls::Primitives;
using namespace Microsoft::UI::Xaml::Input;
using namespace Windows::Foundation;
using namespace Windows::Storage;
using namespace Windows::ApplicationModel::DataTransfer;

namespace {
constexpr size_t maxRenderedBlocks = 2000;

IAsyncAction writeDocument(std::filesystem::path path, std::string bytes) {
    co_await resume_background();
    ssmv::writeFileAtomically(path, bytes);
}

TextBlock label(hstring const& text, double size = 14) {
    TextBlock result;
    result.Text(text);
    result.FontSize(size);
    result.TextWrapping(TextWrapping::Wrap);
    return result;
}

Viewbox smallIcon(Symbol symbol) {
    Viewbox box; box.Width(16); box.Height(16);
    box.Child(SymbolIcon{symbol}); return box;
}

struct App : ApplicationT<App, Markup::IXamlMetadataProvider> {
    XamlTypeInfo::XamlControlsXamlMetaDataProvider metadata;
    Markup::IXamlType GetXamlType(Windows::UI::Xaml::Interop::TypeName const& type) { return metadata.GetXamlType(type); }
    Markup::IXamlType GetXamlType(hstring const& name) { return metadata.GetXamlType(name); }
    com_array<Markup::XmlnsDefinition> GetXmlnsDefinitions() { return metadata.GetXmlnsDefinitions(); }
    ssmv::Activation* activation;
    explicit App(ssmv::Activation* input) : activation(input) {}
    ssmv::Session session;
    std::filesystem::path dataDirectory;
    bool sessionWritable = true;
    bool restoring = false;
    bool initialized = false;
    double fontSize = 16;
    ssmv::ReaderMenu menus;
    int themeIndex = 0;
    TextBox findBox{nullptr};
    StackPanel findPanel{nullptr};
    TextBlock findStatus{nullptr};
    std::vector<size_t> matches;
    size_t matchIndex = 0;
    std::filesystem::path searchPath;
    Window window{nullptr};
    Grid root{nullptr};
    SplitView split{nullptr};
    std::unique_ptr<ssmv::DocumentTree> documentTree;
    Button removeButton{nullptr};
    StackPanel content{nullptr};
    ScrollViewer scroll{nullptr};
    TextBlock status{nullptr};
    ToggleButton outline{nullptr};
    ssmv::DocumentLibrary library;
    std::optional<size_t> selected;
    uint64_t generation = 0;
    bool closed = false;
    bool dialogOpen = false;
    bool importingClipboard = false;
    std::vector<FrameworkElement> rendered;
    size_t renderStart = 0;
    uint64_t renderRevision = 0;
    std::deque<std::vector<std::filesystem::path>> pendingLoads;
    bool loading = false;
    std::shared_ptr<std::atomic_bool> remoteCancellation, pdfCancellation;
    DispatcherTimer navigationTimer{nullptr};
    Border highlightedBlock{nullptr};
    std::set<std::filesystem::path> expandedPaths;

    Button button(hstring const& title, auto action) {
        Button result;
        result.Content(box_value(title));
        result.Click([this, action](auto const&, auto const&) {
            try { action(); }
            catch (hresult_error const& e) { error(e.message()); }
            catch (std::exception const& e) { error(to_hstring(e.what())); }
        });
        return result;
    }

    void styleIcon(Control const& control, hstring const& name, hstring const& tip) {
        control.Width(28); control.Height(28); control.Padding({5, 5, 5, 5});
        control.BorderThickness({0, 0, 0, 0}); control.CornerRadius({4, 4, 4, 4});
        control.Background(Media::SolidColorBrush(Windows::UI::Color{0, 0, 0, 0}));
        Automation::AutomationProperties::SetName(control, name);
        ToolTipService::SetToolTip(control, box_value(tip));
    }
    Button iconButton(Symbol symbol, hstring const& name, hstring const& tip, auto action) {
        auto result = button(name, action);
        result.Content(smallIcon(symbol)); styleIcon(result, name, tip); return result;
    }
    void syncChrome() {
        bool hasDocument = selected && *selected < library.documents().size();
        if (split && outline) menus.update(themeIndex, split.IsPaneOpen(), outline.IsChecked().Value(), hasDocument);
        if (removeButton) removeButton.IsEnabled(hasDocument);
    }
    void toggleSidebar() { split.IsPaneOpen(!split.IsPaneOpen()); syncChrome(); saveState(); }
    void setTheme(int value) {
        themeIndex = value;
        root.RequestedTheme(value == 1 ? ElementTheme::Light : value == 2 ? ElementTheme::Dark : ElementTheme::Default);
        syncChrome(); saveState();
    }

    void error(hstring const& message) {
        if (!closed && status) status.Text(message);
    }

    void OnLaunched(LaunchActivatedEventArgs const&) {
        Resources().MergedDictionaries().Append(XamlControlsResources());
        window = Window();
        window.Title(L"So Simple Markdown Viewer");
        window.AppWindow().Resize({1000, 720});
        HWND nativeWindow = nullptr;
        check_hresult(window.as<IWindowNative>()->get_WindowHandle(&nativeWindow));
        auto module = GetModuleHandleW(nullptr);
        auto bigIcon = LoadImageW(module, MAKEINTRESOURCEW(1), IMAGE_ICON, 32, 32, LR_SHARED);
        auto nativeSmallIcon = LoadImageW(module, MAKEINTRESOURCEW(1), IMAGE_ICON, 16, 16, LR_SHARED);
        SendMessageW(nativeWindow, WM_SETICON, ICON_BIG, reinterpret_cast<LPARAM>(bigIcon));
        SendMessageW(nativeWindow, WM_SETICON, ICON_SMALL, reinterpret_cast<LPARAM>(nativeSmallIcon));
        window.Closed([this](auto const&, auto const&) {
            rememberPosition(); saveState(); activation->stop(); closed = true; ++generation;
            cancelTransfers(); clearNavigationHighlight();
        });
        wchar_t location[32768]{};
        auto length = GetEnvironmentVariableW(L"SSMV_DATA_DIR", location, 32768);
        if (length && length < 32768) dataDirectory = location;
        else {
            PWSTR local = nullptr;
            check_hresult(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &local));
            dataDirectory = std::filesystem::path(local) / L"SSMV";
            CoTaskMemFree(local);
        }
        std::string sessionError;
        try { if (auto saved = ssmv::readSession(dataDirectory / L"session.bin")) session = *saved; }
        catch (std::exception const& e) { sessionWritable = false; sessionError = e.what(); }
        fontSize = std::clamp(session.fontSize, 10.0, 32.0);
        for (auto const& path : session.expandedPaths) expandedPaths.insert(std::filesystem::path(to_hstring(path).c_str()));
        root = Grid();
        root.AllowDrop(true);
        auto updateBackground = [this] {
            auto dark = root.ActualTheme() == ElementTheme::Dark;
            root.Background(Media::SolidColorBrush(dark ? Windows::UI::Color{255, 32, 32, 32} : Windows::UI::Color{255, 250, 250, 250}));
            using Microsoft::UI::Windowing::TitleBarTheme;
            window.AppWindow().TitleBar().PreferredTheme(dark ? TitleBarTheme::Dark : TitleBarTheme::Light);
        };
        root.ActualThemeChanged([updateBackground](auto const&, auto const&) { updateBackground(); });
        updateBackground();
        root.DragOver([](auto const&, DragEventArgs const& args) {
            if (args.DataView().Contains(StandardDataFormats::StorageItems())) {
                args.AcceptedOperation(DataPackageOperation::Copy);
                args.Handled(true);
            }
        });
        root.Drop([this](auto const&, DragEventArgs const& args) { drop(args); });
        RowDefinition toolbarRow; toolbarRow.Height({0, GridUnitType::Auto});
        RowDefinition bodyRow; bodyRow.Height({1, GridUnitType::Star});
        RowDefinition statusRow; statusRow.Height({0, GridUnitType::Auto});
        root.RowDefinitions().Append(toolbarRow);
        RowDefinition findRow; findRow.Height({0, GridUnitType::Auto});
        root.RowDefinitions().Append(findRow);
        root.RowDefinitions().Append(bodyRow);
        root.RowDefinitions().Append(statusRow);

        themeIndex = static_cast<int>(session.theme);
        root.RequestedTheme(themeIndex == 1 ? ElementTheme::Light : themeIndex == 2 ? ElementTheme::Dark : ElementTheme::Default);
        auto guarded = [this](auto action) {
            return [this, action](auto... args) {
                try { action(args...); }
                catch (hresult_error const& e) { error(e.message()); }
                catch (std::exception const& e) { error(to_hstring(e.what())); }
            };
        };
        ssmv::MenuActions actions;
        actions.open = guarded([this] { pick(); });
        actions.openURL = guarded([this] { openURLDialog(); });
        actions.exportPDF = guarded([this] { exportPDF(); });
        actions.clipboard = guarded([this] { openClipboard(); });
        actions.saveCopy = guarded([this] { saveCopy(); });
        actions.reload = guarded([this] { reload(); });
        actions.cancelLoading = guarded([this] { ++generation; pendingLoads.clear(); restoring = false; cancelTransfers(); error(L"Operation canceled."); });
        actions.removeSelected = guarded([this] { removeSelected(); });
        actions.removeAll = guarded([this] { removeAll(); });
        actions.reveal = guarded([this] { reveal(); });
        actions.close = guarded([this] { window.Close(); });
        actions.find = guarded([this] { showFind(); });
        actions.findNext = guarded([this] { findNext(false); });
        actions.findPrevious = guarded([this] { findNext(true); });
        actions.copyDocument = guarded([this] { copyDocument(); });
        actions.increaseSize = guarded([this] { changeSize(1); });
        actions.decreaseSize = guarded([this] { changeSize(-1); });
        actions.resetSize = guarded([this] { changeSize(0); });
        actions.toggleSidebar = guarded([this] { toggleSidebar(); });
        actions.toggleOutline = guarded([this] { outline.IsChecked(!outline.IsChecked().Value()); rebuildShelf(); saveState(); syncChrome(); });
        actions.fullscreen = guarded([this] { toggleFullscreen(); });
        actions.setTheme = guarded([this](int value) { setTheme(value); });
        actions.sort = guarded([this](bool ascending) { sort(ascending); });
        menus = ssmv::makeReaderMenu(std::move(actions));
        Grid chrome;
        ColumnDefinition menuColumn; menuColumn.Width({1, GridUnitType::Star});
        ColumnDefinition iconsColumn; iconsColumn.Width({0, GridUnitType::Auto});
        chrome.ColumnDefinitions().Append(menuColumn); chrome.ColumnDefinitions().Append(iconsColumn);
        chrome.Children().Append(menus.bar);
        StackPanel shortcuts; shortcuts.Orientation(Orientation::Horizontal); shortcuts.Spacing(4);
        shortcuts.Margin({0, 2, 12, 2});
        shortcuts.Children().Append(iconButton(Symbol::OpenPane, L"Toggle sidebar", L"Toggle sidebar (Ctrl+Shift+L)", [this] { toggleSidebar(); }));
        shortcuts.Children().Append(iconButton(Symbol::OpenFile, L"Open documents", L"Open documents (Ctrl+O)", [this] { pick(); }));
        Grid::SetColumn(shortcuts, 1); chrome.Children().Append(shortcuts);
        root.Children().Append(chrome);
        findPanel = StackPanel(); findPanel.Orientation(Orientation::Horizontal); findPanel.Spacing(8);
        findPanel.Margin({12, 0, 12, 8}); findPanel.Visibility(Visibility::Collapsed);
        findBox = TextBox(); findBox.Width(260); findBox.PlaceholderText(L"Find in document");
        findBox.MaxLength(512);
        Automation::AutomationProperties::SetAutomationId(findBox, L"FindBox");
        findBox.KeyDown([this](auto const&, KeyRoutedEventArgs const& args) {
            if (args.Key() == Windows::System::VirtualKey::Enter) { findNext(false); args.Handled(true); }
        });
        findPanel.Children().Append(findBox);
        findPanel.Children().Append(iconButton(Symbol::Back, L"Previous", L"Previous match (Shift+F3)", [this] { findNext(true); }));
        findPanel.Children().Append(iconButton(Symbol::Forward, L"Next", L"Next match (F3)", [this] { findNext(false); }));
        findPanel.Children().Append(iconButton(Symbol::Cancel, L"Close search", L"Close search (Esc)", [this] { findPanel.Visibility(Visibility::Collapsed); }));
        findStatus = label(L""); findPanel.Children().Append(findStatus);
        Grid::SetRow(findPanel, 1); root.Children().Append(findPanel);

        split = SplitView();
        split.DisplayMode(SplitViewDisplayMode::Inline);
        split.OpenPaneLength(280);
        split.IsPaneOpen(session.sidebarVisible);
        Grid::SetRow(split, 2);
        root.Children().Append(split);

        Grid pane;
        RowDefinition headerRow; headerRow.Height({0, GridUnitType::Auto});
        RowDefinition filesRow; filesRow.Height({1, GridUnitType::Star});
        pane.RowDefinitions().Append(headerRow);
        pane.RowDefinitions().Append(filesRow);
        Grid header;
        header.Margin({16, 8, 12, 6});
        ColumnDefinition titleColumn; titleColumn.Width({1, GridUnitType::Star});
        ColumnDefinition actionsColumn; actionsColumn.Width({0, GridUnitType::Auto});
        header.ColumnDefinitions().Append(titleColumn); header.ColumnDefinitions().Append(actionsColumn);
        auto heading = label(L"Documents", 13);
        heading.FontWeight(Windows::UI::Text::FontWeights::SemiBold()); heading.Opacity(.7);
        heading.VerticalAlignment(VerticalAlignment::Center); header.Children().Append(heading);
        StackPanel shelfActions; shelfActions.Orientation(Orientation::Horizontal); shelfActions.Spacing(2);
        shelfActions.Children().Append(iconButton(Symbol::Add, L"Add documents", L"Add documents (Ctrl+O)", [this] { pick(); }));
        removeButton = iconButton(Symbol::Remove, L"Remove document", L"Remove document (Ctrl+W). Right-click for Remove All.", [this] { removeSelected(); });
        MenuFlyout removeActions;
        MenuFlyoutItem clear; clear.Text(L"Remove All Documents…");
        clear.Click([this](auto const&, auto const&) { removeAll(); }); removeActions.Items().Append(clear);
        removeButton.ContextFlyout(removeActions);
        shelfActions.Children().Append(removeButton);
        outline = ToggleButton();
        outline.Content(smallIcon(Symbol::Bullets)); styleIcon(outline, L"Document outline", L"Show or hide document outlines (Ctrl+Shift+O)");
        for (bool dark : {false, true}) {
            ResourceDictionary colors;
            auto foreground = Media::SolidColorBrush(dark ? Windows::UI::Color{255, 240, 240, 240} : Windows::UI::Color{255, 35, 35, 35});
            for (auto key : {L"ToggleButtonForegroundChecked", L"ToggleButtonForegroundCheckedPointerOver", L"ToggleButtonForegroundCheckedPressed"}) colors.Insert(box_value(key), foreground);
            for (auto key : {L"ToggleButtonBackgroundChecked", L"ToggleButtonBackgroundCheckedPointerOver", L"ToggleButtonBackgroundCheckedPressed"})
                colors.Insert(box_value(key), Media::SolidColorBrush(dark ? Windows::UI::Color{255, 70, 70, 70} : Windows::UI::Color{255, 218, 218, 218}));
            outline.Resources().ThemeDictionaries().Insert(box_value(dark ? L"Dark" : L"Light"), colors);
        }
        outline.IsChecked(session.outlineEnabled);
        outline.Click([this](auto const&, auto const&) { rebuildShelf(); saveState(); syncChrome(); });
        shelfActions.Children().Append(outline);
        Grid::SetColumn(shelfActions, 1); header.Children().Append(shelfActions);
        pane.Children().Append(header);
        documentTree = std::make_unique<ssmv::DocumentTree>();
        documentTree->view.Margin({6, 0, 6, 8});
        documentTree->selected = guarded([this](size_t index, std::optional<size_t> block) {
            if (index >= library.documents().size()) return;
            rememberPosition(); selected = index;
            if (block) renderStart = *block / maxRenderedBlocks * maxRenderedBlocks;
            else restorePage();
            render();
            if (block) showNavigationTarget(*block);
            else restoreScroll();
            saveState();
        });
        documentTree->expanded = guarded([this](std::filesystem::path path, bool expanded) {
            if (expanded) expandedPaths.insert(path); else expandedPaths.erase(path);
            saveState();
        });
        Grid::SetRow(documentTree->view, 1); pane.Children().Append(documentTree->view);
        MenuFlyout menu;
        auto item = [this, menu](hstring const& name, auto action) {
            MenuFlyoutItem entry;
            entry.Text(name);
            entry.Click([this, action](auto const&, auto const&) {
                try { action(); }
                catch (std::exception const& e) { error(to_hstring(e.what())); }
                catch (hresult_error const& e) { error(e.message()); }
            });
            menu.Items().Append(entry);
        };
        item(L"Sort by name (A–Z)", [this] { sort(true); });
        item(L"Sort by name (Z–A)", [this] { sort(false); });
        menu.Items().Append(MenuFlyoutSeparator());
        item(L"Remove selected", [this] { removeSelected(); });
        item(L"Remove all…", [this] { removeAll(); });
        pane.ContextFlyout(menu);
        split.Pane(pane);

        scroll = ScrollViewer();
        Automation::AutomationProperties::SetAutomationId(scroll, L"ReaderScroll");
        scroll.HorizontalScrollBarVisibility(ScrollBarVisibility::Disabled);
        content = StackPanel();
        content.Spacing(10);
        content.Margin({28, 20, 28, 28});
        content.MaxWidth(1100);
        content.HorizontalAlignment(HorizontalAlignment::Stretch);
        scroll.Content(content);
        split.Content(scroll);
        status = label(L"Open Markdown files or drop them anywhere in this window.");
        status.Margin({12, 4, 12, 6});
        status.FontSize(11); status.Opacity(.65);
        status.TextWrapping(TextWrapping::NoWrap); status.TextTrimming(TextTrimming::CharacterEllipsis);
        Grid::SetRow(status, 3);
        root.Children().Append(status);
        // OEM minus has no WinUI accelerator label and fails fast during tooltip
        // generation, even on the root. Handle that key without an accelerator.
        auto alias = [this](Windows::System::VirtualKey key, Windows::System::VirtualKeyModifiers modifiers, auto action) {
            KeyboardAccelerator binding; binding.Key(key); binding.Modifiers(modifiers);
            binding.Invoked([action](auto const&, auto const& args) { args.Handled(true); action(); });
            root.KeyboardAccelerators().Append(binding);
        };
        alias(static_cast<Windows::System::VirtualKey>(187), Windows::System::VirtualKeyModifiers::Control, guarded([this] { changeSize(1); }));
        alias(static_cast<Windows::System::VirtualKey>(187), Windows::System::VirtualKeyModifiers::Control | Windows::System::VirtualKeyModifiers::Shift, guarded([this] { changeSize(1); }));
        root.KeyDown([decrease = guarded([this] { changeSize(-1); })](auto const&, KeyRoutedEventArgs const& args) {
            using Windows::System::VirtualKey;
            using Windows::UI::Core::CoreVirtualKeyStates;
            auto down = [](VirtualKey key) {
                return (Microsoft::UI::Input::InputKeyboardSource::GetKeyStateForCurrentThread(key) & CoreVirtualKeyStates::Down) != CoreVirtualKeyStates::None;
            };
            if (args.Key() == static_cast<VirtualKey>(189) && down(VirtualKey::Control) && !down(VirtualKey::Menu) && !down(VirtualKey::Shift)) {
                args.Handled(true); decrease();
            }
        });
        alias(Windows::System::VirtualKey::Escape, Windows::System::VirtualKeyModifiers::None, guarded([this] { findPanel.Visibility(Visibility::Collapsed); }));
        syncChrome();
        window.Content(root);
        window.Activate();
        render();
        initialized = true;
        if (!sessionError.empty()) error(L"Session could not be restored; automatic saving is disabled. " + to_hstring(sessionError));
        std::vector<std::filesystem::path> restoredPaths;
        for (auto const& savedDocument : session.documents) restoredPaths.emplace_back(to_hstring(savedDocument.path).c_str());
        if (!restoredPaths.empty()) { restoring = true; load(std::move(restoredPaths)); }
        activation->attach(window.DispatcherQueue(), [this](auto paths) {
            if (closed) return;
            if (!paths.empty()) load(std::move(paths));
            window.Activate();
        });
    }

    fire_and_forget pick() {
        auto lifetime = get_strong();
        try {
            Windows::Storage::Pickers::FileOpenPicker picker;
            HWND hwnd = nullptr;
            check_hresult(window.as<IWindowNative>()->get_WindowHandle(&hwnd));
            check_hresult(picker.as<IInitializeWithWindow>()->Initialize(hwnd));
            picker.FileTypeFilter().Append(L".md");
            picker.FileTypeFilter().Append(L".markdown");
            picker.FileTypeFilter().Append(L".mdown");
            auto files = co_await picker.PickMultipleFilesAsync();
            std::vector<std::filesystem::path> paths;
            for (auto const& file : files) paths.emplace_back(file.Path().c_str());
            if (!closed && !paths.empty()) load(std::move(paths));
        } catch (hresult_error const& e) { error(e.message()); }
        catch (std::exception const& e) { error(to_hstring(e.what())); }
    }

    fire_and_forget drop(DragEventArgs args) {
        auto lifetime = get_strong();
        DragOperationDeferral deferral{nullptr};
        try {
            deferral = args.GetDeferral();
            args.Handled(true);
            if (args.DataView().Contains(StandardDataFormats::StorageItems())) {
                auto items = co_await args.DataView().GetStorageItemsAsync();
                std::vector<std::filesystem::path> paths;
                for (auto const& item : items) {
                    if (item.IsOfType(StorageItemTypes::File)) paths.emplace_back(item.Path().c_str());
                }
                if (!closed && !paths.empty()) load(std::move(paths));
            }
        } catch (hresult_error const& e) { error(e.message()); }
        catch (std::exception const& e) { error(to_hstring(e.what())); }
        if (deferral) deferral.Complete();
    }

    void load(std::vector<std::filesystem::path> paths) {
        rememberPosition();
        pendingLoads.push_back(std::move(paths));
        if (!loading) processLoads();
    }

    fire_and_forget processLoads() {
        auto lifetime = get_strong();
        apartment_context ui;
        loading = true;
        while (!closed && !pendingLoads.empty()) {
            auto paths = std::move(pendingLoads.front());
            pendingLoads.pop_front();
            auto request = generation;
            std::vector<ssmv::Document> loaded;
            std::string failures;
            try {
                status.Text(L"Loading Markdown…");
                co_await resume_background();
                for (auto const& path : paths) {
                    try { loaded.push_back(ssmv::readDocument(path)); }
                    catch (std::exception const& e) {
                        if (!failures.empty()) failures += "\n";
                        failures += e.what();
                    }
                }
            } catch (std::exception const& e) { failures = e.what(); }
            catch (...) { failures = "Could not read the selected files."; }
            try {
                co_await ui;
                if (closed || request != generation) continue;
                lastQuery = L""; ++searchGeneration;
                for (auto& document : loaded) {
                    auto path = pathText(document.path);
                    bool registered = std::any_of(session.documents.begin(), session.documents.end(), [&](auto const& item) { return item.path == path; });
                    if (!registered && session.documents.size() >= ssmv::MaxSessionDocuments) { failures = "The document list is full. Clear missing entries before adding files."; continue; }
                    if (!registered) session.documents.push_back({path, 0, 0});
                    selected = library.insert(std::move(document));
                }
                if (restoring) {
                    for (size_t i = 0; i < library.documents().size(); ++i)
                        if (pathText(library.documents()[i].path) == session.selectedPath) selected = i;
                    restoring = false;
                }
                restorePage();
                rebuildShelf();
                render();
                restoreScroll(); saveState();
                if (!failures.empty()) error(to_hstring(failures));
            } catch (hresult_error const& e) { error(e.message()); }
            catch (std::exception const& e) { error(to_hstring(e.what())); }
        }
        loading = false;
    }

    void rebuildShelf() {
        documentTree->update(library, selected, outline.IsChecked().Value(), expandedPaths);
        syncChrome();
    }

    void render() {
        syncChrome();
        clearNavigationHighlight();
        ++renderRevision;
        content.Children().Clear();
        rendered.clear();
        if (!selected || *selected >= library.documents().size()) {
            selected.reset();
            window.Title(L"So Simple Markdown Viewer");
            content.Children().Append(label(L"Open a Markdown document", 28));
            status.Text(L"Drop files here, or press Ctrl+O.");
            return;
        }
        auto const& document = library.documents()[*selected];
        window.Title(hstring(document.path.filename().wstring()) + L" — SSMV");
        auto count = document.markdown.blocks.size();
        if (renderStart >= count) renderStart = 0;
        if (renderStart > 0) content.Children().Append(button(L"Previous part", [this] {
            renderStart = renderStart >= maxRenderedBlocks ? renderStart - maxRenderedBlocks : 0;
            render();
        }));
        auto end = std::min(count, renderStart + maxRenderedBlocks);
        for (size_t index = renderStart; index < end; ++index) {
            auto const& block = document.markdown.blocks[index];
            auto element = ssmv::renderBlock(block, fontSize, [this](std::string destination) { navigateLink(std::move(destination)); });
            Border wrapper; wrapper.Child(element); wrapper.CornerRadius({4, 4, 4, 4});
            Automation::AutomationProperties::SetAutomationId(wrapper, L"reader.block." + to_hstring(index));
            rendered.push_back(wrapper);
            content.Children().Append(wrapper);
        }
        scroll.ChangeView(nullptr, 0.0, nullptr);
        if (end < count) content.Children().Append(button(L"Continue reading", [this, end] {
            renderStart = end;
            render();
        }));
        if (count > maxRenderedBlocks) {
            status.Text(L"Part " + to_hstring(renderStart / maxRenderedBlocks + 1) + L" of " +
                        to_hstring((count + maxRenderedBlocks - 1) / maxRenderedBlocks));
        } else status.Text(hstring(document.path.filename().wstring()));
        ToolTipService::SetToolTip(status, box_value(document.path.wstring()));
    }

    void clearNavigationHighlight() {
        if (navigationTimer) navigationTimer.Stop();
        if (scroll) Automation::AutomationProperties::SetHelpText(scroll, L"");
        if (highlightedBlock) {
            highlightedBlock.Background(nullptr);
            Automation::AutomationProperties::SetHelpText(highlightedBlock, L"");
            highlightedBlock = nullptr;
        }
    }

    void showNavigationTarget(size_t index) {
        if (index < renderStart || index - renderStart >= rendered.size()) return;
        clearNavigationHighlight();
        highlightedBlock = rendered[index - renderStart].as<Border>();
        highlightedBlock.Background(Media::SolidColorBrush(root.ActualTheme() == ElementTheme::Dark
            ? Windows::UI::Color{255, 91, 76, 30} : Windows::UI::Color{255, 255, 238, 173}));
        Automation::AutomationProperties::SetHelpText(highlightedBlock, L"Navigation target");
        Automation::AutomationProperties::SetHelpText(scroll, L"Navigation target: " + to_hstring(index));
        // Complete layout first so new document parts have accurate scroll bounds.
        content.UpdateLayout();
        BringIntoViewOptions options; options.VerticalAlignmentRatio(0); options.AnimationDesired(false);
        highlightedBlock.StartBringIntoView(options);
        if (!navigationTimer) {
            navigationTimer = DispatcherTimer();
            navigationTimer.Interval(std::chrono::milliseconds(1800));
            navigationTimer.Tick([weak = get_weak()](auto const&, auto const&) {
                if (auto self = weak.get()) self->clearNavigationHighlight();
            });
        }
        navigationTimer.Start();
    }

    void cancelTransfers() {
        if (remoteCancellation) remoteCancellation->store(true);
        if (pdfCancellation) pdfCancellation->store(true);
    }

    void removeSelected() {
        if (!selected) return;
        lastQuery = L""; ++searchGeneration;
        auto removed = pathText(library.documents()[*selected].path);
        std::erase_if(session.documents, [&](auto const& item) { return item.path == removed; });
        expandedPaths.erase(library.documents()[*selected].path);
        library.remove(*selected);
        renderStart = 0;
        if (library.documents().empty()) selected.reset();
        else selected = std::min(*selected, library.documents().size() - 1);
        rebuildShelf();
        render(); saveState();
    }

    fire_and_forget removeAll() {
        auto lifetime = get_strong();
        if (dialogOpen || (library.documents().empty() && session.documents.empty())) co_return;
        dialogOpen = true;
        try {
            ContentDialog dialog;
            dialog.XamlRoot(root.XamlRoot());
            dialog.RequestedTheme(root.RequestedTheme());
            dialog.Title(box_value(L"Remove all documents?"));
            dialog.Content(box_value(L"This clears the document list. Your files will stay on disk."));
            dialog.PrimaryButtonText(L"Remove all");
            dialog.CloseButtonText(L"Cancel");
            dialog.DefaultButton(ContentDialogButton::Close);
            auto result = co_await dialog.ShowAsync();
            if (!closed && result == ContentDialogResult::Primary) {
                ++generation;
                pendingLoads.clear();
                cancelTransfers();
                restoring = false;
                expandedPaths.clear();
                library.clear();
                lastQuery = L""; ++searchGeneration;
                session.documents.clear(); session.selectedPath.clear();
                selected.reset();
                rebuildShelf();
                render(); saveState();
            }
        } catch (hresult_error const& e) { error(e.message()); }
        catch (std::exception const& e) { error(to_hstring(e.what())); }
        dialogOpen = false;
    }

    static std::string pathText(std::filesystem::path const& path) {
        auto bytes = path.u8string(); return {reinterpret_cast<char const*>(bytes.data()), bytes.size()};
    }
    ssmv::SessionDocument* position() {
        if (!selected || *selected >= library.documents().size()) return nullptr;
        auto path = pathText(library.documents()[*selected].path);
        for (auto& item : session.documents) if (item.path == path) return &item;
        session.documents.push_back({path, 0, 0}); return &session.documents.back();
    }
    void rememberPosition() {
        if (!initialized || restoring) return;
        if (auto item = position()) { item->bodyPage = static_cast<uint32_t>(renderStart / maxRenderedBlocks); item->scrollOffset = scroll.VerticalOffset(); }
    }
    void restorePage() { if (auto item = position()) renderStart = size_t(item->bodyPage) * maxRenderedBlocks; else renderStart = 0; }
    void restoreScroll() {
        if (auto item = position()) {
            auto path = item->path; auto offset = item->scrollOffset; auto revision = renderRevision;
            window.DispatcherQueue().TryEnqueue([weak = get_weak(), path, offset, revision] {
                if (auto self = weak.get(); self && !self->closed && self->selected && self->renderRevision == revision &&
                    pathText(self->library.documents()[*self->selected].path) == path) {
                    self->scroll.UpdateLayout(); self->scroll.ChangeView(nullptr, offset, nullptr);
                }
            });
        }
    }
    void saveState() {
        if (!initialized || !sessionWritable || restoring) return;
        try {
            session.theme = static_cast<uint32_t>(themeIndex); session.fontSize = fontSize;
            session.outlineEnabled = outline.IsChecked().Value(); session.sidebarVisible = split.IsPaneOpen();
            session.expandedPaths.clear();
            for (auto const& path : expandedPaths) session.expandedPaths.push_back(pathText(path));
            std::vector<ssmv::SessionDocument> ordered;
            for (auto const& document : library.documents()) {
                auto path = pathText(document.path);
                auto found = std::find_if(session.documents.begin(), session.documents.end(), [&](auto const& item) { return item.path == path; });
                ordered.push_back(found != session.documents.end() ? *found : ssmv::SessionDocument{path, 0, 0});
            }
            // Missing files remain registered until the reader explicitly clears the list.
            for (auto const& item : session.documents)
                if (std::none_of(ordered.begin(), ordered.end(), [&](auto const& entry) { return entry.path == item.path; })) ordered.push_back(item);
            session.documents = std::move(ordered);
            session.selectedPath = selected ? pathText(library.documents()[*selected].path) : std::string{};
            ssmv::saveSession(dataDirectory / L"session.bin", session);
        } catch (std::exception const& e) { error(L"Could not save the document list: " + to_hstring(e.what())); }
    }
    void changeSize(int delta) {
        rememberPosition(); fontSize = delta ? std::clamp(fontSize + delta * 2, 10.0, 32.0) : 16;
        render(); restoreScroll(); saveState();
    }
    void showFind() { findPanel.Visibility(Visibility::Visible); findBox.Focus(FocusState::Programmatic); findBox.SelectAll(); }
    static std::string blockText(ssmv::Block const& block) {
        if (block.kind == ssmv::BlockKind::Code) return block.text;
        if (block.kind == ssmv::BlockKind::Table) {
            std::string value;
            for (auto const& row : block.tableRows) { for (auto const& cell : row) { value += ssmv::plainInlineText(cell); value += '\t'; } value += '\n'; }
            return value;
        }
        return ssmv::plainInlineText(block.text);
    }
    hstring lastQuery;
    uint64_t searchGeneration = 0;
    fire_and_forget findNext(bool previous) {
        auto lifetime = get_strong(); apartment_context ui;
        if (!selected || findBox.Text().empty()) { showFind(); co_return; }
        auto request = ++searchGeneration;
        auto query = findBox.Text(); auto path = library.documents()[*selected].path;
        hstring failure;
        try {
            if (query != lastQuery || path != searchPath) {
                auto source = library.documents()[*selected].source;
                findStatus.Text(L"Searching…");
                std::vector<size_t> found;
                co_await resume_background();
                auto view = std::string_view(source);
                if (view.starts_with("\xef\xbb\xbf")) view.remove_prefix(3);
                auto parsed = ssmv::parseMarkdown(view);
                for (size_t i = 0; i < parsed.blocks.size(); ++i) {
                    auto text = to_hstring(blockText(parsed.blocks[i]));
                    if (FindStringOrdinal(FIND_FROMSTART, text.c_str(), static_cast<int>(text.size()), query.c_str(), static_cast<int>(query.size()), TRUE) >= 0) found.push_back(i);
                }
                co_await ui;
                if (closed || request != searchGeneration || !selected || library.documents()[*selected].path != path) co_return;
                matches = std::move(found); lastQuery = query; searchPath = path; matchIndex = previous && !matches.empty() ? matches.size() - 1 : 0;
            } else if (!matches.empty()) matchIndex = previous ? (matchIndex + matches.size() - 1) % matches.size() : (matchIndex + 1) % matches.size();
            if (matches.empty()) { findStatus.Text(L"No matches"); co_return; }
            rememberPosition(); auto target = matches[matchIndex]; renderStart = target / maxRenderedBlocks * maxRenderedBlocks;
            render();
            showNavigationTarget(target);
            findStatus.Text(to_hstring(matchIndex + 1) + L" / " + to_hstring(matches.size()) + L" matching sections");
        } catch (hresult_error const& e) { failure = e.message(); }
        catch (std::exception const& e) { failure = to_hstring(e.what()); }
        catch (...) { failure = L"Search failed."; }
        if (!failure.empty()) {
            co_await ui;
            if (!closed && request == searchGeneration) error(failure);
        }
    }
    void copyDocument() {
        if (!selected) return;
        std::string text;
        for (auto const& block : library.documents()[*selected].markdown.blocks) { text += blockText(block); text += '\n'; }
        DataPackage data; data.SetText(to_hstring(text)); Clipboard::SetContent(data);
    }
    fire_and_forget reload() {
        auto lifetime = get_strong(); apartment_context ui;
        if (!selected) co_return;
        rememberPosition(); auto path = library.documents()[*selected].path; auto request = generation;
        if (auto source = remoteSource(path)) { openRemote(*source); co_return; }
        std::optional<ssmv::Document> document; std::string failure;
        co_await resume_background();
        try { document = ssmv::readDocument(path); } catch (std::exception const& e) { failure = e.what(); }
        co_await ui;
        if (closed || request != generation) co_return;
        try {
            if (!failure.empty()) { error(to_hstring(failure)); co_return; }
            for (size_t i = 0; i < library.documents().size(); ++i) if (library.documents()[i].path == path) {
                library.replace(i, std::move(*document)); lastQuery = L""; ++searchGeneration;
                rebuildShelf(); if (selected && library.documents()[*selected].path == path) { render(); restoreScroll(); }
                saveState(); break;
            }
        } catch (std::exception const& e) { error(to_hstring(e.what())); }
        catch (hresult_error const& e) { error(e.message()); }
    }
    fire_and_forget openClipboard() {
        auto lifetime = get_strong();
        if (importingClipboard) co_return;
        importingClipboard = true;
        struct ResetImport { bool& flag; ~ResetImport() { flag = false; } } reset{importingClipboard};
        try {
            auto data = Clipboard::GetContent();
            if (!data.Contains(StandardDataFormats::Text())) { error(L"The clipboard contains no text."); co_return; }
            auto value = co_await data.GetTextAsync();
            if (closed) co_return;
            auto bytes = to_string(value);
            if (bytes.empty() || bytes.size() > ssmv::MaxDocumentBytes || !ssmv::validUTF8(bytes)) { error(L"Clipboard text must be valid UTF-8 and 16 MiB or smaller."); co_return; }
            auto directory = dataDirectory / L"imports"; std::filesystem::create_directories(directory);
            uintmax_t total = 0;
            for (auto const& entry : std::filesystem::directory_iterator(directory)) if (entry.is_regular_file()) total += entry.file_size();
            if (total + bytes.size() > 256 * 1024 * 1024) { error(L"Imported documents exceed the 256 MiB storage limit."); co_return; }
            GUID id{}; check_hresult(CoCreateGuid(&id)); wchar_t name[40]{}; StringFromGUID2(id, name, 40);
            auto path = directory / (std::wstring(L"Clipboard ") + name + L".md");
            co_await writeDocument(path, std::move(bytes)); if (!closed) load({path});
        } catch (hresult_error const& e) { error(e.message()); }
        catch (std::exception const& e) { error(to_hstring(e.what())); }
    }
    fire_and_forget openURLDialog() {
        auto lifetime = get_strong();
        if (dialogOpen) co_return;
        dialogOpen = true;
        std::wstring address;
        try {
            TextBox input; input.PlaceholderText(L"https://…/document.md"); input.MinWidth(360);
            Automation::AutomationProperties::SetAutomationId(input, L"URLInput");
            Automation::AutomationProperties::SetName(input, L"Markdown URL");
            ContentDialog dialog; dialog.XamlRoot(root.XamlRoot()); dialog.RequestedTheme(root.RequestedTheme());
            dialog.Title(box_value(L"Open Markdown URL")); dialog.Content(input);
            dialog.PrimaryButtonText(L"Open"); dialog.CloseButtonText(L"Cancel");
            dialog.DefaultButton(ContentDialogButton::Primary);
            auto result = co_await dialog.ShowAsync();
            if (result == ContentDialogResult::Primary && !closed) address = input.Text().c_str();
        } catch (hresult_error const& e) { error(e.message()); }
        catch (std::exception const& e) { error(to_hstring(e.what())); }
        dialogOpen = false;
        if (!address.empty()) openRemote(std::move(address));
    }

    fire_and_forget openRemote(std::wstring address) {
        auto lifetime = get_strong(); apartment_context ui;
        if (remoteCancellation) remoteCancellation->store(true);
        auto cancellation = std::make_shared<std::atomic_bool>(false);
        remoteCancellation = cancellation;
        auto directory = dataDirectory / L"remotes";
        std::filesystem::path path;
        hstring failure;
        auto request = generation;
        status.Text(L"Downloading Markdown…");
        try {
            co_await resume_background();
            path = ssmv::downloadRemoteDocument(address, directory, cancellation);
        } catch (hresult_error const& e) { failure = e.message(); }
        catch (std::exception const& e) { failure = to_hstring(e.what()); }
        co_await ui;
        if (remoteCancellation == cancellation) remoteCancellation.reset();
        if (closed || cancellation->load() || request != generation) co_return;
        if (!failure.empty()) { error(failure); co_return; }
        load({path});
    }

    std::optional<std::wstring> remoteSource(std::filesystem::path const& path) {
        // Only app-owned remote cache entries may supply link-resolution metadata.
        auto relative = path.lexically_relative(dataDirectory / L"remotes");
        if (relative.empty() || relative.is_absolute() || *relative.begin() == L"..") return std::nullopt;
        return ssmv::remoteDocumentSource(path);
    }

    fire_and_forget exportPDF() {
        auto lifetime = get_strong(); apartment_context ui;
        if (!selected || pdfCancellation) co_return;
        auto snapshot = library.documents()[*selected].markdown;
        auto name = library.documents()[*selected].path.stem().wstring();
        auto cancellation = std::make_shared<std::atomic_bool>(false);
        pdfCancellation = cancellation;
        hstring failure;
        bool saved = false;
        try {
            Windows::Storage::Pickers::FileSavePicker picker;
            HWND hwnd = nullptr; check_hresult(window.as<IWindowNative>()->get_WindowHandle(&hwnd));
            check_hresult(picker.as<IInitializeWithWindow>()->Initialize(hwnd));
            picker.SuggestedFileName(name); picker.FileTypeChoices().Insert(L"PDF document", single_threaded_vector<hstring>({L".pdf"}));
            auto file = co_await picker.PickSaveFileAsync();
            if (file && !closed && !cancellation->load()) {
                auto destination = std::filesystem::path(file.Path().c_str());
                status.Text(L"Exporting PDF…");
                co_await resume_background();
                ssmv::ui::exportPdf(snapshot, name, destination, *cancellation);
                saved = true;
            }
        } catch (hresult_error const& e) { failure = e.message(); }
        catch (std::exception const& e) { failure = to_hstring(e.what()); }
        co_await ui;
        if (pdfCancellation == cancellation) pdfCancellation.reset();
        if (closed || cancellation->load()) co_return;
        if (!failure.empty()) error(failure);
        else if (saved) error(L"PDF saved.");
    }

    fire_and_forget saveCopy() {
        auto lifetime = get_strong();
        if (!selected) co_return;
        auto source = library.documents()[*selected].source;
        auto name = library.documents()[*selected].path.filename().wstring();
        try {
            Windows::Storage::Pickers::FileSavePicker picker;
            HWND hwnd = nullptr; check_hresult(window.as<IWindowNative>()->get_WindowHandle(&hwnd));
            check_hresult(picker.as<IInitializeWithWindow>()->Initialize(hwnd));
            picker.SuggestedFileName(name); picker.FileTypeChoices().Insert(L"Markdown", single_threaded_vector<hstring>({L".md"}));
            auto file = co_await picker.PickSaveFileAsync();
            if (file && !closed) { co_await writeDocument(std::filesystem::path(file.Path().c_str()), std::move(source)); error(L"Markdown copy saved."); }
        } catch (hresult_error const& e) { error(e.message()); }
        catch (std::exception const& e) { error(to_hstring(e.what())); }
    }
    void reveal() {
        if (!selected) return;
        auto path = library.documents()[*selected].path.wstring();
        auto item = ILCreateFromPathW(path.c_str());
        if (!item) { error(L"The document could not be located in Explorer."); return; }
        auto result = SHOpenFolderAndSelectItems(item, 0, nullptr, 0); ILFree(item); check_hresult(result);
    }
    void toggleFullscreen() {
        auto appWindow = window.AppWindow();
        using Kind = Microsoft::UI::Windowing::AppWindowPresenterKind;
        appWindow.SetPresenter(appWindow.Presenter().Kind() == Kind::FullScreen ? Kind::Default : Kind::FullScreen);
    }
    fire_and_forget navigateLink(std::string destination) {
        auto lifetime = get_strong();
        try {
            if (!selected) co_return;
            auto kind = ssmv::classifyLink(destination);
            if (kind == ssmv::LinkKind::Web || kind == ssmv::LinkKind::Email) {
                co_await Windows::System::Launcher::LaunchUriAsync(Uri(to_hstring(destination)));
            } else if (kind == ssmv::LinkKind::Relative) {
                if (auto source = remoteSource(library.documents()[*selected].path)) {
                    auto address = ssmv::resolveRemoteLink(*source, to_hstring(destination).c_str());
                    auto linkPath = Uri(address).Path();
                    auto extension = std::filesystem::path(linkPath.c_str()).extension().wstring();
                    std::transform(extension.begin(), extension.end(), extension.begin(), [](wchar_t c) { return static_cast<wchar_t>(towlower(c)); });
                    if (extension == L".md" || extension == L".markdown" || extension == L".mdown") openRemote(address);
                    else co_await Windows::System::Launcher::LaunchUriAsync(Uri(address));
                    co_return;
                }
                std::error_code comparisonError;
                if (std::filesystem::equivalent(library.documents()[*selected].path.parent_path(), dataDirectory / L"imports", comparisonError)) {
                    error(L"Imported text cannot open local-file links. Save a copy first to give it a local folder."); co_return;
                }
                auto fragment = destination.find('#'); destination = destination.substr(0, fragment);
                auto relative = Uri::UnescapeComponent(to_hstring(destination));
                auto relativePath = std::filesystem::path(relative.c_str());
                if (relativePath.has_root_path() || std::wstring_view(relative).find(L':') != std::wstring_view::npos) {
                    error(L"Only relative Markdown file links can be opened."); co_return;
                }
                auto path = library.documents()[*selected].path.parent_path() / relativePath;
                load({path});
            } else if (kind == ssmv::LinkKind::Anchor) {
                auto anchor = to_string(Uri::UnescapeComponent(to_hstring(destination.substr(1))));
                for (auto const& heading : library.documents()[*selected].markdown.headings) {
                    auto slug = heading.text;
                    for (char& c : slug) { if (c == ' ') c = '-'; else if (c >= 'A' && c <= 'Z') c += 'a' - 'A'; }
                    if (slug == anchor) {
                        renderStart = heading.blockIndex / maxRenderedBlocks * maxRenderedBlocks;
                        auto target = heading.blockIndex; render();
            showNavigationTarget(target); break;
                    }
                }
            }
        } catch (hresult_error const& e) { error(e.message()); }
        catch (std::exception const& e) { error(to_hstring(e.what())); }
    }

    void sort(bool ascending) {
        auto path = selected ? library.documents()[*selected].path : std::filesystem::path{};
        library.sortByName(ascending);
        for (size_t index = 0; index < library.documents().size(); ++index)
            if (library.documents()[index].path == path) selected = index;
        rebuildShelf(); saveState();
    }
};
}

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    try {
        init_apartment(apartment_type::single_threaded);
        ssmv::Activation activation;
        if (activation.redirectToExisting()) return 0;
        Application::Start([&activation](auto const&) { make<App>(&activation); });
        return 0;
    } catch (hresult_error const& e) {
        MessageBoxW(nullptr, e.message().c_str(), L"SSMV could not start", MB_OK | MB_ICONERROR);
    } catch (std::exception const& e) {
        MessageBoxW(nullptr, to_hstring(e.what()).c_str(), L"SSMV could not start", MB_OK | MB_ICONERROR);
    }
    return 1;
}
