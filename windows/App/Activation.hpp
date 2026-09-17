#pragma once

#include <filesystem>
#include <functional>
#include <memory>
#include <vector>
#include <winrt/Microsoft.UI.Dispatching.h>

namespace ssmv {

// Construct after init_apartment(STA), before Application::Start. Keep alive until
// the application exits. attach() and stop() are called on the UI thread.
class Activation final {
public:
    using Handler = std::function<void(std::vector<std::filesystem::path>)>;
    Activation();
    ~Activation();
    Activation(Activation const&) = delete;
    Activation& operator=(Activation const&) = delete;

    // true means this process forwarded its request and must exit without UI.
    // Forwarded command-line paths must be absolute: AppLifecycle does not carry
    // the launching process's working directory. Cold launches accept relatives.
    bool redirectToExisting();
    void attach(winrt::Microsoft::UI::Dispatching::DispatcherQueue const& dispatcher, Handler handler);
    void stop() noexcept;

private:
    struct State;
    std::shared_ptr<State> state_;
};
}
