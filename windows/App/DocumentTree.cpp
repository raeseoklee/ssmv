#include "DocumentTree.hpp"
#include <algorithm>
#include <winrt/Microsoft.UI.Xaml.h>
#include <winrt/Microsoft.UI.Xaml.Automation.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include <winrt/Microsoft.UI.Xaml.Input.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>
#include <winrt/Windows.Foundation.Collections.h>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
using Microsoft::UI::Xaml::Automation::AutomationProperties;

namespace ssmv {
struct DocumentTree::State {
    static constexpr std::size_t pageSize = 200;
    enum class Kind { Document, Heading, Pager };
    struct Entry {
        TreeViewNode node{nullptr};
        Kind kind;
        std::size_t document;
        std::size_t value = 0;
    };
    std::shared_ptr<int> lifetime = std::make_shared<int>(0);
    DocumentTree& owner;
    DocumentLibrary const* library = nullptr;
    std::vector<Entry> entries;
    bool updating = false;
    bool outlines = true;
    explicit State(DocumentTree& input) : owner(input) {}

    std::optional<Entry> find(TreeViewNode const& node) const {
        auto it = std::find_if(entries.begin(), entries.end(), [&](auto const& entry) { return entry.node == node; });
        if (it == entries.end()) return std::nullopt;
        return *it;
    }
    TreeViewNode root(std::size_t document) const {
        for (auto const& entry : entries)
            if (entry.kind == Kind::Document && entry.document == document) return entry.node;
        return nullptr;
    }
    TreeViewNode makeNode(FrameworkElement const& content, hstring const& name, Kind kind,
                          std::size_t document, std::size_t value = 0) {
        TreeViewNode node;
        node.Content(content);
        AutomationProperties::SetName(content, name);
        // Set the container name too, so screen readers and UI Automation expose
        // the filename instead of the custom layout's runtime type name.
        content.Loaded([this, guard = std::weak_ptr<int>(lifetime), weak = make_weak(node), name](auto const&, auto const&) {
            if (guard.expired()) return;
            if (auto current = weak.get()) {
                if (auto item = owner.view.ContainerFromNode(current).try_as<TreeViewItem>()) {
                    AutomationProperties::SetName(item, name);
                    item.HorizontalContentAlignment(HorizontalAlignment::Stretch);
                }
            }
        });
        entries.push_back({node, kind, document, value});
        return node;
    }
    void clearChildren(TreeViewNode const& node, std::size_t document) {
        // Drop metadata before the controls: no retained outline nodes after a
        // collapse or page change, and no stale indices after a library update.
        auto current = find(owner.view.SelectedNode());
        if (current && current->document == document && current->kind != Kind::Document)
            owner.view.SelectedNode(node);
        std::erase_if(entries, [&](auto const& entry) {
            return entry.document == document && entry.kind != Kind::Document;
        });
        node.Children().Clear();
    }
    void page(std::size_t document, std::size_t start) {
        auto parent = root(document);
        if (!parent || !library || document >= library->documents().size()) return;
        bool const wasUpdating = updating;
        updating = true;
        clearChildren(parent, document);
        auto const& headings = library->documents()[document].markdown.headings;
        start = std::min(start, headings.size());
        auto pager = [&](hstring const& label, std::size_t offset) {
            TextBlock text;
            text.Text(label);
            text.FontSize(12);
            text.Opacity(.75);
            parent.Children().Append(makeNode(text, label, Kind::Pager, document, offset));
        };
        if (start) pager(L"Previous headings", start >= pageSize ? start - pageSize : 0);
        std::vector<std::pair<int, TreeViewNode>> ancestors;
        auto const end = std::min(headings.size(), start + pageSize);
        for (auto i = start; i < end; ++i) {
            auto const& heading = headings[i];
            TextBlock text;
            auto name = to_hstring(heading.text);
            text.Text(name);
            text.FontSize(13);
            text.TextTrimming(TextTrimming::CharacterEllipsis);
            auto node = makeNode(text, name, Kind::Heading, document, heading.blockIndex);
            while (!ancestors.empty() && ancestors.back().first >= heading.level) ancestors.pop_back();
            auto container = ancestors.empty() ? parent : ancestors.back().second;
            container.Children().Append(node);
            node.IsExpanded(true);
            ancestors.emplace_back(heading.level, node);
        }
        if (end < headings.size()) pager(L"More headings", end);
        parent.HasUnrealizedChildren(false);
        updating = wasUpdating;
    }
};

DocumentTree::DocumentTree() : view(TreeView{}), state(std::make_unique<State>(*this)) {
    view.SelectionMode(TreeViewSelectionMode::Single);
    view.CanDragItems(false);
    view.CanReorderItems(false);
    view.AllowDrop(false);
    AutomationProperties::SetAutomationId(view, L"DocumentTree");
    AutomationProperties::SetName(view, L"Documents");
    view.Expanding([this, guard = std::weak_ptr<int>(state->lifetime)](auto const&, TreeViewExpandingEventArgs const& args) {
        if (guard.expired() || state->updating) return;
        auto entry = state->find(args.Node());
        if (!entry || entry->kind != State::Kind::Document) return;
        state->page(entry->document, 0);
        if (expanded) expanded(state->library->documents()[entry->document].path, true);
    });
    view.Collapsed([this, guard = std::weak_ptr<int>(state->lifetime)](auto const&, TreeViewCollapsedEventArgs const& args) {
        if (guard.expired() || state->updating) return;
        auto entry = state->find(args.Node());
        if (!entry || entry->kind != State::Kind::Document) return;
        state->updating = true;
        state->clearChildren(args.Node(), entry->document);
        args.Node().HasUnrealizedChildren(state->outlines && !state->library->documents()[entry->document].markdown.headings.empty());
        state->updating = false;
        if (expanded) expanded(state->library->documents()[entry->document].path, false);
    });
    view.SelectionChanged([this, guard = std::weak_ptr<int>(state->lifetime)](auto const&, auto const&) {
        if (guard.expired() || state->updating) return;
        auto entry = state->find(view.SelectedNode());
        if (!entry || entry->kind != State::Kind::Document || !selected) return;
        selected(entry->document, std::nullopt);
    });
    view.ItemInvoked([this, guard = std::weak_ptr<int>(state->lifetime)](auto const&, TreeViewItemInvokedEventArgs const& args) {
        if (guard.expired() || state->updating) return;
        auto node = args.InvokedItem().try_as<TreeViewNode>();
        if (!node) node = view.NodeFromItem(args.InvokedItem());
        auto entry = state->find(node);
        if (!entry) return;
        if (entry->kind == State::Kind::Pager) state->page(entry->document, entry->value);
        // Invoke headings even when already selected. Arrow keys move selection;
        // Enter (or a click) activates the heading, without a duplicate first jump.
        else if (entry->kind == State::Kind::Heading && selected) selected(entry->document, entry->value);
    });
    view.RightTapped([this, guard = std::weak_ptr<int>(state->lifetime)](auto const&, Input::RightTappedRoutedEventArgs const& args) {
        if (guard.expired() || state->updating) return;
        auto target = args.OriginalSource().try_as<DependencyObject>();
        while (target && target != view) {
            if (auto item = target.try_as<TreeViewItem>()) {
                auto node = view.NodeFromContainer(item);
                auto entry = state->find(node);
                if (entry && entry->kind != State::Kind::Pager) {
                    view.SelectedNode(node);
                    if (entry->kind == State::Kind::Heading && selected)
                        selected(entry->document, std::nullopt);
                }
                return;
            }
            target = Media::VisualTreeHelper::GetParent(target);
        }
    });
}
DocumentTree::~DocumentTree() = default;

void DocumentTree::update(DocumentLibrary const& library, std::optional<std::size_t> selectedIndex,
                          bool outlineEnabled, std::set<std::filesystem::path> const& expandedPaths) {
    state->updating = true;
    state->library = &library;
    state->outlines = outlineEnabled;
    state->entries.clear();
    view.RootNodes().Clear();
    for (std::size_t i = 0; i < library.documents().size(); ++i) {
        auto const& document = library.documents()[i];
        Grid row;
        ColumnDefinition iconColumn;
        iconColumn.Width(GridLength{24, GridUnitType::Pixel});
        row.ColumnDefinitions().Append(iconColumn);
        ColumnDefinition titleColumn;
        titleColumn.Width(GridLength{1, GridUnitType::Star});
        row.ColumnDefinitions().Append(titleColumn);
        row.Margin(Thickness{0, 5, 4, 5});
        SymbolIcon icon{Symbol::Document};
        icon.Width(16);
        icon.Height(16);
        icon.VerticalAlignment(VerticalAlignment::Top);
        icon.Margin(Thickness{0, 3, 0, 0});
        row.Children().Append(icon);
        StackPanel labels;
        Grid::SetColumn(labels, 1);
        TextBlock title;
        auto filename = hstring(document.path.filename().wstring());
        title.Text(filename);
        title.FontSize(14);
        title.TextTrimming(TextTrimming::CharacterEllipsis);
        labels.Children().Append(title);
        TextBlock location;
        location.Text(document.path.parent_path().wstring());
        location.FontSize(11);
        location.Opacity(.6);
        location.TextTrimming(TextTrimming::CharacterEllipsis);
        labels.Children().Append(location);
        row.Children().Append(labels);
        auto node = state->makeNode(row, filename, State::Kind::Document, i);
        node.HasUnrealizedChildren(outlineEnabled && !document.markdown.headings.empty());
        view.RootNodes().Append(node);
        if (outlineEnabled && expandedPaths.contains(document.path) && !document.markdown.headings.empty()) {
            state->page(i, 0);
            node.IsExpanded(true);
        }
        if (selectedIndex == i) view.SelectedNode(node);
    }
    state->updating = false;
}
}
