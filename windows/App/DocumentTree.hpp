#pragma once
#include "Documents.hpp"
#include <functional>
#include <memory>
#include <optional>
#include <set>
#include <winrt/Microsoft.UI.Xaml.Controls.h>

namespace ssmv {
class DocumentTree {
public:
    winrt::Microsoft::UI::Xaml::Controls::TreeView view{nullptr};
    std::function<void(std::size_t, std::optional<std::size_t>)> selected;
    std::function<void(std::filesystem::path, bool)> expanded;
    DocumentTree();
    ~DocumentTree();
    DocumentTree(DocumentTree const&) = delete;
    DocumentTree& operator=(DocumentTree const&) = delete;
    void update(DocumentLibrary const&, std::optional<std::size_t>, bool,
                std::set<std::filesystem::path> const&);
private:
    struct State;
    std::unique_ptr<State> state;
};
}
