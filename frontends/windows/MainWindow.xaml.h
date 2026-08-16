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
        void BoardAppearancePicker_SelectionChanged(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&);
        void GameAppearance_Click(
            Windows::Foundation::IInspectable const& sender,
            Microsoft::UI::Xaml::RoutedEventArgs const&);
        void OpenAppearanceEditor_Click(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::RoutedEventArgs const&);
        void BoardZoomPicker_SelectionChanged(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&);
        void SettingsBoardAppearancePicker_SelectionChanged(
            Windows::Foundation::IInspectable const& sender,
            Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&);
        void SettingsBoardZoomPicker_SelectionChanged(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&);
        void CustomBoardThemePicker_SelectionChanged(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&);
        void CustomPieceThemePicker_SelectionChanged(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&);
        void BoardThemeProviderBox_SelectionChanged(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&);
        void PieceThemeProviderBox_SelectionChanged(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&);
        void NewBoardTheme_Click(Windows::Foundation::IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
        void SaveBoardTheme_Click(Windows::Foundation::IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
        void RemoveBoardTheme_Click(Windows::Foundation::IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
        void NewPieceTheme_Click(Windows::Foundation::IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
        void SavePieceTheme_Click(Windows::Foundation::IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
        void RemovePieceTheme_Click(Windows::Foundation::IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
        void ImportPieceSvgFolder_Click(Windows::Foundation::IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
        void ClearPieceAssets_Click(Windows::Foundation::IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
        void FloatingBoard_Click(Windows::Foundation::IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
        void ExportPgn_Click(Windows::Foundation::IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&);
        void CreateGame_Click(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::RoutedEventArgs const&);
        void ChangeBackend_Click(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::RoutedEventArgs const&);
        void OfferDraw_Click(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::RoutedEventArgs const&);
        void OfferTakeback_Click(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::RoutedEventArgs const&);
        void AcceptOffer_Click(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::RoutedEventArgs const&);
        void DeclineOffer_Click(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::RoutedEventArgs const&);
        void ClaimVictory_Click(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::RoutedEventArgs const&);
        void ClaimDraw_Click(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::RoutedEventArgs const&);
        void OpenGame_Click(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::RoutedEventArgs const&);
        void ReconnectGame_Click(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::RoutedEventArgs const&);
        void Resign_Click(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::RoutedEventArgs const&);
        void RefreshHistory_Click(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::RoutedEventArgs const&);
        void LoadMoreHistory_Click(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::RoutedEventArgs const&);
        void HistoryGame_Click(
            Windows::Foundation::IInspectable const& sender,
            Microsoft::UI::Xaml::RoutedEventArgs const&);
        void GameCard_Click(
            Windows::Foundation::IInspectable const& sender,
            Microsoft::UI::Xaml::RoutedEventArgs const&);
        void ReviewMove_Click(
            Windows::Foundation::IInspectable const& sender,
            Microsoft::UI::Xaml::RoutedEventArgs const&);
        void ReviewFirst_Click(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::RoutedEventArgs const&);
        void ReviewPrevious_Click(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::RoutedEventArgs const&);
        void ReviewNext_Click(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::RoutedEventArgs const&);
        void ReviewLast_Click(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::RoutedEventArgs const&);
        void OpenAnalysis_Click(
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
        winrt::hstring SendCommand(Windows::Data::Json::JsonObject const& command);
        void SendGameAction(winrt::hstring const& action);
        void SubmitMove(winrt::hstring const& move_id);
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
        void SetLiveGames(std::vector<::LibChess::Windows::Wire::LiveGameSummary> games);
        void ClearLiveGames();
        void RefreshLiveGameNavigation();
        void PopulateGamesPage();
        void RefreshGameHistory(bool append);
        void PopulateGameHistory();
        void LoadGameReview(winrt::hstring const& game_id);
        void ShowReviewPosition(std::uint32_t ply);
        void PopulateReview();
        void UpdateReviewAnalysis();
        void RenderReviewBoard();
        void HideWorkspacePanes();
        void StartLiveGame(
            winrt::hstring const& game_id,
            winrt::hstring const& player_color);
        void SelectNavigationForGame(winrt::hstring const& game_id);
        void ShowLiveGame(::LibChess::Windows::Wire::LiveGame game);
        void UpdateGameInspector();
        void UpdateClocks();
        void PopulateMoveList();
        void PopulatePockets();
        void PopulatePocketRow(
            Microsoft::UI::Xaml::Controls::ItemsControl const& row,
            winrt::hstring const& color,
            bool selectable);
        void PocketPiece_Click(
            Windows::Foundation::IInspectable const& sender,
            Microsoft::UI::Xaml::RoutedEventArgs const&);
        void ClockTimer_Tick(
            Windows::Foundation::IInspectable const&,
            Windows::Foundation::IInspectable const&);
        void ShowPromotionMenu(
            Microsoft::UI::Xaml::Controls::Button const& anchor,
            std::vector<::LibChess::Windows::Wire::LegalMove> moves);
        winrt::fire_and_forget ConfirmTerminationAsync();
        winrt::fire_and_forget OpenGameAsync();
        winrt::fire_and_forget OpenAnalysisAsync();
        void PreparePieceAnimations(
            std::optional<::LibChess::Windows::Wire::LiveGame> const& previous,
            ::LibChess::Windows::Wire::LiveGame const& current);
        void RenderBoard();
        void RenderBoardInto(
            Microsoft::UI::Xaml::Controls::Grid const& grid,
            std::optional<::LibChess::Windows::Wire::BoardState> const& board,
            bool black_perspective,
            double square_extent,
            bool interactive);
        void RenderAppearancePreview();
        void RenderFloatingBoard();
        void QueueFloatingBoardClose();
        void CloseFloatingBoard();
        void DetachFloatingBoardSubclass();
        void StopBoardAnimations();
        void ApplyRoundedClip(
            Microsoft::UI::Xaml::FrameworkElement const& element,
            double extent);
        Microsoft::UI::Xaml::FrameworkElement CreatePieceVisual(
            ::LibChess::Windows::Wire::BoardPiece const& piece,
            double square_extent,
            bool separate_xaml_root = false);
        Microsoft::UI::Xaml::Media::Imaging::SvgImageSource SvgSource(
            ::LibChess::Windows::Wire::BoardAsset const& asset,
            ::LibChess::Windows::Wire::RgbaColor const& tint,
            double logical_extent,
            bool separate_xaml_root = false);
        static winrt::fire_and_forget LoadSvgAsync(
            Microsoft::UI::Xaml::Media::Imaging::SvgImageSource source,
            winrt::hstring svg);
        void AnimatePiece(
            Microsoft::UI::Xaml::FrameworkElement const& piece,
            winrt::hstring const& from,
            winrt::hstring const& to,
            bool black_perspective);
        void AnimatePieceAppearance(Microsoft::UI::Xaml::FrameworkElement const& piece);
        void ApplyBoardChrome();
        void PopulateBoardAppearance();
        void PopulateThemeChoices(
            ::LibChess::Windows::Wire::BoardProvider const& provider,
            winrt::hstring const& board_theme,
            winrt::hstring const& piece_theme);
        void RestoreBoardAppearance();
        void RequestBoardPresentation(
            winrt::hstring const& provider,
            winrt::hstring const& board_theme,
            winrt::hstring const& piece_theme);
        void PopulateCustomizationEditors();
        void PopulateSettingsAppearance();
        void PopulateBaseThemes(bool board);
        void ResetBoardThemeEditor();
        void ResetPieceThemeEditor();
        void LoadBoardThemeEditor(Windows::Data::Json::JsonObject const& theme);
        void LoadPieceThemeEditor(Windows::Data::Json::JsonObject const& theme);
        void SaveCustomizationState(Windows::Data::Json::JsonObject const& state);
        void RestoreCustomizationState();
        winrt::fire_and_forget ImportPieceSvgFolderAsync();
        winrt::fire_and_forget SavePgnAsync(winrt::hstring filename, winrt::hstring pgn);
        void OpenFloatingBoard();
        void ConfigureFloatingBoardWindow();
        void SaveFloatingBoardFrame();
        static LRESULT CALLBACK FloatingBoardSubclassProc(
            HWND hwnd,
            UINT message,
            WPARAM wparam,
            LPARAM lparam,
            UINT_PTR subclass_id,
            DWORD_PTR reference_data);
        Microsoft::UI::Xaml::Controls::MenuFlyout BuildFloatingBoardMenu();
        void FloatingBoard_PointerPressed(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::Input::PointerRoutedEventArgs const& args);
        void FloatingBoard_PointerMoved(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::Input::PointerRoutedEventArgs const& args);
        void FloatingBoard_PointerReleased(
            Windows::Foundation::IInspectable const&,
            Microsoft::UI::Xaml::Input::PointerRoutedEventArgs const& args);
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
        std::vector<::LibChess::Windows::Wire::LiveGameSummary> live_game_summaries_;
        std::unordered_map<std::wstring, ::LibChess::Windows::Wire::LiveGame> live_games_;
        std::vector<::LibChess::Windows::Wire::GameHistoryEntry> game_history_;
        std::optional<std::uint64_t> next_history_before_millis_;
        std::optional<::LibChess::Windows::Wire::GameReview> game_review_;
        std::optional<::LibChess::Windows::Wire::BoardState> review_board_;
        winrt::hstring review_game_id_;
        std::uint32_t review_ply_{ 0 };
        bool history_request_pending_{ false };
        bool review_request_pending_{ false };
        winrt::hstring pending_history_request_id_;
        winrt::hstring pending_review_request_id_;
        winrt::hstring pending_review_position_request_id_;
        winrt::hstring pending_export_request_id_;
        winrt::hstring pending_export_game_id_;
        std::unordered_map<std::wstring, bool> live_stream_states_;
        std::unordered_map<std::wstring, winrt::hstring> live_start_requests_;
        std::unordered_map<std::wstring, winrt::hstring> live_latest_start_request_by_game_;
        std::unordered_map<std::wstring, std::chrono::steady_clock::time_point>
            live_game_received_times_;
        std::unordered_map<std::wstring, std::chrono::steady_clock::time_point>
            live_game_claim_received_times_;
        winrt::hstring current_game_id_;
        std::optional<::LibChess::Windows::Wire::BoardState> move_rollback_board_;
        std::optional<std::vector<winrt::hstring>> move_rollback_san_moves_;
        std::optional<std::uint64_t> move_rollback_white_time_millis_;
        std::optional<std::uint64_t> move_rollback_black_time_millis_;
        std::chrono::steady_clock::time_point move_rollback_received_at_{};
        ::LibChess::Windows::Wire::BoardPresentation board_presentation_;
        std::vector<::LibChess::Windows::Wire::BoardProvider> board_providers_;
        Windows::Data::Json::JsonObject board_customization_state_{ nullptr };
        Windows::Data::Json::JsonObject pending_piece_assets_{ nullptr };
        winrt::hstring selected_square_;
        std::unordered_map<std::wstring, winrt::hstring> piece_animation_origins_;
        std::vector<winrt::hstring> piece_appearance_squares_;
        std::unordered_map<std::wstring, Microsoft::UI::Xaml::Media::Imaging::SvgImageSource>
            svg_sources_;
        std::vector<Microsoft::UI::Xaml::Media::Animation::Storyboard> active_storyboards_;
        std::uint32_t board_zoom_scale_percent_{ 100 };
        winrt::hstring pending_board_presentation_request_id_;
        winrt::hstring pending_customization_request_id_;
        Microsoft::UI::Xaml::Window floating_board_window_{ nullptr };
        Microsoft::UI::Xaml::Controls::Grid floating_board_root_{ nullptr };
        Microsoft::UI::Xaml::Controls::Grid floating_board_grid_{ nullptr };
        winrt::event_token floating_board_closed_token_{};
        HWND floating_board_hwnd_{ nullptr };
        RECT floating_board_resize_origin_window_{};
        std::uint32_t floating_board_drag_pointer_id_{ 0 };
        POINT floating_board_drag_origin_cursor_{};
        RECT floating_board_drag_origin_window_{};
        bool floating_board_drag_pending_{ false };
        bool floating_board_drag_started_{ false };
        bool floating_board_close_pending_{ false };
        winrt::hstring selected_drop_;
        winrt::hstring incoming_offer_;
        winrt::hstring pending_move_request_id_;
        winrt::hstring pending_game_action_request_id_;
        Microsoft::UI::Xaml::DispatcherTimer clock_timer_{ nullptr };
        std::chrono::steady_clock::time_point live_game_received_at_{};
        std::chrono::steady_clock::time_point live_game_claim_received_at_{};
        bool live_stream_connected_{ true };
        bool termination_dialog_open_{ false };
        bool populating_board_appearance_{ false };
        bool populating_customization_{ false };
        bool customization_state_restored_{ false };
        bool customization_edit_pending_{ false };
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
