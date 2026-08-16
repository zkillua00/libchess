#pragma once

#include "MainWindow.g.h"
#include "NativeClient.h"
#include "WireModels.h"

namespace winrt::LibChess::WinUI::implementation
{
    struct MainWindow : MainWindowT<MainWindow>
    {
        MainWindow();

        void HandleProtocolActivation(winrt::hstring const& callback_url);
        void SetProtocolActivationAvailable(bool available);

        void BackendActionButton_Click(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::RoutedEventArgs const&);
        void MainNavigation_SelectionChanged(
            Microsoft::UI::Xaml::Controls::NavigationView const&,
            Microsoft::UI::Xaml::Controls::NavigationViewSelectionChangedEventArgs const& args);
        void VariantPicker_SelectionChanged(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&);
        void TimeControlPicker_SelectionChanged(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&);
        void InitialTimePicker_SelectionChanged(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&);
        void CreateGame_Click(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::RoutedEventArgs const&);
        void ChangeBackend_Click(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::RoutedEventArgs const&);
        void OfferDraw_Click(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::RoutedEventArgs const&);
        void Resign_Click(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::RoutedEventArgs const&);

    private:
        void InitializeNativeClient();
        void BeginOAuth();
        void ConnectUsingSavedCredential();
        winrt::fire_and_forget LaunchAuthorizationAsync(winrt::hstring authorization_url);
        void UpdateBackendAction();
        bool AuthorizationUrlIsValid(winrt::hstring const& authorization_url) const;
        static bool CallbackUrlIsValid(winrt::hstring const& callback_url);
        void ReceiveNativeEvent(std::string const& payload);
        void SendCommand(Windows::Data::Json::JsonObject const& command);
        void SendGameAction(winrt::hstring const& action);
        void ShowMessage(winrt::hstring const& message, bool error = true);
        void ShowLauncher();
        void ShowWorkspace();
        void SetProviders(std::vector<::LibChess::Windows::Wire::Provider> providers);
        void FocusProvider(std::size_t index, bool select);
        void PopulateNewGameOptions();
        void PopulateClockIncrementOptions(std::uint32_t preferred_increment);
        void UpdateTimeControlEditor();
        Windows::Data::Json::JsonObject SelectedTimeControl();
        void StartCreatedGame(Windows::Data::Json::JsonObject const& game);
        void ShowLiveGame(::LibChess::Windows::Wire::LiveGame game);
        void RenderBoard();
        void Square_Click(
            Windows::Foundation::IInspectable const& sender,
            Microsoft::UI::Xaml::RoutedEventArgs const&);
        void ResizeAndCenter();

        static Windows::UI::Color Color(::LibChess::Windows::Wire::RgbaColor const& color);
        static winrt::hstring PieceFallback(winrt::hstring const& color, winrt::hstring const& role);
        static winrt::hstring ComboTag(Microsoft::UI::Xaml::Controls::ComboBox const& picker);
        static std::uint32_t ComboNumber(Microsoft::UI::Xaml::Controls::ComboBox const& picker);

        std::unique_ptr<::LibChess::Windows::NativeClient> native_client_;
        std::vector<::LibChess::Windows::Wire::Provider> providers_;
        std::optional<std::size_t> selected_provider_;
        std::optional<::LibChess::Windows::Wire::LiveGame> live_game_;
        ::LibChess::Windows::Wire::BoardPresentation board_presentation_;
        winrt::hstring selected_square_;
        bool protocol_activation_available_{ true };
        bool oauth_authorizing_{ false };
        bool connecting_with_saved_credential_{ false };
        bool populating_time_controls_{ false };
        std::uint64_t next_request_id_{ 1 };
    };
}

namespace winrt::LibChess::WinUI::factory_implementation
{
    struct MainWindow : MainWindowT<MainWindow, implementation::MainWindow> {};
}
