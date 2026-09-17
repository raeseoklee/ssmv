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
#include <winrt/Microsoft.UI.Dispatching.h>
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
    ComboBox theme{nullptr};
    TextBox findBox{nullptr};
    StackPanel findPanel{nullptr};
    TextBlock findStatus{nullptr};
    std::vector<size_t> matches;
    size_t matchIndex = 0;
    std::filesystem::path searchPath;
    Window window{nullptr};
    Grid root{nullptr};
    SplitView split{nullptr};
    StackPanel shelf{nullptr};
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

    void error(hstring const& message) {
        if (!closed && status) status.Text(message);
    }

    void OnLaunched(LaunchActivatedEventArgs const&) {
        Resources().MergedDictionaries().Append(XamlControlsResources());
        window = Window();
        window.Title(L"So Simple Markdown Viewer");
        window.Closed([this](auto const&, auto const&) {
            rememberPosition(); saveState(); activation->stop(); closed = true; ++generation;
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

        StackPanel toolbar;
        toolbar.Orientation(Orientation::Horizontal);
        toolbar.Spacing(8);
        toolbar.Margin({12, 10, 12, 10});
        toolbar.Children().Append(button(L"Sidebar", [this] { split.IsPaneOpen(!split.IsPaneOpen()); saveState(); }));
        toolbar.Children().Append(button(L"Open…", [this] { pick(); }));
        theme = ComboBox();
        theme.Items().Append(box_value(L"System theme"));
        theme.Items().Append(box_value(L"Light"));
        theme.Items().Append(box_value(L"Dark"));
        theme.SelectedIndex(static_cast<int>(session.theme));
        theme.SelectionChanged([this](auto const&, auto const&) {
            root.RequestedTheme(theme.SelectedIndex() == 1 ? ElementTheme::Light :
                                theme.SelectedIndex() == 2 ? ElementTheme::Dark : ElementTheme::Default);
            saveState();
        });
        root.RequestedTheme(session.theme == 1 ? ElementTheme::Light : session.theme == 2 ? ElementTheme::Dark : ElementTheme::Default);
        toolbar.Children().Append(theme);
        MenuFlyout actions;
        auto command = [this, actions](hstring const& title, auto action) {
            MenuFlyoutItem item; item.Text(title);
            item.Click([this, action](auto const&, auto const&) {
                try { action(); }
                catch (hresult_error const& e) { error(e.message()); }
                catch (std::exception const& e) { error(to_hstring(e.what())); }
            });
            actions.Items().Append(item);
        };
        command(L"Open Clipboard as Markdown", [this] { openClipboard(); });
        command(L"Save a Copy…", [this] { saveCopy(); });
        command(L"Reload", [this] { reload(); });
        command(L"Cancel Loading", [this] { ++generation; pendingLoads.clear(); restoring = false; status.Text(L"Loading canceled."); });
        command(L"Find…", [this] { showFind(); });
        command(L"Increase Text Size", [this] { changeSize(1); });
        command(L"Decrease Text Size", [this] { changeSize(-1); });
        command(L"Actual Text Size", [this] { changeSize(0); });
        command(L"Copy Document Text", [this] { copyDocument(); });
        command(L"Reveal in Explorer", [this] { reveal(); });
        command(L"Full Screen", [this] { toggleFullscreen(); });
        DropDownButton more; more.Content(box_value(L"More")); more.Flyout(actions);
        toolbar.Children().Append(more);
        root.Children().Append(toolbar);
        findPanel = StackPanel(); findPanel.Orientation(Orientation::Horizontal); findPanel.Spacing(8);
        findPanel.Margin({12, 0, 12, 8}); findPanel.Visibility(Visibility::Collapsed);
        findBox = TextBox(); findBox.Width(260); findBox.PlaceholderText(L"Find in document");
        findBox.MaxLength(512);
        Automation::AutomationProperties::SetAutomationId(findBox, L"FindBox");
        findBox.KeyDown([this](auto const&, KeyRoutedEventArgs const& args) {
            if (args.Key() == Windows::System::VirtualKey::Enter) { findNext(false); args.Handled(true); }
        });
        findPanel.Children().Append(findBox);
        findPanel.Children().Append(button(L"Previous", [this] { findNext(true); }));
        findPanel.Children().Append(button(L"Next", [this] { findNext(false); }));
        findPanel.Children().Append(button(L"Close search", [this] { findPanel.Visibility(Visibility::Collapsed); }));
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
        StackPanel header;
        header.Orientation(Orientation::Horizontal);
        header.Spacing(8);
        header.Margin({12, 8, 12, 8});
        header.Children().Append(label(L"Documents", 16));
        header.Children().Append(button(L"+", [this] { pick(); }));
        header.Children().Append(button(L"−", [this] { removeSelected(); }));
        outline = ToggleButton();
        outline.Content(box_value(L"Outline"));
        outline.IsChecked(session.outlineEnabled);
        outline.Click([this](auto const&, auto const&) { rebuildShelf(); saveState(); });
        header.Children().Append(outline);
        pane.Children().Append(header);
        ScrollViewer shelfScroll;
        shelf = StackPanel();
        shelf.Spacing(4);
        shelf.Margin({8, 0, 8, 12});
        shelfScroll.Content(shelf);
        Grid::SetRow(shelfScroll, 1);
        pane.Children().Append(shelfScroll);
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
        scroll.HorizontalScrollBarVisibility(ScrollBarVisibility::Disabled);
        content = StackPanel();
        content.Spacing(10);
        content.Margin({28, 20, 28, 28});
        content.MaxWidth(1100);
        content.HorizontalAlignment(HorizontalAlignment::Stretch);
        scroll.Content(content);
        split.Content(scroll);
        status = label(L"Open Markdown files or drop them anywhere in this window.");
        status.Margin({12, 6, 12, 10});
        Grid::SetRow(status, 3);
        root.Children().Append(status);
        KeyboardAccelerator openKey;
        openKey.Key(Windows::System::VirtualKey::O);
        openKey.Modifiers(Windows::System::VirtualKeyModifiers::Control);
        openKey.Invoked([this](auto const&, auto const& args) { args.Handled(true); pick(); });
        root.KeyboardAccelerators().Append(openKey);
        auto shortcut = [this](Windows::System::VirtualKey key, Windows::System::VirtualKeyModifiers modifiers, auto action) {
            KeyboardAccelerator keybinding; keybinding.Key(key); keybinding.Modifiers(modifiers);
            keybinding.Invoked([this, action](auto const&, auto const& args) {
                args.Handled(true);
                try { action(); } catch (hresult_error const& e) { error(e.message()); }
                catch (std::exception const& e) { error(to_hstring(e.what())); }
            });
            root.KeyboardAccelerators().Append(keybinding);
        };
        using Key = Windows::System::VirtualKey;
        using Mod = Windows::System::VirtualKeyModifiers;
        shortcut(Key::F, Mod::Control, [this] { showFind(); });
        shortcut(Key::F3, Mod::None, [this] { findNext(false); });
        shortcut(Key::F3, Mod::Shift, [this] { findNext(true); });
        shortcut(Key::R, Mod::Control, [this] { reload(); });
        shortcut(Key::Number0, Mod::Control, [this] { changeSize(0); });
        shortcut(Key::Add, Mod::Control, [this] { changeSize(1); });
        shortcut(static_cast<Key>(187), Mod::Control, [this] { changeSize(1); });
        shortcut(Key::Subtract, Mod::Control, [this] { changeSize(-1); });
        shortcut(static_cast<Key>(189), Mod::Control, [this] { changeSize(-1); });
        shortcut(Key::F11, Mod::None, [this] { toggleFullscreen(); });
        shortcut(Key::S, Mod::Control | Mod::Shift, [this] { saveCopy(); });
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

    void buildOutline(Expander const& expander, size_t index, size_t start) {
        constexpr size_t pageSize = 200;
        auto const& headings = library.documents()[index].markdown.headings;
        StackPanel panel;
        auto weakExpander = make_weak(expander);
        if (start > 0) panel.Children().Append(button(L"Previous headings", [this, weakExpander, index, start] {
            if (auto owner = weakExpander.get()) buildOutline(owner, index, start >= pageSize ? start - pageSize : 0);
        }));
        auto end = std::min(headings.size(), start + pageSize);
        for (size_t position = start; position < end; ++position) {
            auto const& heading = headings[position];
            auto jump = button(to_hstring(heading.text), [this, index, target = heading.blockIndex] {
                auto changed = !selected || *selected != index;
                rememberPosition(); selected = index;
                renderStart = (target / maxRenderedBlocks) * maxRenderedBlocks;
                if (changed) rebuildShelf();
                render();
                if (target >= renderStart && target - renderStart < rendered.size())
                    rendered[target - renderStart].StartBringIntoView();
            });
            jump.Margin({double(std::max(0, heading.level - 1) * 12), 0, 0, 0});
            jump.HorizontalAlignment(HorizontalAlignment::Stretch);
            jump.HorizontalContentAlignment(HorizontalAlignment::Left);
            panel.Children().Append(jump);
        }
        if (end < headings.size()) panel.Children().Append(button(L"More headings", [this, weakExpander, index, end] {
            if (auto owner = weakExpander.get()) buildOutline(owner, index, end);
        }));
        expander.Content(panel);
    }

    void rebuildShelf() {
        shelf.Children().Clear();
        for (size_t index = 0; index < library.documents().size(); ++index) {
            auto const& document = library.documents()[index];
            auto title = (selected && *selected == index ? hstring(L"● ") : hstring()) + hstring(document.path.filename().wstring());
            auto choose = button(title, [this, index] { rememberPosition(); selected = index; restorePage(); rebuildShelf(); render(); restoreScroll(); saveState(); });
            choose.HorizontalAlignment(HorizontalAlignment::Stretch);
            choose.HorizontalContentAlignment(HorizontalAlignment::Left);
            ToolTipService::SetToolTip(choose, box_value(document.path.wstring()));
            if (outline.IsChecked().Value() && !document.markdown.headings.empty()) {
                Expander expander;
                expander.Header(choose);
                auto path = document.path;
                expander.Expanding([this, path, index](auto const& sender, auto const&) {
                    expandedPaths.insert(path);
                    saveState();
                    buildOutline(sender.template as<Expander>(), index, 0);
                });
                expander.Collapsed([this, path](auto const& sender, auto const&) {
                    expandedPaths.erase(path);
                    saveState();
                    sender.template as<Expander>().Content(nullptr);
                });
                expander.HorizontalAlignment(HorizontalAlignment::Stretch);
                if (expandedPaths.contains(path)) {
                    buildOutline(expander, index, 0);
                    expander.IsExpanded(true);
                }
                shelf.Children().Append(expander);
            } else shelf.Children().Append(choose);
        }
    }

    void render() {
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
            rendered.push_back(element);
            content.Children().Append(element);
        }
        scroll.ChangeView(nullptr, 0.0, nullptr);
        if (end < count) content.Children().Append(button(L"Continue reading", [this, end] {
            renderStart = end;
            render();
        }));
        if (count > maxRenderedBlocks) {
            status.Text(L"Part " + to_hstring(renderStart / maxRenderedBlocks + 1) + L" of " +
                        to_hstring((count + maxRenderedBlocks - 1) / maxRenderedBlocks));
        } else status.Text(hstring(document.path.wstring()));
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
            session.theme = static_cast<uint32_t>(theme.SelectedIndex()); session.fontSize = fontSize;
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
            if (target >= renderStart && target - renderStart < rendered.size()) rendered[target - renderStart].StartBringIntoView();
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
            if (target >= renderStart && target - renderStart < rendered.size()) rendered[target - renderStart].StartBringIntoView(); break;
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
