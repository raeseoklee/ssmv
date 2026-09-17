#include <windows.h>
#undef GetCurrentTime
#include <shellapi.h>
#include <objbase.h>
#include "Activation.hpp"
#include <winrt/Microsoft.Windows.AppLifecycle.h>
#include <winrt/Windows.ApplicationModel.Activation.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Storage.h>
#include <deque>
#include <exception>
#include <mutex>
#include <stdexcept>
#include <utility>

namespace ssmv {
namespace {
using namespace winrt;
using namespace winrt::Microsoft::Windows::AppLifecycle;

std::vector<std::filesystem::path> activationPaths(AppActivationArguments const& args, bool cold) {
    std::vector<std::filesystem::path> paths;
    if (args.Kind() == ExtendedActivationKind::File) {
        auto files = args.Data().as<Windows::ApplicationModel::Activation::IFileActivatedEventArgs>();
        for (auto const& file : files.Files()) {
            if (file.IsOfType(Windows::Storage::StorageItemTypes::File))
                paths.emplace_back(file.Path().c_str());
        }
    } else if (args.Kind() == ExtendedActivationKind::Launch) {
        // Unpackaged AppLifecycle launch Arguments includes the executable name.
        auto arguments = args.Data().as<Windows::ApplicationModel::Activation::ILaunchActivatedEventArgs>().Arguments();
        int count = 0;
        auto raw = CommandLineToArgvW(arguments.c_str(), &count);
        if (!raw) throw_last_error();
        struct FreeArguments { void operator()(wchar_t** value) const { LocalFree(value); } };
        std::unique_ptr<wchar_t*, FreeArguments> owner(raw);
        for (int index = 1; index < count; ++index) {
            std::filesystem::path path(raw[index]);
            if (!cold && !path.is_absolute())
                throw std::runtime_error("SSMV is already running. Open files with an absolute path (for example, C:\\Documents\\notes.md).");
            paths.push_back(std::filesystem::absolute(path).lexically_normal());
        }
    }
    return paths;
}

struct RedirectCompletion {
    HANDLE event = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    std::exception_ptr error;
    RedirectCompletion() { if (!event) throw_last_error(); }
    ~RedirectCompletion() { CloseHandle(event); }
};

fire_and_forget redirect(AppInstance target, AppActivationArguments arguments,
                       std::shared_ptr<RedirectCompletion> completion) {
    try {
        co_await target.RedirectActivationToAsync(arguments);
    } catch (...) { completion->error = std::current_exception(); }
    SetEvent(completion->event);
}
}

struct Activation::State : std::enable_shared_from_this<Activation::State> {
    std::mutex mutex;
    std::deque<std::vector<std::filesystem::path>> pending;
    winrt::Microsoft::UI::Dispatching::DispatcherQueue dispatcher{nullptr};
    Handler handler;
    AppInstance current{nullptr};
    winrt::event_token token{};
    bool subscribed = false;
    bool stopped = false;
    bool scheduled = false;

    // Called under mutex. The UI callback never accesses the application after stop().
    void schedule() {
        if (stopped || scheduled || !dispatcher || !handler || pending.empty()) return;
        scheduled = true;
        auto self = shared_from_this();
        if (!dispatcher.TryEnqueue([self] {
            for (;;) {
                Handler callback;
                std::vector<std::filesystem::path> paths;
                {
                    std::lock_guard lock(self->mutex);
                    if (self->stopped || self->pending.empty()) {
                        self->scheduled = false;
                        return;
                    }
                    paths = std::move(self->pending.front());
                    self->pending.pop_front();
                    callback = self->handler;
                }
                try { if (callback) callback(std::move(paths)); }
                catch (...) { OutputDebugStringW(L"SSMV activation callback failed.\n"); }
            }
        })) scheduled = false;
    }

    void enqueue(std::vector<std::filesystem::path> paths) {
        std::lock_guard lock(mutex);
        if (stopped) return;
        pending.push_back(std::move(paths));
        schedule();
    }
};

Activation::Activation() : state_(std::make_shared<State>()) {}
Activation::~Activation() { stop(); }

bool Activation::redirectToExisting() {
    auto state = state_;
    state->current = AppInstance::GetCurrent();
    auto args = state->current.GetActivatedEventArgs();
    state->enqueue(activationPaths(args, true));
    // Subscribe before claiming the key: a second process may arrive immediately.
    state->token = state->current.Activated([state](auto const&, AppActivationArguments const& arguments) {
        try { state->enqueue(activationPaths(arguments, false)); }
        catch (...) { OutputDebugStringW(L"SSMV rejected invalid forwarded activation.\n"); }
    });
    state->subscribed = true;
    auto target = AppInstance::FindOrRegisterForKey(L"SSMV.MainWindow.v1");
    if (target.IsCurrent()) return false;

    // Validate on the sender, where failure can be shown, before forwarding.
    (void)activationPaths(args, false);
    AllowSetForegroundWindow(target.ProcessId());
    auto completion = std::make_shared<RedirectCompletion>();
    redirect(target, args, completion);
    DWORD index = 0;
    auto handle = completion->event;
    // Keep COM calls dispatched while the redirection is pending on the STA.
    winrt::check_hresult(CoWaitForMultipleHandles(COWAIT_DISPATCH_CALLS | COWAIT_DISPATCH_WINDOW_MESSAGES,
                                                 INFINITE, 1, &handle, &index));
    if (completion->error) std::rethrow_exception(completion->error);
    stop();
    return true;
}

void Activation::attach(winrt::Microsoft::UI::Dispatching::DispatcherQueue const& dispatcher, Handler handler) {
    std::lock_guard lock(state_->mutex);
    if (state_->stopped) return;
    state_->dispatcher = dispatcher;
    state_->handler = std::move(handler);
    state_->schedule();
}

void Activation::stop() noexcept {
    auto state = state_;
    {
        std::lock_guard lock(state->mutex);
        state->stopped = true;
        state->pending.clear();
        state->handler = {};
        state->dispatcher = nullptr;
    }
    if (state->subscribed) {
        try { state->current.Activated(state->token); } catch (...) {}
        state->subscribed = false;
    }
}
}
