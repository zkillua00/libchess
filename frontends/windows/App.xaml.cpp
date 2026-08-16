#include "pch.h"
#include "App.xaml.h"
#include "DiagnosticLog.h"
#include "MainWindow.xaml.h"

namespace
{
    constexpr wchar_t InstanceKey[] = L"LibChess.Main";
    constexpr wchar_t OAuthScheme[] = L"org.libchess.windows";

    std::wstring ExecutablePath()
    {
        std::vector<wchar_t> path(32'768);
        auto const length = GetModuleFileNameW(
            nullptr,
            path.data(),
            static_cast<DWORD>(path.size()));
        if (length == 0 || length >= path.size())
        {
            throw winrt::hresult_error(HRESULT_FROM_WIN32(GetLastError()));
        }
        return std::wstring(path.data(), length);
    }
}

namespace winrt::LibChess::WinUI::implementation
{
    App::App()
    {
        InitializeComponent();

#if defined(_DEBUG) && !defined(DISABLE_XAML_GENERATED_BREAK_ON_UNHANDLED_EXCEPTION)
        UnhandledException([](auto const&, Microsoft::UI::Xaml::UnhandledExceptionEventArgs const& args)
        {
            if (IsDebuggerPresent())
            {
                auto const message = args.Message();
                static_cast<void>(message);
                __debugbreak();
            }
        });
#endif
    }

    winrt::fire_and_forget App::OnLaunched(
        Microsoft::UI::Xaml::LaunchActivatedEventArgs const&)
    {
        auto lifetime = get_strong();
        try
        {
            auto const main_instance =
                Microsoft::Windows::AppLifecycle::AppInstance::FindOrRegisterForKey(InstanceKey);
            if (!main_instance.IsCurrent())
            {
                auto const activation = Microsoft::Windows::AppLifecycle::AppInstance::GetCurrent()
                    .GetActivatedEventArgs();
                co_await main_instance.RedirectActivationToAsync(activation);
                ExitProcess(0);
                co_return;
            }

            app_instance_ = Microsoft::Windows::AppLifecycle::AppInstance::GetCurrent();
            activated_token_ = app_instance_.Activated({ this, &App::OnActivated });

            bool protocol_available = true;
            try
            {
                auto const executable = ExecutablePath();
                Microsoft::Windows::AppLifecycle::ActivationRegistrationManager::
                    RegisterForProtocolActivation(
                        OAuthScheme,
                        executable + L",0",
                        L"LibChess sign-in",
                        executable);
            }
            catch (winrt::hresult_error const& error)
            {
                protocol_available = false;
                ::LibChess::Windows::DiagnosticLog::Write(
                    L"activation",
                    L"Protocol registration failed: " + error.message());
            }
            catch (std::exception const& error)
            {
                protocol_available = false;
                ::LibChess::Windows::DiagnosticLog::Write(
                    L"activation",
                    L"Protocol registration failed: " + winrt::to_hstring(error.what()));
            }

            main_window_ = winrt::make_self<MainWindow>();
            main_window_->SetProtocolActivationAvailable(protocol_available);
            window_ = *main_window_;
            window_.Activate();
            HandleActivation(app_instance_.GetActivatedEventArgs());
        }
        catch (winrt::hresult_error const& error)
        {
            ::LibChess::Windows::DiagnosticLog::Write(
                L"startup",
                L"Window startup failed: " + error.message());
            MessageBoxW(
                nullptr,
                L"LibChess couldn't open. Try restarting the app.",
                L"LibChess startup failure",
                MB_OK | MB_ICONERROR);
        }
    }

    void App::OnActivated(
        Windows::Foundation::IInspectable const&,
        Microsoft::Windows::AppLifecycle::AppActivationArguments const& args)
    {
        if (!window_)
        {
            return;
        }
        auto const weak = get_weak();
        window_.DispatcherQueue().TryEnqueue([weak, args]
        {
            if (auto const app = weak.get())
            {
                app->HandleActivation(args);
            }
        });
    }

    void App::HandleActivation(
        Microsoft::Windows::AppLifecycle::AppActivationArguments const& args)
    {
        using Microsoft::Windows::AppLifecycle::ExtendedActivationKind;
        if (!main_window_ || args.Kind() != ExtendedActivationKind::Protocol)
        {
            return;
        }
        auto const protocol =
            args.Data().try_as<Windows::ApplicationModel::Activation::IProtocolActivatedEventArgs>();
        if (!protocol || !protocol.Uri())
        {
            ::LibChess::Windows::DiagnosticLog::Write(
                L"activation",
                L"Protocol activation did not contain a URI.");
            return;
        }
        ::LibChess::Windows::DiagnosticLog::Write(
            L"activation",
            L"Protocol activation was redirected to the primary app instance.");
        main_window_->HandleProtocolActivation(protocol.Uri().RawUri());
        window_.Activate();
    }
}
