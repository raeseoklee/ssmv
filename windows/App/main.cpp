#include <windows.h>
#undef GetCurrentTime
#include <shellapi.h>
#include <shobjidl.h>
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
    std::vector<FrameworkElement> rendered;
    size_t renderLimit = maxRenderedBlocks;
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
        window.Closed([this](auto const&, auto const&) { closed = true; ++generation; });
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
        root.RowDefinitions().Append(bodyRow);
        root.RowDefinitions().Append(statusRow);

        StackPanel toolbar;
        toolbar.Orientation(Orientation::Horizontal);
        toolbar.Spacing(8);
        toolbar.Margin({12, 10, 12, 10});
        toolbar.Children().Append(button(L"Sidebar", [this] { split.IsPaneOpen(!split.IsPaneOpen()); }));
        toolbar.Children().Append(button(L"Open…", [this] { pick(); }));
        ComboBox theme;
        theme.Items().Append(box_value(L"System theme"));
        theme.Items().Append(box_value(L"Light"));
        theme.Items().Append(box_value(L"Dark"));
        theme.SelectedIndex(0);
        theme.SelectionChanged([this, theme](auto const&, auto const&) {
            root.RequestedTheme(theme.SelectedIndex() == 1 ? ElementTheme::Light :
                                theme.SelectedIndex() == 2 ? ElementTheme::Dark : ElementTheme::Default);
        });
        toolbar.Children().Append(theme);
        root.Children().Append(toolbar);

        split = SplitView();
        split.DisplayMode(SplitViewDisplayMode::Inline);
        split.OpenPaneLength(280);
        split.IsPaneOpen(true);
        Grid::SetRow(split, 1);
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
        outline.IsChecked(true);
        outline.Click([this](auto const&, auto const&) { rebuildShelf(); });
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
        Grid::SetRow(status, 2);
        root.Children().Append(status);
        KeyboardAccelerator openKey;
        openKey.Key(Windows::System::VirtualKey::O);
        openKey.Modifiers(Windows::System::VirtualKeyModifiers::Control);
        openKey.Invoked([this](auto const&, auto const& args) { args.Handled(true); pick(); });
        root.KeyboardAccelerators().Append(openKey);
        window.Content(root);
        window.Activate();
        render();
        int count = 0;
        auto argv = CommandLineToArgvW(GetCommandLineW(), &count);
        std::vector<std::filesystem::path> paths;
        if (argv) {
            for (int index = 1; index < count; ++index) paths.emplace_back(argv[index]);
            LocalFree(argv);
        }
        if (!paths.empty()) load(std::move(paths));
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
                for (auto& document : loaded) selected = library.insert(std::move(document));
                renderLimit = maxRenderedBlocks;
                rebuildShelf();
                render();
                if (!failures.empty()) error(to_hstring(failures));
            } catch (hresult_error const& e) { error(e.message()); }
            catch (std::exception const& e) { error(to_hstring(e.what())); }
        }
        loading = false;
    }

    void rebuildShelf() {
        shelf.Children().Clear();
        for (size_t index = 0; index < library.documents().size(); ++index) {
            auto const& document = library.documents()[index];
            auto title = (selected && *selected == index ? hstring(L"● ") : hstring()) + hstring(document.path.filename().wstring());
            auto choose = button(title, [this, index] { selected = index; renderLimit = maxRenderedBlocks; rebuildShelf(); render(); });
            choose.HorizontalAlignment(HorizontalAlignment::Stretch);
            choose.HorizontalContentAlignment(HorizontalAlignment::Left);
            ToolTipService::SetToolTip(choose, box_value(document.path.wstring()));
            if (outline.IsChecked().Value() && !document.markdown.headings.empty()) {
                Expander expander;
                expander.Header(choose);
                auto path = document.path;
                expander.IsExpanded(expandedPaths.contains(path));
                expander.Expanding([this, path](auto const&, auto const&) { expandedPaths.insert(path); });
                expander.Collapsed([this, path](auto const&, auto const&) { expandedPaths.erase(path); });
                expander.HorizontalAlignment(HorizontalAlignment::Stretch);
                StackPanel headings;
                for (auto const& heading : document.markdown.headings) {
                    auto jump = button(to_hstring(heading.text), [this, index, target = heading.blockIndex] {
                        if (!selected || *selected != index) { selected = index; renderLimit = maxRenderedBlocks; rebuildShelf(); render(); }
                        if (target >= rendered.size()) { renderLimit = target + 1; render(); }
                        if (target < rendered.size()) rendered[target].StartBringIntoView();
                        else error(L"Could not locate this heading.");
                    });
                    jump.Margin({double(std::max(0, int(heading.level) - 1) * 12), 0, 0, 0});
                    jump.HorizontalAlignment(HorizontalAlignment::Stretch);
                    jump.HorizontalContentAlignment(HorizontalAlignment::Left);
                    headings.Children().Append(jump);
                }
                expander.Content(headings);
                shelf.Children().Append(expander);
            } else shelf.Children().Append(choose);
        }
    }

    void render() {
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
        for (auto const& block : document.markdown.blocks) {
            if (rendered.size() == renderLimit) break;
            auto text = label(to_hstring(block.text), 16);
            text.IsTextSelectionEnabled(true);
            switch (block.kind) {
            case ssmv::BlockKind::Heading:
                text.FontSize(block.level == 1 ? 30 : block.level == 2 ? 25 : 20);
                text.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
                text.Margin({0, 14, 0, 4});
                break;
            case ssmv::BlockKind::Code:
                text.FontFamily(Media::FontFamily(L"Consolas"));
                text.FontSize(14);
                text.Margin({12, 8, 12, 8});
                break;
            case ssmv::BlockKind::Quote: text.Margin({18, 0, 0, 0}); break;
            case ssmv::BlockKind::UnorderedListItem: text.Text(L"• " + to_hstring(block.text)); break;
            case ssmv::BlockKind::OrderedListItem: text.Text(to_hstring(std::to_string(block.startNumber) + ". " + block.text)); break;
            case ssmv::BlockKind::Rule: text.Text(L"────────────────"); break;
            default: break;
            }
            rendered.push_back(text);
            content.Children().Append(text);
        }
        scroll.ChangeView(nullptr, 0.0, nullptr);
        if (document.markdown.blocks.size() > rendered.size()) {
            content.Children().Append(button(L"Load more", [this] {
                auto offset = scroll.VerticalOffset();
                renderLimit += maxRenderedBlocks;
                render();
                scroll.ChangeView(nullptr, offset, nullptr);
            }));
            status.Text(L"Showing the first " + to_hstring(rendered.size()) + L" blocks. Choose Load more to continue.");
        } else status.Text(hstring(document.path.wstring()));
    }

    void removeSelected() {
        if (!selected) return;
        expandedPaths.erase(library.documents()[*selected].path);
        library.remove(*selected);
        if (library.documents().empty()) selected.reset();
        else selected = std::min(*selected, library.documents().size() - 1);
        rebuildShelf();
        render();
    }

    fire_and_forget removeAll() {
        auto lifetime = get_strong();
        if (dialogOpen || library.documents().empty()) co_return;
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
                expandedPaths.clear();
                library.clear();
                selected.reset();
                rebuildShelf();
                render();
            }
        } catch (hresult_error const& e) { error(e.message()); }
        catch (std::exception const& e) { error(to_hstring(e.what())); }
        dialogOpen = false;
    }

    void sort(bool ascending) {
        auto path = selected ? library.documents()[*selected].path : std::filesystem::path{};
        library.sortByName(ascending);
        for (size_t index = 0; index < library.documents().size(); ++index)
            if (library.documents()[index].path == path) selected = index;
        rebuildShelf();
    }
};
}

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    try {
        init_apartment(apartment_type::single_threaded);
        Application::Start([](auto const&) { make<App>(); });
        return 0;
    } catch (hresult_error const& e) {
        MessageBoxW(nullptr, e.message().c_str(), L"SSMV could not start", MB_OK | MB_ICONERROR);
    } catch (std::exception const& e) {
        MessageBoxW(nullptr, to_hstring(e.what()).c_str(), L"SSMV could not start", MB_OK | MB_ICONERROR);
    }
    return 1;
}
