#pragma once

namespace LibChess::Windows
{
    class NativeClient final
    {
    public:
        using EventHandler = std::function<void(std::string const&)>;

        NativeClient(
            winrt::Microsoft::UI::Dispatching::DispatcherQueue const& dispatcher,
            EventHandler handler);
        ~NativeClient();

        NativeClient(NativeClient const&) = delete;
        NativeClient& operator=(NativeClient const&) = delete;
        NativeClient(NativeClient&&) = delete;
        NativeClient& operator=(NativeClient&&) = delete;

        void Send(std::string const& json) const;

    private:
        struct CallbackState;

        using EventCallback = void(__cdecl*)(void*, std::uint8_t const*, std::size_t);
        using ApiVersionFunction = std::uint32_t(__cdecl*)();
        using CreateFunction = void*(__cdecl*)(EventCallback, void*);
        using SendFunction = std::int32_t(__cdecl*)(void*, std::uint8_t const*, std::size_t);
        using DestroyFunction = void(__cdecl*)(void*);

        static void __cdecl ReceiveEvent(
            void* context,
            std::uint8_t const* bytes,
            std::size_t length) noexcept;

        HMODULE module_{ nullptr };
        void* handle_{ nullptr };
        SendFunction send_{ nullptr };
        DestroyFunction destroy_{ nullptr };
        std::shared_ptr<CallbackState> callback_state_;
    };
}
