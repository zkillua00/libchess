#pragma once

#include "App.xaml.g.h"

namespace winrt::LibChess::WinUI::implementation
{
    struct MainWindow;

    struct App : AppT<App>
    {
        App();
        winrt::fire_and_forget OnLaunched(Microsoft::UI::Xaml::LaunchActivatedEventArgs const&);

    private:
        void OnActivated(
            Windows::Foundation::IInspectable const&,
            Microsoft::Windows::AppLifecycle::AppActivationArguments const& args);
        void HandleActivation(
            Microsoft::Windows::AppLifecycle::AppActivationArguments const& args);

        Microsoft::Windows::AppLifecycle::AppInstance app_instance_{ nullptr };
        winrt::event_token activated_token_{};
        winrt::com_ptr<MainWindow> main_window_;
        Microsoft::UI::Xaml::Window window_{ nullptr };
    };
}
