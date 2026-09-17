#include "MarkdownView.hpp"
#include <algorithm>
#include <memory>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.UI.h>
#include <winrt/Windows.UI.Text.h>
#include <winrt/Microsoft.UI.Xaml.Controls.h>
#include <winrt/Microsoft.UI.Xaml.Controls.Primitives.h>
#include <winrt/Microsoft.UI.Xaml.Documents.h>
#include <winrt/Microsoft.UI.Xaml.Media.h>

using namespace winrt;
using namespace Microsoft::UI::Xaml;
using namespace Microsoft::UI::Xaml::Controls;
using namespace Microsoft::UI::Xaml::Documents;
using namespace Microsoft::UI::Xaml::Media;

namespace ssmv {
namespace {
using Navigation = std::function<void(std::string)>;
constexpr size_t tablePageRows = 100;
constexpr size_t tablePageColumns = 12;

TextBlock text(std::string const& source, double size, Navigation const& navigate,
               bool bold = false, bool literal = false) {
    TextBlock result;
    result.FontSize(size);
    result.TextWrapping(TextWrapping::Wrap);
    result.IsTextSelectionEnabled(true);
    if (literal) {
        result.Text(to_hstring(source));
        result.FontFamily(FontFamily(L"Consolas"));
        return result;
    }
    for (auto const& span : parseInline(source)) {
        Run run;
        run.Text(to_hstring(span.text));
        if (bold || span.bold) run.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
        if (span.italic) run.FontStyle(Windows::UI::Text::FontStyle::Italic);
        if (span.strikethrough) run.TextDecorations(Windows::UI::Text::TextDecorations::Strikethrough);
        if (span.code) run.FontFamily(FontFamily(L"Consolas"));
        if (!span.destination.empty() && classifyLink(span.destination) != LinkKind::Unsafe && navigate) {
            Hyperlink link;
            link.Inlines().Append(run);
            // NavigateUri intentionally stays unset: the host validates relative paths
            // and source-specific policies before launching or opening a document.
            link.Click([navigate, destination = span.destination](auto const&, auto const&) {
                navigate(destination);
            });
            result.Inlines().Append(link);
        } else {
            result.Inlines().Append(run);
        }
    }
    return result;
}

void decorate(Border const& border, bool fill) {
    auto update = [fill](Border const& target) {
        bool dark = target.ActualTheme() == ElementTheme::Dark;
        target.BorderBrush(SolidColorBrush(dark ? Windows::UI::Color{255, 90, 90, 90}
                                              : Windows::UI::Color{255, 190, 190, 190}));
        if (fill) target.Background(SolidColorBrush(dark ? Windows::UI::Color{255, 42, 42, 42}
                                                       : Windows::UI::Color{255, 240, 240, 240}));
    };
    update(border);
    border.ActualThemeChanged([update](FrameworkElement const& sender, auto const&) {
        update(sender.as<Border>());
    });
}

struct TableData {
    std::vector<std::vector<std::string>> rows;
    std::vector<TableAlignment> alignments;
    size_t columns = 0;
    double size;
    Navigation navigate;
};

void paintTable(StackPanel const& host, std::shared_ptr<TableData const> const& data,
                size_t rowStart, size_t columnStart) {
    host.Children().Clear();
    if (data->rows.empty() || data->columns == 0) return;
    auto columnEnd = std::min(data->columns, columnStart + tablePageColumns);
    auto bodyCount = data->rows.size() - 1;
    auto rowEnd = std::min(bodyCount, rowStart + tablePageRows);
    if (bodyCount > tablePageRows || data->columns > tablePageColumns) {
        TextBlock range;
        range.Text(to_hstring("Table rows " + std::to_string(bodyCount ? rowStart + 1 : 0) +
            "–" + std::to_string(rowEnd) + " of " + std::to_string(bodyCount) +
            "; columns " + std::to_string(columnStart + 1) + "–" +
            std::to_string(columnEnd) + " of " + std::to_string(data->columns)));
        range.TextWrapping(TextWrapping::Wrap);
        host.Children().Append(range);
    }
    Grid grid;
    for (size_t column = columnStart; column < columnEnd; ++column) {
        ColumnDefinition definition;
        definition.Width({1, GridUnitType::Star});
        definition.MinWidth(80);
        grid.ColumnDefinitions().Append(definition);
    }
    auto appendRow = [&](size_t sourceIndex, int viewIndex) {
        RowDefinition definition;
        definition.Height({1, GridUnitType::Auto});
        grid.RowDefinitions().Append(definition);
        for (size_t column = columnStart; column < columnEnd; ++column) {
            auto const& row = data->rows[sourceIndex];
            auto cellText = text(column < row.size() ? row[column] : "", data->size,
                                 data->navigate, sourceIndex == 0);
            if (column < data->alignments.size()) {
                auto alignment = data->alignments[column];
                cellText.TextAlignment(alignment == TableAlignment::Center ? TextAlignment::Center :
                    alignment == TableAlignment::Right ? TextAlignment::Right : TextAlignment::Left);
            }
            Border cell;
            cell.Padding({8, 5, 8, 5});
            cell.MaxWidth(360);
            cell.BorderThickness({0.5, 0.5, 0.5, 0.5});
            decorate(cell, sourceIndex == 0);
            cell.Child(cellText);
            Grid::SetColumn(cell, static_cast<int>(column - columnStart));
            Grid::SetRow(cell, viewIndex);
            grid.Children().Append(cell);
        }
    };
    appendRow(0, 0);
    for (size_t row = rowStart; row < rowEnd; ++row)
        appendRow(row + 1, static_cast<int>(row - rowStart + 1));
    ScrollViewer horizontal;
    horizontal.HorizontalScrollBarVisibility(ScrollBarVisibility::Auto);
    horizontal.HorizontalScrollMode(ScrollMode::Enabled);
    horizontal.VerticalScrollBarVisibility(ScrollBarVisibility::Disabled);
    horizontal.VerticalScrollMode(ScrollMode::Disabled);
    horizontal.Content(grid);
    host.Children().Append(horizontal);
    StackPanel pager;
    // A vertical pager remains reachable even in a narrow reading pane.
    pager.HorizontalAlignment(HorizontalAlignment::Left);
    pager.Spacing(8);
    auto add = [&](hstring const& title, size_t nextRow, size_t nextColumn) {
        Button button;
        button.Content(box_value(title));
        button.Click([weak = make_weak(host), data, nextRow, nextColumn](auto const&, auto const&) {
            if (auto target = weak.get()) paintTable(target, data, nextRow, nextColumn);
        });
        pager.Children().Append(button);
    };
    if (rowStart > 0) add(L"Previous rows", rowStart >= tablePageRows ? rowStart - tablePageRows : 0, columnStart);
    if (rowEnd < bodyCount) add(L"Next rows", rowEnd, columnStart);
    if (columnStart > 0) add(L"Previous columns", rowStart, columnStart >= tablePageColumns ? columnStart - tablePageColumns : 0);
    if (columnEnd < data->columns) add(L"Next columns", rowStart, columnEnd);
    if (pager.Children().Size()) host.Children().Append(pager);
}
}

FrameworkElement renderBlock(Block const& block, double fontSize, Navigation navigate) {
    if (block.kind == BlockKind::Table) {
        auto data = std::make_shared<TableData>();
        data->rows = block.tableRows;
        data->alignments = block.alignments;
        data->size = fontSize;
        data->navigate = std::move(navigate);
        for (auto const& row : data->rows) data->columns = std::max(data->columns, row.size());
        StackPanel table;
        table.Spacing(8);
        paintTable(table, data, 0, 0);
        return table;
    }
    if (block.kind == BlockKind::Rule) {
        Border rule;
        rule.BorderThickness({0, 1, 0, 0});
        rule.Margin({0, 8, 0, 8});
        decorate(rule, false);
        return rule;
    }
    auto body = text(block.text, fontSize, navigate, block.kind == BlockKind::Heading,
                     block.kind == BlockKind::Code);
    if (block.kind == BlockKind::Heading) {
        body.FontSize(fontSize * (block.level == 1 ? 1.875 : block.level == 2 ? 1.5625 : 1.25));
        body.Margin({0, 14, 0, 4});
    } else if (block.kind == BlockKind::Code || block.kind == BlockKind::Quote) {
        Border wrapper;
        bool code = block.kind == BlockKind::Code;
        wrapper.Padding({12, 8, 12, 8});
        wrapper.BorderThickness(code ? Thickness{1, 1, 1, 1} : Thickness{3, 0, 0, 0});
        if (code) body.FontSize(fontSize * 0.875);
        decorate(wrapper, code);
        wrapper.Child(body);
        return wrapper;
    } else if (block.kind == BlockKind::UnorderedListItem || block.kind == BlockKind::OrderedListItem) {
        Grid row;
        ColumnDefinition markerColumn;
        markerColumn.Width({1, GridUnitType::Auto});
        row.ColumnDefinitions().Append(markerColumn);
        row.ColumnDefinitions().Append(ColumnDefinition());
        auto marker = text(block.kind == BlockKind::UnorderedListItem ? "•" :
                           std::to_string(block.startNumber) + ".", fontSize, {});
        marker.Margin({0, 0, 8, 0});
        row.Margin({static_cast<double>(std::min(block.indent, size_t{32})) * fontSize * 0.5, 0, 0, 0});
        Grid::SetColumn(body, 1);
        row.Children().Append(marker);
        row.Children().Append(body);
        return row;
    }
    return body;
}
}
