#include "pch.h"
#include "NativeClient.h"

namespace
{
    constexpr std::uint32_t ApiVersion = 1;
    constexpr std::int32_t SendOk = 0;

    template<typename Function>
    Function LoadFunction(HMODULE module, char const* name)
    {
        auto const address = GetProcAddress(module, name);
        if (!address)
        {
            throw std::runtime_error("LibChess couldn't start because a required component is damaged.");
        }
        return reinterpret_cast<Function>(address);
    }

    std::runtime_error WindowsError(std::string_view operation)
    {
        auto const code = GetLastError();
        static_cast<void>(operation);
        static_cast<void>(code);
        return std::runtime_error("LibChess couldn't load a required component.");
    }
}

namespace LibChess::Windows
{
    struct NativeClient::CallbackState : std::enable_shared_from_this<CallbackState>
    {
        winrt::Microsoft::UI::Dispatching::DispatcherQueue dispatcher{ nullptr };
        std::mutex mutex;
        EventHandler handler;
        bool active{ true };
    };

    NativeClient::NativeClient(
        winrt::Microsoft::UI::Dispatching::DispatcherQueue const& dispatcher,
        EventHandler handler)
    {
        module_ = LoadLibraryExW(
            L"libchess_ffi.dll",
            nullptr,
            LOAD_LIBRARY_SEARCH_APPLICATION_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        if (!module_)
        {
            throw WindowsError("Loading libchess_ffi.dll");
        }

        try
        {
            auto const api_version = LoadFunction<ApiVersionFunction>(module_, "libchess_api_version");
            auto const create = LoadFunction<CreateFunction>(module_, "libchess_client_create");
            send_ = LoadFunction<SendFunction>(module_, "libchess_client_send");
            destroy_ = LoadFunction<DestroyFunction>(module_, "libchess_client_destroy");

            auto const actual_version = api_version();
            if (actual_version != ApiVersion)
            {
                throw std::runtime_error(
                    "LibChess couldn't start because its components are incompatible.");
            }

            callback_state_ = std::make_shared<CallbackState>();
            callback_state_->dispatcher = dispatcher;
            callback_state_->handler = std::move(handler);
            handle_ = create(&NativeClient::ReceiveEvent, callback_state_.get());
            if (!handle_)
            {
                throw std::runtime_error("LibChess couldn't start.");
            }
        }
        catch (...)
        {
            if (module_)
            {
                FreeLibrary(module_);
                module_ = nullptr;
            }
            throw;
        }
    }

    NativeClient::~NativeClient()
    {
        if (callback_state_)
        {
            std::scoped_lock const lock(callback_state_->mutex);
            callback_state_->active = false;
            callback_state_->handler = {};
        }
        if (handle_ && destroy_)
        {
            destroy_(handle_);
            handle_ = nullptr;
        }
        callback_state_.reset();
        if (module_)
        {
            FreeLibrary(module_);
            module_ = nullptr;
        }
    }

    void NativeClient::Send(std::string const& json) const
    {
        if (!handle_ || !send_)
        {
            throw std::runtime_error("LibChess isn't available right now.");
        }
        auto const* bytes = reinterpret_cast<std::uint8_t const*>(json.data());
        auto const result = send_(handle_, bytes, json.size());
        if (result != SendOk)
        {
            throw std::runtime_error("LibChess couldn't complete that action.");
        }
    }

    void __cdecl NativeClient::ReceiveEvent(
        void* context,
        std::uint8_t const* bytes,
        std::size_t length) noexcept
    {
        if (!context || !bytes)
        {
            return;
        }

        try
        {
            auto* raw_state = static_cast<CallbackState*>(context);
            auto state = raw_state->shared_from_this();
            std::string payload(reinterpret_cast<char const*>(bytes), length);
            state->dispatcher.TryEnqueue([state = std::move(state), payload = std::move(payload)]
            {
                EventHandler handler;
                {
                    std::scoped_lock const lock(state->mutex);
                    if (!state->active)
                    {
                        return;
                    }
                    handler = state->handler;
                }
                if (handler)
                {
                    handler(payload);
                }
            });
        }
        catch (...)
        {
            // Exceptions must never cross the Rust callback boundary.
        }
    }
}
