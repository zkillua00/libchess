#include "pch.h"
#include "CredentialStore.h"
#include "DiagnosticLog.h"
#include "MainWindow.xaml.h"

#if __has_include("MainWindow.g.cpp")
#include "MainWindow.g.cpp"
#endif

#include <microsoft.ui.xaml.window.h>

namespace
{
    constexpr wchar_t OAuthClientId[] = L"org.libchess.windows";
    constexpr wchar_t OAuthRedirectUri[] = L"org.libchess.windows://oauth/lichess";
    constexpr wchar_t PreferenceKeyPath[] = L"Software\\LibChess\\Windows";
    constexpr wchar_t CustomizationFileName[] = L"board-customization.json";
    constexpr UINT_PTR FloatingBoardSubclassId = 0x4C434642;

    using namespace winrt;
    using namespace Windows::Data::Json;
    using namespace Microsoft::UI::Xaml;
    using namespace Microsoft::UI::Xaml::Controls;
    using namespace Microsoft::UI::Xaml::Media;

    JsonObject Object(JsonObject const& parent, wchar_t const* name)
    {
        if (!parent || !parent.HasKey(name))
        {
            return nullptr;
        }
        auto const value = parent.GetNamedValue(name);
        return value.ValueType() == JsonValueType::Object ? value.GetObject() : nullptr;
    }

    JsonArray Array(JsonObject const& parent, wchar_t const* name)
    {
        if (!parent || !parent.HasKey(name))
        {
            return nullptr;
        }
        auto const value = parent.GetNamedValue(name);
        return value.ValueType() == JsonValueType::Array ? value.GetArray() : nullptr;
    }

    hstring String(JsonObject const& parent, wchar_t const* name)
    {
        if (!parent || !parent.HasKey(name))
        {
            return {};
        }
        auto const value = parent.GetNamedValue(name);
        return value.ValueType() == JsonValueType::String ? value.GetString() : hstring{};
    }

    JsonValue JsonString(hstring const& value)
    {
        return JsonValue::CreateStringValue(value);
    }

    JsonValue JsonNumber(double value)
    {
        return JsonValue::CreateNumberValue(value);
    }

    JsonValue JsonBool(bool value)
    {
        return JsonValue::CreateBooleanValue(value);
    }

    JsonObject JsonColor(Windows::UI::Color const& color)
    {
        JsonObject json;
        json.Insert(L"red", JsonNumber(color.R));
        json.Insert(L"green", JsonNumber(color.G));
        json.Insert(L"blue", JsonNumber(color.B));
        json.Insert(L"alpha", JsonNumber(color.A));
        return json;
    }

    Windows::UI::Color JsonUiColor(
        JsonObject const& object,
        Windows::UI::Color const& fallback)
    {
        if (!object)
        {
            return fallback;
        }
        auto component = [&](wchar_t const* name, std::uint8_t value)
        {
            if (!object.HasKey(name)
                || object.GetNamedValue(name).ValueType() != JsonValueType::Number)
            {
                return value;
            }
            return static_cast<std::uint8_t>((std::clamp)(
                object.GetNamedNumber(name), 0.0, 255.0));
        };
        return Windows::UI::Color{
            component(L"alpha", fallback.A), component(L"red", fallback.R),
            component(L"green", fallback.G), component(L"blue", fallback.B) };
    }

    bool IsStableThemeId(hstring const& value)
    {
        return !value.empty() && value.size() <= 64
            && std::all_of(value.begin(), value.end(), [](wchar_t character)
            {
                return (character >= L'a' && character <= L'z')
                    || (character >= L'0' && character <= L'9') || character == L'-';
            });
    }

    std::filesystem::path CustomizationPath()
    {
        PWSTR local_app_data = nullptr;
        if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_DEFAULT, nullptr,
            &local_app_data)))
        {
            return {};
        }
        std::filesystem::path path(local_app_data);
        CoTaskMemFree(local_app_data);
        path /= L"LibChess";
        std::error_code error;
        std::filesystem::create_directories(path, error);
        return error ? std::filesystem::path{} : path / CustomizationFileName;
    }

    hstring CustomThemeKey(JsonObject const& theme)
    {
        return String(theme, L"provider") + L"|" + String(theme, L"id");
    }

    std::pair<hstring, hstring> SplitThemeKey(hstring const& key)
    {
        auto const text = std::wstring(key);
        auto const separator = text.find(L'|');
        return separator == std::wstring::npos
            ? std::pair<hstring, hstring>{ {}, {} }
            : std::pair<hstring, hstring>{
                hstring(text.substr(0, separator)), hstring(text.substr(separator + 1)) };
    }

    bool EqualIgnoringCase(hstring const& left, hstring const& right)
    {
        return CompareStringOrdinal(
            left.c_str(),
            static_cast<int>(left.size()),
            right.c_str(),
            static_cast<int>(right.size()),
            TRUE) == CSTR_EQUAL;
    }

    SolidColorBrush CreateBrush(Windows::UI::Color const& color)
    {
        return SolidColorBrush(color);
    }

    void SelectComboTag(ComboBox const& combo, hstring const& wanted)
    {
        for (std::uint32_t index = 0; index < combo.Items().Size(); ++index)
        {
            auto const item = combo.Items().GetAt(index).try_as<ComboBoxItem>();
            if (item && unbox_value_or<hstring>(item.Tag(), {}) == wanted)
            {
                combo.SelectedIndex(static_cast<std::int32_t>(index));
                return;
            }
        }
        if (combo.Items().Size() > 0)
        {
            combo.SelectedIndex(0);
        }
    }

    void AppendComboItem(ComboBox const& combo, hstring const& title, hstring const& tag)
    {
        ComboBoxItem item;
        item.Content(box_value(title));
        item.Tag(box_value(tag));
        combo.Items().Append(item);
    }

    hstring FormatInitialTime(std::uint32_t seconds)
    {
        if (seconds < 60)
        {
            return winrt::to_hstring(seconds) + (seconds == 1 ? L" second" : L" seconds");
        }
        if (seconds % 3600 == 0)
        {
            auto const hours = seconds / 3600;
            return winrt::to_hstring(hours) + (hours == 1 ? L" hour" : L" hours");
        }
        if (seconds % 60 == 0)
        {
            auto const minutes = seconds / 60;
            return winrt::to_hstring(minutes) + (minutes == 1 ? L" minute" : L" minutes");
        }
        return winrt::to_hstring(seconds / 60) + L" min "
            + winrt::to_hstring(seconds % 60) + L" sec";
    }

    hstring FormatIncrement(std::uint32_t seconds)
    {
        if (seconds == 0)
        {
            return L"No increment";
        }
        return winrt::to_hstring(seconds) + (seconds == 1 ? L" second" : L" seconds");
    }

    hstring FormatDays(std::uint32_t days)
    {
        return winrt::to_hstring(days) + (days == 1 ? L" day" : L" days");
    }

    hstring PlayerDisplayName(::LibChess::Windows::Wire::LiveGamePlayer const& player)
    {
        return player.title.empty()
            ? player.name
            : player.title + L" " + player.name;
    }

    hstring PlayerMetadata(
        ::LibChess::Windows::Wire::LiveGamePlayer const& player,
        bool is_you)
    {
        std::vector<std::wstring> values;
        if (player.rating)
        {
            values.push_back(std::to_wstring(*player.rating)
                + (player.provisional ? L"?" : L""));
        }
        if (player.ai_level)
        {
            values.push_back(L"Level " + std::to_wstring(*player.ai_level));
        }
        if (is_you)
        {
            values.push_back(L"You");
        }
        std::wstring result;
        for (auto const& value : values)
        {
            if (!result.empty())
            {
                result += L" · ";
            }
            result += value;
        }
        return hstring(result);
    }

    hstring DisplayLabel(hstring const& value)
    {
        static std::unordered_map<std::wstring, std::wstring> const labels{
            { L"created", L"Created" }, { L"started", L"In progress" },
            { L"aborted", L"Aborted" }, { L"mate", L"Checkmate" },
            { L"resign", L"Resignation" }, { L"stalemate", L"Stalemate" },
            { L"timeout", L"Time expired" }, { L"outoftime", L"Time expired" },
            { L"draw", L"Draw" }, { L"cheat", L"Fair-play termination" },
            { L"noStart", L"Game not started" },
            { L"insufficientMaterialClaim", L"Insufficient material" },
            { L"variantEnd", L"Variant victory" },
        };
        if (auto const found = labels.find(std::wstring(value)); found != labels.end())
        {
            return hstring(found->second);
        }
        auto label = std::wstring(value);
        std::replace(label.begin(), label.end(), L'_', L' ');
        std::replace(label.begin(), label.end(), L'-', L' ');
        if (!label.empty())
        {
            label[0] = static_cast<wchar_t>(std::towupper(label[0]));
        }
        return hstring(label);
    }

    hstring RoleDisplayName(hstring const& role)
    {
        auto label = DisplayLabel(role);
        return label.empty() ? L"Piece" : label;
    }

    std::pair<int, int> DisplayLocation(hstring const& square, bool black_perspective)
    {
        if (square.size() != 2 || square[0] < L'a' || square[0] > L'h'
            || square[1] < L'1' || square[1] > L'8')
        {
            return { 0, 0 };
        }
        auto const file = static_cast<int>(square[0] - L'a');
        auto const rank = static_cast<int>(square[1] - L'0');
        return black_perspective
            ? std::pair{ rank - 1, 7 - file }
            : std::pair{ 8 - rank, file };
    }

    int SquareDistance(hstring const& left, hstring const& right)
    {
        if (left.size() != 2 || right.size() != 2)
        {
            return INT_MAX;
        }
        return std::abs(static_cast<int>(left[0]) - static_cast<int>(right[0]))
            + std::abs(static_cast<int>(left[1]) - static_cast<int>(right[1]));
    }

    std::wstring HexColor(::LibChess::Windows::Wire::RgbaColor const& color)
    {
        wchar_t value[8]{};
        swprintf_s(value, L"#%02X%02X%02X", color.red, color.green, color.blue);
        return value;
    }

    hstring TintSvg(
        hstring const& svg,
        ::LibChess::Windows::Wire::RgbaColor const& color)
    {
        auto result = std::wstring(svg);
        auto const replacement = HexColor(color);
        for (auto const attribute : { std::wstring_view(L"fill="), std::wstring_view(L"stroke=") })
        {
            std::size_t cursor = 0;
            while ((cursor = result.find(attribute, cursor)) != std::wstring::npos)
            {
                auto const quote_index = cursor + attribute.size();
                if (quote_index >= result.size()
                    || (result[quote_index] != L'\"' && result[quote_index] != L'\''))
                {
                    cursor = quote_index;
                    continue;
                }
                auto const quote = result[quote_index];
                auto const value_start = quote_index + 1;
                auto const value_end = result.find(quote, value_start);
                if (value_end == std::wstring::npos)
                {
                    break;
                }
                auto const value = result.substr(value_start, value_end - value_start);
                if (_wcsicmp(value.c_str(), L"none") != 0
                    && _wcsicmp(value.c_str(), L"transparent") != 0)
                {
                    result.replace(value_start, value.size(), replacement);
                    cursor = value_start + replacement.size();
                }
                else
                {
                    cursor = value_end + 1;
                }
            }
        }
        return hstring(result);
    }

    hstring ReadPreference(wchar_t const* name)
    {
        wchar_t value[256]{};
        DWORD size = sizeof(value);
        DWORD type = 0;
        if (RegGetValueW(
                HKEY_CURRENT_USER,
                PreferenceKeyPath,
                name,
                RRF_RT_REG_SZ,
                &type,
                value,
                &size) != ERROR_SUCCESS)
        {
            return {};
        }
        return hstring(value);
    }

    void WritePreference(wchar_t const* name, hstring const& value)
    {
        HKEY key = nullptr;
        if (RegCreateKeyExW(
                HKEY_CURRENT_USER,
                PreferenceKeyPath,
                0,
                nullptr,
                REG_OPTION_NON_VOLATILE,
                KEY_SET_VALUE,
                nullptr,
                &key,
                nullptr) != ERROR_SUCCESS)
        {
            return;
        }
        auto const size = static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t));
        static_cast<void>(RegSetValueExW(
            key,
            name,
            0,
            REG_SZ,
            reinterpret_cast<BYTE const*>(value.c_str()),
            size));
        RegCloseKey(key);
    }
}

namespace winrt::LibChess::WinUI::implementation
{
    MainWindow::MainWindow()
    {
        InitializeComponent();
        Title(L"LibChess");
        SystemBackdrop(Media::MicaBackdrop());
        ExtendsContentIntoTitleBar(true);
        SetTitleBar(AppTitleBar());
        MainNavigation().SelectedItem(MainNavigation().MenuItems().GetAt(0));
        clock_timer_ = Microsoft::UI::Xaml::DispatcherTimer();
        clock_timer_.Interval(Windows::Foundation::TimeSpan{ 1'000'000 });
        clock_timer_.Tick({ this, &MainWindow::ClockTimer_Tick });
        ResizeAndCenter();
        InitializeNativeClient();
    }

    void MainWindow::InitializeNativeClient()
    {
        try
        {
            native_client_ = std::make_unique<::LibChess::Windows::NativeClient>(
                DispatcherQueue(),
                [this](std::string const& payload)
                {
                    ReceiveNativeEvent(payload);
                });
        }
        catch (std::exception const& error)
        {
            BackendLoading().Visibility(Visibility::Collapsed);
            ShowMessage(winrt::to_hstring(error.what()));
        }
    }

    void MainWindow::ReceiveNativeEvent(std::string const& payload)
    {
        try
        {
            auto const event = ::LibChess::Windows::Wire::ParseObject(payload);
            auto const type = String(event, L"type");

            if (type == L"ready" || type == L"providers")
            {
                SetProviders(::LibChess::Windows::Wire::ParseProviders(Array(event, L"providers")));
                if (auto const board_providers = Array(event, L"board_providers"))
                {
                    board_providers_ =
                        ::LibChess::Windows::Wire::ParseBoardProviders(board_providers);
                }
                if (auto const customization = Object(event, L"board_customization"))
                {
                    board_customization_state_ = customization;
                    PopulateCustomizationEditors();
                    if (!customization_state_restored_)
                    {
                        customization_state_restored_ = true;
                        RestoreCustomizationState();
                    }
                }
                if (auto const selected = Object(event, L"selected_backend"))
                {
                    auto const id = String(selected, L"id");
                    auto const found = std::find_if(
                        providers_.begin(),
                        providers_.end(),
                        [&](auto const& provider) { return provider.id == id; });
                    if (found != providers_.end())
                    {
                        FocusProvider(
                            static_cast<std::size_t>(found - providers_.begin()),
                            false);
                    }
                }
                if (auto const presentation = Object(event, L"board_presentation"))
                {
                    board_presentation_ =
                        ::LibChess::Windows::Wire::ParseBoardPresentation(presentation);
                    svg_sources_.clear();
                    PopulateBoardAppearance();
                    PopulateSettingsAppearance();
                    RestoreBoardAppearance();
                    RenderAppearancePreview();
                }
                return;
            }
            if (type == L"board_presentation_loaded")
            {
                auto const request_id = String(event, L"request_id");
                if (!pending_board_presentation_request_id_.empty()
                    && request_id != pending_board_presentation_request_id_)
                {
                    return;
                }
                AppearanceProgress().Visibility(Visibility::Collapsed);
                if (auto const presentation = Object(event, L"board_presentation"))
                {
                    board_presentation_ =
                        ::LibChess::Windows::Wire::ParseBoardPresentation(presentation);
                    svg_sources_.clear();
                    WritePreference(L"BoardProvider", board_presentation_.provider);
                    WritePreference(L"BoardTheme", board_presentation_.board_theme);
                    WritePreference(L"PieceTheme", board_presentation_.piece_theme);
                    auto const settings_visible =
                        AppearancePane().Visibility() == Visibility::Visible;
                    if (settings_visible) PopulateSettingsAppearance();
                    else PopulateBoardAppearance();
                    populating_board_appearance_ = true;
                    if (settings_visible)
                    {
                        SelectComboTag(SettingsBoardProviderPicker(), board_presentation_.provider);
                        SelectComboTag(SettingsBoardThemePicker(), board_presentation_.board_theme);
                        SelectComboTag(SettingsPieceThemePicker(), board_presentation_.piece_theme);
                    }
                    else
                    {
                        SelectComboTag(BoardProviderPicker(), board_presentation_.provider);
                        SelectComboTag(BoardThemePicker(), board_presentation_.board_theme);
                        SelectComboTag(PieceThemePicker(), board_presentation_.piece_theme);
                    }
                    populating_board_appearance_ = false;
                    UpdateGameInspector();
                    RenderBoard();
                    RenderReviewBoard();
                    RenderAppearancePreview();
                    RenderFloatingBoard();
                }
                return;
            }
            if (type == L"board_customization_changed")
            {
                if (auto const board_providers = Array(event, L"board_providers"))
                {
                    board_providers_ =
                        ::LibChess::Windows::Wire::ParseBoardProviders(board_providers);
                }
                if (auto const customization = Object(event, L"board_customization"))
                {
                    board_customization_state_ = customization;
                    SaveCustomizationState(customization);
                }
                auto const user_edit = customization_edit_pending_;
                pending_customization_request_id_.clear();
                customization_edit_pending_ = false;
                PopulateBoardAppearance();
                PopulateSettingsAppearance();
                PopulateCustomizationEditors();
                RestoreBoardAppearance();
                if (user_edit)
                {
                    AppearanceInfoBar().Severity(InfoBarSeverity::Success);
                    AppearanceInfoBar().Message(L"Theme library saved.");
                    AppearanceInfoBar().IsOpen(true);
                }
                return;
            }
            if (type == L"backend_selection_changed")
            {
                auto const backend = Object(event, L"backend");
                if (!backend)
                {
                    selected_provider_.reset();
                    ClearLiveGames();
                    ShowLauncher();
                    return;
                }
                auto const id = String(backend, L"id");
                auto const found = std::find_if(providers_.begin(), providers_.end(), [&](auto const& provider)
                {
                    return provider.id == id;
                });
                if (found != providers_.end())
                {
                    FocusProvider(static_cast<std::size_t>(found - providers_.begin()), false);
                }
                return;
            }
            if (type == L"oauth_authorization_required")
            {
                ::LibChess::Windows::DiagnosticLog::Write(
                    L"wire",
                    L"Received oauth_authorization_required from Rust.");
                auto const provider = String(event, L"provider");
                auto const authorization_url = String(event, L"authorization_url");
                if (!selected_provider_ || *selected_provider_ >= providers_.size() ||
                    providers_[*selected_provider_].id != provider ||
                    !AuthorizationUrlIsValid(authorization_url))
                {
                    ::LibChess::Windows::DiagnosticLog::Write(
                        L"oauth",
                        L"The authorization request failed frontend origin validation.");
                    JsonObject cancel;
                    cancel.Insert(L"type", JsonString(L"cancel_oauth"));
                    SendCommand(cancel);
                    oauth_authorizing_ = false;
                    BackendProgress().Visibility(Visibility::Collapsed);
                    UpdateBackendAction();
                    ShowMessage(L"The sign-in request could not be verified.");
                    return;
                }
                LaunchAuthorizationAsync(authorization_url);
                return;
            }
            if (type == L"oauth_credential_issued")
            {
                ::LibChess::Windows::DiagnosticLog::Write(
                    L"wire",
                    L"Received oauth_credential_issued from Rust; credential value omitted.");
                auto const provider = String(event, L"provider");
                auto const access_token = String(event, L"access_token");
                if (!selected_provider_ || *selected_provider_ >= providers_.size() ||
                    providers_[*selected_provider_].id != provider || access_token.empty())
                {
                    ShowMessage(L"The online service returned an invalid sign-in.");
                    return;
                }
                try
                {
                    ::LibChess::Windows::CredentialStore::Save(provider, access_token);
                    UpdateBackendAction();
                }
                catch (std::exception const&)
                {
                    ::LibChess::Windows::DiagnosticLog::Write(
                        L"credential",
                        L"The issued credential could not be saved.");
                    ShowMessage(
                        L"You're signed in, but Windows couldn't save it for next time.");
                }
                return;
            }
            if (type == L"account_updated")
            {
                auto const account = Object(event, L"account");
                auto const username = String(account, L"username");
                auto const title = String(account, L"title");
                AccountName().Text(title.empty()
                    ? username
                    : hstring(std::wstring(title) + L" " + std::wstring(username)));
                return;
            }
            if (type == L"connection_state_changed")
            {
                auto const state = String(event, L"state");
                if (state == L"authorizing" || state == L"connecting" ||
                    state == L"connected" || state == L"disconnected")
                {
                    ::LibChess::Windows::DiagnosticLog::Write(
                        L"wire",
                        L"Rust connection state changed to " + state + L".");
                }
                if (state == L"connected")
                {
                    oauth_authorizing_ = false;
                    connecting_with_saved_credential_ = false;
                    BackendProgress().Visibility(Visibility::Collapsed);
                    ShowWorkspace();
                    auto const supports_live_games = selected_provider_
                        && *selected_provider_ < providers_.size()
                        && providers_[*selected_provider_].Supports(L"live_games");
                    auto const supports_history = selected_provider_
                        && *selected_provider_ < providers_.size()
                        && providers_[*selected_provider_].Supports(L"game_history");
                    BoardNavigationItem().IsEnabled(supports_live_games);
                    HistoryNavigationItem().IsEnabled(supports_history);
                    if (supports_live_games)
                    {
                        JsonObject watch;
                        watch.Insert(L"type", JsonString(L"watch_live_games"));
                        SendCommand(watch);
                        JsonObject refresh;
                        refresh.Insert(L"type", JsonString(L"refresh_live_games"));
                        SendCommand(refresh);
                    }
                    if (supports_history)
                    {
                        RefreshGameHistory(false);
                    }
                }
                else if (state == L"connecting" || state == L"authorizing")
                {
                    oauth_authorizing_ = state == L"authorizing";
                    BackendProgress().Visibility(Visibility::Visible);
                    BackendActionButton().IsEnabled(false);
                }
                else
                {
                    oauth_authorizing_ = false;
                    connecting_with_saved_credential_ = false;
                    BackendProgress().Visibility(Visibility::Collapsed);
                    UpdateBackendAction();
                    if (!selected_provider_)
                    {
                        ShowLauncher();
                    }
                }
                return;
            }
            if (type == L"bot_game_created")
            {
                StartCreatedGame(Object(event, L"game"));
                return;
            }
            if (type == L"live_game_updated")
            {
                if (auto const game = Object(event, L"live_game"))
                {
                    auto parsed = ::LibChess::Windows::Wire::ParseLiveGame(game);
                    if (!current_game_id_.empty() && parsed.id != current_game_id_)
                    {
                        return;
                    }
                    auto const received_at = std::chrono::steady_clock::now();
                    live_game_received_times_.insert_or_assign(
                        std::wstring(parsed.id), received_at);
                    live_game_claim_received_times_.insert_or_assign(
                        std::wstring(parsed.id), received_at);
                    live_stream_states_.insert_or_assign(std::wstring(parsed.id), true);
                    live_games_.insert_or_assign(std::wstring(parsed.id), parsed);
                    if (current_game_id_.empty() || current_game_id_ == parsed.id)
                    {
                        live_stream_connected_ = true;
                        ShowLiveGame(std::move(parsed));
                    }
                    else
                    {
                        RefreshLiveGameNavigation();
                    }
                }
                return;
            }
            if (type == L"live_games_updated")
            {
                SetLiveGames(::LibChess::Windows::Wire::ParseLiveGameSummaries(
                    Array(event, L"games")));
                return;
            }
            if (type == L"game_history_updated")
            {
                auto page = ::LibChess::Windows::Wire::ParseGameHistoryPage(
                    Object(event, L"page"));
                auto const append = event.HasKey(L"append")
                    && event.GetNamedValue(L"append").ValueType() == JsonValueType::Boolean
                    && event.GetNamedBoolean(L"append");
                if (!append)
                {
                    game_history_.clear();
                }
                for (auto& game : page.games)
                {
                    auto const existing = std::find_if(
                        game_history_.begin(), game_history_.end(),
                        [&](auto const& candidate) { return candidate.id == game.id; });
                    if (existing == game_history_.end())
                    {
                        game_history_.push_back(std::move(game));
                    }
                }
                next_history_before_millis_ = page.next_before_millis;
                history_request_pending_ = false;
                pending_history_request_id_.clear();
                PopulateGameHistory();
                return;
            }
            if (type == L"game_exported")
            {
                auto const request_id = String(event, L"request_id");
                if (request_id != pending_export_request_id_) return;
                auto const game_export = Object(event, L"game_export");
                auto const provider = String(game_export, L"provider");
                auto const game_id = String(game_export, L"game_id");
                auto const filename = String(game_export, L"suggested_filename");
                auto const pgn = String(game_export, L"pgn");
                auto const expected_game_id = pending_export_game_id_;
                auto const filename_text = std::wstring(filename);
                auto const pgn_utf8 = winrt::to_string(pgn);
                auto const expected_provider = selected_provider_ && *selected_provider_ < providers_.size()
                    ? providers_[*selected_provider_].id : hstring{};
                pending_export_request_id_.clear();
                pending_export_game_id_.clear();
                ExportPgnButton().IsEnabled(true);
                ExportPgnButton().Content(box_value(L"Export annotated PGN…"));
                if (provider != expected_provider || game_id != expected_game_id
                    || filename.empty() || filename.size() > 128
                    || !filename_text.ends_with(L".pgn")
                    || filename_text.find(L'/') != std::wstring::npos
                    || filename_text.find(L'\\') != std::wstring::npos
                    || pgn_utf8.empty() || pgn_utf8.size() > 8ull * 1024ull * 1024ull
                    || pgn_utf8.find('\0') != std::string::npos)
                {
                    ShowMessage(L"LibChess returned an invalid game export.");
                    return;
                }
                SavePgnAsync(filename, pgn);
                return;
            }
            if (type == L"game_review_loaded")
            {
                auto review = ::LibChess::Windows::Wire::ParseGameReview(
                    Object(event, L"review"));
                if (!review_game_id_.empty() && review.game_id == review_game_id_)
                {
                    game_review_ = std::move(review);
                    review_board_ = ::LibChess::Windows::Wire::ParseBoardState(
                        Object(event, L"board"));
                    review_ply_ = review_board_->ply;
                    review_request_pending_ = false;
                    pending_review_request_id_.clear();
                    PopulateReview();
                    RenderReviewBoard();
                }
                return;
            }
            if (type == L"game_review_position_updated")
            {
                auto const game_id = String(event, L"game_id");
                if (game_review_ && game_id == game_review_->game_id)
                {
                    review_board_ = ::LibChess::Windows::Wire::ParseBoardState(
                        Object(event, L"board"));
                    review_ply_ = static_cast<std::uint32_t>(
                        event.GetNamedNumber(L"ply", review_board_->ply));
                    pending_review_position_request_id_.clear();
                    PopulateReview();
                    RenderReviewBoard();
                }
                return;
            }
            if (type == L"live_games_changed")
            {
                JsonObject refresh;
                refresh.Insert(L"type", JsonString(L"refresh_live_games"));
                SendCommand(refresh);
                return;
            }
            if (type == L"move_predicted")
            {
                auto const request_id = String(event, L"request_id");
                auto const game_id = String(event, L"game_id");
                if (live_game_ && game_id == live_game_->id
                    && request_id == pending_move_request_id_)
                {
                    if (!move_rollback_board_)
                    {
                        move_rollback_board_ = live_game_->board;
                        move_rollback_white_time_millis_ = live_game_->white_time_millis;
                        move_rollback_black_time_millis_ = live_game_->black_time_millis;
                        move_rollback_received_at_ = live_game_received_at_;
                    }
                    auto const now = std::chrono::steady_clock::now();
                    auto const elapsed = static_cast<std::uint64_t>(std::max<std::int64_t>(
                        0,
                        std::chrono::duration_cast<std::chrono::milliseconds>(
                            now - live_game_received_at_).count()));
                    if (live_game_->status == L"started" && live_game_->has_clock)
                    {
                        auto& active_time = live_game_->board.turn == L"white"
                            ? live_game_->white_time_millis : live_game_->black_time_millis;
                        if (active_time)
                        {
                            *active_time = *active_time > elapsed ? *active_time - elapsed : 0;
                        }
                    }
                    live_game_received_at_ = now;
                    auto predicted = *live_game_;
                    predicted.board = ::LibChess::Windows::Wire::ParseBoardState(
                        Object(event, L"board"));
                    PreparePieceAnimations(live_game_, predicted);
                    live_game_->board = std::move(predicted.board);
                    live_games_.insert_or_assign(std::wstring(live_game_->id), *live_game_);
                    live_game_received_times_.insert_or_assign(
                        std::wstring(live_game_->id), live_game_received_at_);
                    selected_square_.clear();
                    selected_drop_.clear();
                    UpdateGameInspector();
                    RenderBoard();
                }
                return;
            }
            if (type == L"move_submitted")
            {
                auto const request_id = String(event, L"request_id");
                if (request_id == pending_move_request_id_)
                {
                    pending_move_request_id_.clear();
                    UpdateGameInspector();
                }
                return;
            }
            if (type == L"game_action_completed")
            {
                auto const request_id = String(event, L"request_id");
                if (request_id == pending_game_action_request_id_)
                {
                    pending_game_action_request_id_.clear();
                    UpdateGameInspector();
                }
                return;
            }
            if (type == L"live_game_stream_ended")
            {
                auto const game_id = String(event, L"game_id");
                auto const request_id = String(event, L"request_id");
                auto const latest = live_latest_start_request_by_game_.find(std::wstring(game_id));
                if (latest == live_latest_start_request_by_game_.end()
                    || latest->second != request_id)
                {
                    live_start_requests_.erase(std::wstring(request_id));
                    return;
                }
                live_start_requests_.erase(std::wstring(request_id));
                live_latest_start_request_by_game_.erase(latest);
                live_stream_states_.insert_or_assign(std::wstring(game_id), false);
                if (game_id == current_game_id_
                    && live_games_.find(std::wstring(game_id)) == live_games_.end())
                {
                    current_game_id_.clear();
                    live_game_.reset();
                    clock_timer_.Stop();
                    GameLoadingPane().Visibility(Visibility::Collapsed);
                    GamePane().Visibility(Visibility::Collapsed);
                    NewGamePane().Visibility(Visibility::Visible);
                    MainNavigation().SelectedItem(nullptr);
                    RefreshLiveGameNavigation();
                    ShowMessage(L"Live updates ended before the game opened. Select it to retry.");
                }
                else if (live_game_ && game_id == live_game_->id)
                {
                    live_stream_connected_ = false;
                    UpdateGameInspector();
                }
                RefreshLiveGameNavigation();
                return;
            }
            if (type == L"error")
            {
                CreateGameButton().IsEnabled(true);
                CreateGameProgress().Visibility(Visibility::Collapsed);
                auto const request_id = String(event, L"request_id");
                if (request_id == pending_board_presentation_request_id_)
                {
                    AppearanceProgress().Visibility(Visibility::Collapsed);
                }
                if (request_id == pending_customization_request_id_)
                {
                    pending_customization_request_id_.clear();
                    customization_edit_pending_ = false;
                    AppearanceInfoBar().Severity(InfoBarSeverity::Error);
                    AppearanceInfoBar().Message(String(Object(event, L"error"), L"message"));
                    AppearanceInfoBar().IsOpen(true);
                }
                if (request_id == pending_history_request_id_)
                {
                    history_request_pending_ = false;
                    pending_history_request_id_.clear();
                    PopulateGameHistory();
                }
                if (request_id == pending_review_request_id_)
                {
                    review_request_pending_ = false;
                    pending_review_request_id_.clear();
                    ReviewTitle().Text(L"Review unavailable");
                }
                if (request_id == pending_review_position_request_id_)
                {
                    pending_review_position_request_id_.clear();
                }
                if (request_id == pending_export_request_id_)
                {
                    pending_export_request_id_.clear();
                    pending_export_game_id_.clear();
                    ExportPgnButton().IsEnabled(true);
                    ExportPgnButton().Content(box_value(L"Export annotated PGN…"));
                }
                if (auto const live_request = live_start_requests_.find(std::wstring(request_id));
                    live_request != live_start_requests_.end())
                {
                    auto const game_id = live_request->second;
                    auto const latest = live_latest_start_request_by_game_.find(
                        std::wstring(game_id));
                    if (latest == live_latest_start_request_by_game_.end()
                        || latest->second != request_id)
                    {
                        live_start_requests_.erase(live_request);
                    }
                    else
                    {
                        live_stream_states_.insert_or_assign(std::wstring(game_id), false);
                        live_start_requests_.erase(live_request);
                        live_latest_start_request_by_game_.erase(latest);
                        if (game_id == current_game_id_)
                        {
                            live_stream_connected_ = false;
                            UpdateGameInspector();
                            if (live_games_.find(std::wstring(game_id)) == live_games_.end())
                            {
                                current_game_id_.clear();
                                live_game_.reset();
                                clock_timer_.Stop();
                                GameLoadingPane().Visibility(Visibility::Collapsed);
                                GamePane().Visibility(Visibility::Collapsed);
                                NewGamePane().Visibility(Visibility::Visible);
                                MainNavigation().SelectedItem(nullptr);
                                RefreshLiveGameNavigation();
                            }
                        }
                    }
                }
                if (!request_id.empty() && request_id == pending_move_request_id_)
                {
                    pending_move_request_id_.clear();
                    if (live_game_ && move_rollback_board_)
                    {
                        live_game_->board = std::move(*move_rollback_board_);
                        live_game_->white_time_millis = move_rollback_white_time_millis_;
                        live_game_->black_time_millis = move_rollback_black_time_millis_;
                        live_game_received_at_ = move_rollback_received_at_;
                        live_games_.insert_or_assign(std::wstring(live_game_->id), *live_game_);
                        live_game_received_times_.insert_or_assign(
                            std::wstring(live_game_->id), live_game_received_at_);
                        move_rollback_board_.reset();
                        move_rollback_white_time_millis_.reset();
                        move_rollback_black_time_millis_.reset();
                        selected_square_.clear();
                        selected_drop_.clear();
                        UpdateGameInspector();
                        RenderBoard();
                    }
                }
                if (!request_id.empty() && request_id == pending_game_action_request_id_)
                {
                    pending_game_action_request_id_.clear();
                    UpdateGameInspector();
                }
                auto const error = Object(event, L"error");
                auto const error_kind = String(error, L"kind");
                auto const error_message = String(error, L"message");
                ::LibChess::Windows::DiagnosticLog::Write(
                    L"core",
                    L"Request failed [" + error_kind + L"]: " + error_message);
                if (connecting_with_saved_credential_ &&
                    error_kind == L"authentication" &&
                    selected_provider_ && *selected_provider_ < providers_.size())
                {
                    ::LibChess::Windows::CredentialStore::Remove(
                        providers_[*selected_provider_].id);
                }
                connecting_with_saved_credential_ = false;
                UpdateBackendAction();
                ShowMessage(error_message);
                return;
            }
        }
        catch (winrt::hresult_error const& error)
        {
            static_cast<void>(error);
            ShowMessage(L"LibChess received data it couldn't use. Please try again.");
        }
        catch (std::exception const& error)
        {
            static_cast<void>(error);
            ShowMessage(L"Something went wrong while updating the app. Please try again.");
        }
    }

    hstring MainWindow::SendCommand(Windows::Data::Json::JsonObject const& command)
    {
        if (!native_client_)
        {
            throw std::runtime_error("LibChess is not available");
        }
        command.Insert(L"version", JsonNumber(1));
        auto const request_id = L"windows-" + winrt::to_hstring(next_request_id_++);
        command.Insert(L"request_id", JsonString(request_id));
        native_client_->Send(winrt::to_string(command.Stringify()));
        return request_id;
    }

    void MainWindow::SetProviders(std::vector<::LibChess::Windows::Wire::Provider> providers)
    {
        providers_ = std::move(providers);
        BackendCards().Children().Clear();
        BackendCards().ColumnDefinitions().Clear();
        BackendCards().RowDefinitions().Clear();
        BackendLoading().Visibility(Visibility::Collapsed);

        for (int column_index = 0; column_index < 2; ++column_index)
        {
            ColumnDefinition column;
            column.Width(GridLength{ 1, GridUnitType::Star });
            BackendCards().ColumnDefinitions().Append(column);
        }

        auto const card_style = Application::Current().Resources()
            .Lookup(box_value(L"LauncherCardButtonStyle"))
            .as<Style>();

        for (std::size_t index = 0; index < providers_.size(); ++index)
        {
            if (index % 2 == 0)
            {
                RowDefinition row;
                row.Height(GridLengthHelper::Auto());
                BackendCards().RowDefinitions().Append(row);
            }

            auto const& provider = providers_[index];
            Button button;
            button.Style(card_style);
            button.Tag(box_value(static_cast<std::uint32_t>(index)));

            Grid content;
            ColumnDefinition icon_column;
            icon_column.Width(GridLengthHelper::Auto());
            content.ColumnDefinitions().Append(icon_column);
            ColumnDefinition text_column;
            text_column.Width(GridLength{ 1, GridUnitType::Star });
            content.ColumnDefinitions().Append(text_column);
            ColumnDefinition chevron_column;
            chevron_column.Width(GridLengthHelper::Auto());
            content.ColumnDefinitions().Append(chevron_column);
            RowDefinition title_row;
            title_row.Height(GridLengthHelper::Auto());
            content.RowDefinitions().Append(title_row);
            RowDefinition subtitle_row;
            subtitle_row.Height(GridLengthHelper::Auto());
            content.RowDefinitions().Append(subtitle_row);

            FontIcon icon;
            icon.FontFamily(Media::FontFamily(L"Segoe Fluent Icons"));
            icon.FontSize(28);
            icon.Glyph(provider.icon == L"processor" ? L"\xE950" : L"\xE909");
            icon.Margin(Thickness{ 0, 2, 18, 0 });
            content.Children().Append(icon);

            TextBlock title;
            title.Text(provider.display_name);
            title.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
            title.FontSize(16);
            Grid::SetColumn(title, 1);
            content.Children().Append(title);

            TextBlock subtitle;
            subtitle.Text(provider.available ? provider.subtitle : L"Unavailable");
            subtitle.Margin(Thickness{ 0, 5, 12, 0 });
            subtitle.Opacity(0.72);
            subtitle.TextWrapping(TextWrapping::Wrap);
            Grid::SetColumn(subtitle, 1);
            Grid::SetRow(subtitle, 1);
            content.Children().Append(subtitle);

            FontIcon chevron;
            chevron.FontFamily(Media::FontFamily(L"Segoe Fluent Icons"));
            chevron.FontSize(12);
            chevron.Glyph(L"\xE76C");
            chevron.Opacity(provider.available ? 0.72 : 0.36);
            chevron.VerticalAlignment(VerticalAlignment::Center);
            Grid::SetColumn(chevron, 2);
            Grid::SetRowSpan(chevron, 2);
            content.Children().Append(chevron);

            button.Content(content);
            Grid::SetColumn(button, static_cast<std::int32_t>(index % 2));
            Grid::SetRow(button, static_cast<std::int32_t>(index / 2));
            button.Click([this](auto const& sender, auto const&)
            {
                auto const index = unbox_value<std::uint32_t>(sender.as<Button>().Tag());
                auto const select = index < providers_.size() && providers_[index].available;
                FocusProvider(index, select);
            });
            BackendCards().Children().Append(button);
        }

        if (!providers_.empty())
        {
            FocusProvider(0, false);
        }
    }

    void MainWindow::FocusProvider(std::size_t index, bool select)
    {
        if (index >= providers_.size())
        {
            return;
        }
        selected_provider_ = index;
        auto const& provider = providers_[index];
        BackendName().Text(provider.display_name);
        BackendSubtitle().Text(provider.subtitle);
        BackendDescription().Text(provider.available
            ? provider.description
            : provider.unavailable_reason);
        BackendIcon().Glyph(provider.icon == L"processor" ? L"\xE950" : L"\xE909");
        LauncherInfoBar().IsOpen(!provider.available);
        LauncherInfoBar().Severity(InfoBarSeverity::Warning);
        LauncherInfoBar().Message(provider.unavailable_reason);

        auto const oauth = provider.connection_type == L"oauth_pkce";
        BackendActionButton().Visibility(oauth ? Visibility::Visible : Visibility::Collapsed);
        UpdateBackendAction();

        if (select)
        {
            JsonObject command;
            command.Insert(L"type", JsonString(L"select_backend"));
            command.Insert(L"backend", JsonString(provider.id));
            BackendProgress().Visibility(oauth ? Visibility::Collapsed : Visibility::Visible);
            try
            {
                SendCommand(command);
            }
            catch (std::exception const& error)
            {
                BackendProgress().Visibility(Visibility::Collapsed);
                ShowMessage(winrt::to_hstring(error.what()));
            }
        }
    }

    void MainWindow::BackendActionButton_Click(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        if (!selected_provider_ || *selected_provider_ >= providers_.size())
        {
            return;
        }
        auto const& provider = providers_[*selected_provider_];
        if (!provider.available || provider.connection_type != L"oauth_pkce")
        {
            return;
        }
        try
        {
            if (::LibChess::Windows::CredentialStore::Contains(provider.id))
            {
                ConnectUsingSavedCredential();
            }
            else
            {
                BeginOAuth();
            }
        }
        catch (std::exception const& error)
        {
            ShowMessage(winrt::to_hstring(error.what()));
            UpdateBackendAction();
        }
    }

    void MainWindow::BeginOAuth()
    {
        if (!selected_provider_ || *selected_provider_ >= providers_.size())
        {
            return;
        }
        auto const& provider = providers_[*selected_provider_];
        if (!protocol_activation_available_)
        {
            ShowMessage(L"Windows couldn't enable online sign-in for LibChess.");
            return;
        }

        LauncherInfoBar().IsOpen(false);
        BackendProgress().Visibility(Visibility::Visible);
        BackendActionButton().IsEnabled(false);
        JsonObject command;
        command.Insert(L"type", JsonString(L"begin_oauth"));
        command.Insert(L"provider", JsonString(provider.id));
        command.Insert(L"client_id", JsonString(OAuthClientId));
        command.Insert(L"redirect_uri", JsonString(OAuthRedirectUri));
        ::LibChess::Windows::DiagnosticLog::Write(
            L"wire",
            L"Sending begin_oauth with the Windows client and callback identity.");
        try
        {
            SendCommand(command);
        }
        catch (...)
        {
            ::LibChess::Windows::DiagnosticLog::Write(
                L"oauth",
                L"The begin_oauth command could not be sent to Rust.");
            BackendProgress().Visibility(Visibility::Collapsed);
            UpdateBackendAction();
            throw;
        }
    }

    void MainWindow::ConnectUsingSavedCredential()
    {
        if (!selected_provider_ || *selected_provider_ >= providers_.size())
        {
            return;
        }
        auto const& provider = providers_[*selected_provider_];
        std::optional<std::string> access_token;
        try
        {
            access_token = ::LibChess::Windows::CredentialStore::Load(provider.id);
        }
        catch (...)
        {
            ::LibChess::Windows::CredentialStore::Remove(provider.id);
            UpdateBackendAction();
            throw;
        }
        if (!access_token)
        {
            UpdateBackendAction();
            BeginOAuth();
            return;
        }

        BackendProgress().Visibility(Visibility::Visible);
        BackendActionButton().IsEnabled(false);
        connecting_with_saved_credential_ = true;
        try
        {
            JsonObject command;
            command.Insert(L"type", JsonString(L"connect"));
            command.Insert(L"provider", JsonString(provider.id));
            command.Insert(L"access_token", JsonString(winrt::to_hstring(*access_token)));
            SendCommand(command);
            SecureZeroMemory(access_token->data(), access_token->size());
        }
        catch (...)
        {
            SecureZeroMemory(access_token->data(), access_token->size());
            connecting_with_saved_credential_ = false;
            BackendProgress().Visibility(Visibility::Collapsed);
            UpdateBackendAction();
            throw;
        }
    }

    winrt::fire_and_forget MainWindow::LaunchAuthorizationAsync(hstring authorization_url)
    {
        auto lifetime = get_strong();
        try
        {
            auto const launched = co_await Windows::System::Launcher::LaunchUriAsync(
                Windows::Foundation::Uri(authorization_url));
            if (launched)
            {
                co_return;
            }
        }
        catch (...)
        {
        }

        try
        {
            JsonObject cancel;
            cancel.Insert(L"type", JsonString(L"cancel_oauth"));
            SendCommand(cancel);
        }
        catch (...)
        {
        }
        oauth_authorizing_ = false;
        BackendProgress().Visibility(Visibility::Collapsed);
        UpdateBackendAction();
        ::LibChess::Windows::DiagnosticLog::Write(
            L"oauth",
            L"The system browser did not accept the authorization URI.");
        ShowMessage(L"Windows couldn't open the sign-in page.");
    }

    bool MainWindow::AuthorizationUrlIsValid(hstring const& authorization_url) const
    {
        if (!selected_provider_ || *selected_provider_ >= providers_.size() ||
            authorization_url.empty() || authorization_url.size() > 8'192)
        {
            return false;
        }
        auto const& origin = providers_[*selected_provider_].authorization_origin;
        if (origin.empty())
        {
            return false;
        }
        try
        {
            Windows::Foundation::Uri const authorization(authorization_url);
            Windows::Foundation::Uri const expected(origin);
            return !authorization.Suspicious() &&
                authorization.UserName().empty() && authorization.Password().empty() &&
                EqualIgnoringCase(authorization.SchemeName(), L"https") &&
                EqualIgnoringCase(authorization.SchemeName(), expected.SchemeName()) &&
                EqualIgnoringCase(authorization.Host(), expected.Host()) &&
                authorization.Port() == expected.Port();
        }
        catch (...)
        {
            return false;
        }
    }

    bool MainWindow::CallbackUrlIsValid(hstring const& callback_url)
    {
        if (callback_url.empty() || callback_url.size() > 8'192)
        {
            ::LibChess::Windows::DiagnosticLog::Write(
                L"oauth",
                L"Callback rejected before parsing because its length was invalid.");
            return false;
        }
        try
        {
            Windows::Foundation::Uri const callback(callback_url);
            Windows::Foundation::Uri const expected(OAuthRedirectUri);
            auto const details =
                L"Callback received: scheme=" + std::wstring(callback.SchemeName()) +
                L", host=" + std::wstring(callback.Host()) +
                L", port=" + std::to_wstring(callback.Port()) +
                L", path=" + std::wstring(callback.Path()) +
                L", suspicious=" + (callback.Suspicious() ? L"true" : L"false") +
                L", user_info=" +
                    ((!callback.UserName().empty() || !callback.Password().empty())
                        ? L"present"
                        : L"absent") +
                L", fragment=" + (callback.Fragment().empty() ? L"absent" : L"present") +
                L". Query values omitted.";
            ::LibChess::Windows::DiagnosticLog::Write(L"oauth", winrt::hstring(details));

            if (callback.Suspicious())
            {
                ::LibChess::Windows::DiagnosticLog::Write(
                    L"oauth",
                    L"Callback rejected because Windows marked the URI as suspicious.");
                return false;
            }
            if (!callback.UserName().empty() || !callback.Password().empty())
            {
                ::LibChess::Windows::DiagnosticLog::Write(
                    L"oauth",
                    L"Callback rejected because user information was present.");
                return false;
            }
            if (!callback.Fragment().empty())
            {
                ::LibChess::Windows::DiagnosticLog::Write(
                    L"oauth",
                    L"Callback rejected because a fragment was present.");
                return false;
            }
            if (!EqualIgnoringCase(callback.SchemeName(), expected.SchemeName()))
            {
                ::LibChess::Windows::DiagnosticLog::Write(
                    L"oauth",
                    L"Callback rejected because the scheme did not match LibChess.");
                return false;
            }
            if (!EqualIgnoringCase(callback.Host(), expected.Host()))
            {
                ::LibChess::Windows::DiagnosticLog::Write(
                    L"oauth",
                    L"Callback rejected because the host did not match LibChess.");
                return false;
            }
            if (callback.Port() != expected.Port())
            {
                ::LibChess::Windows::DiagnosticLog::Write(
                    L"oauth",
                    L"Callback rejected because the port did not match LibChess.");
                return false;
            }
            if (callback.Path() != expected.Path())
            {
                ::LibChess::Windows::DiagnosticLog::Write(
                    L"oauth",
                    L"Callback rejected because the path did not match LibChess.");
                return false;
            }

            ::LibChess::Windows::DiagnosticLog::Write(
                L"oauth",
                L"Callback matched the registered Windows redirect; Rust will validate it again with the PKCE state.");
            return true;
        }
        catch (winrt::hresult_error const& error)
        {
            ::LibChess::Windows::DiagnosticLog::Write(
                L"oauth",
                L"Callback URI parsing failed: " + error.message());
            return false;
        }
    }

    void MainWindow::HandleProtocolActivation(hstring const& callback_url)
    {
        auto const callback_is_valid = CallbackUrlIsValid(callback_url);
        if (!oauth_authorizing_)
        {
            ::LibChess::Windows::DiagnosticLog::Write(
                L"oauth",
                L"Callback ignored because there is no pending authorization in this process.");
            return;
        }
        if (!callback_is_valid)
        {
            ShowMessage(L"That sign-in response wasn't intended for LibChess.");
            return;
        }

        try
        {
            JsonObject command;
            command.Insert(L"type", JsonString(L"complete_oauth"));
            command.Insert(L"callback_url", JsonString(callback_url));
            ::LibChess::Windows::DiagnosticLog::Write(
                L"wire",
                L"Sending complete_oauth to Rust; callback query omitted.");
            SendCommand(command);
            ::LibChess::Windows::DiagnosticLog::Write(
                L"oauth",
                L"Callback forwarded to Rust for exact redirect and state validation.");
            oauth_authorizing_ = false;
            BackendProgress().Visibility(Visibility::Visible);
        }
        catch (std::exception const& error)
        {
            ShowMessage(winrt::to_hstring(error.what()));
            BackendProgress().Visibility(Visibility::Collapsed);
            UpdateBackendAction();
        }
    }

    void MainWindow::SetProtocolActivationAvailable(bool available)
    {
        protocol_activation_available_ = available;
        UpdateBackendAction();
    }

    void MainWindow::UpdateBackendAction()
    {
        if (!selected_provider_ || *selected_provider_ >= providers_.size())
        {
            return;
        }
        auto const& provider = providers_[*selected_provider_];
        if (provider.connection_type != L"oauth_pkce")
        {
            return;
        }

        bool saved = false;
        try
        {
            saved = ::LibChess::Windows::CredentialStore::Contains(provider.id);
        }
        catch (...)
        {
        }
        BackendActionButton().Content(box_value(
            (saved ? L"Continue with " : L"Sign in with ") + provider.display_name));
        BackendActionButton().IsEnabled(
            provider.available && !oauth_authorizing_ && !connecting_with_saved_credential_ &&
            (saved || protocol_activation_available_));
    }

    void MainWindow::ShowLauncher()
    {
        if (floating_board_window_)
        {
            SaveFloatingBoardFrame();
            floating_board_window_.Close();
        }
        WorkspaceView().Visibility(Visibility::Collapsed);
        LauncherView().Visibility(Visibility::Visible);
        live_game_.reset();
        selected_square_.clear();
    }

    void MainWindow::ShowWorkspace()
    {
        LauncherView().Visibility(Visibility::Collapsed);
        WorkspaceView().Visibility(Visibility::Visible);
        PopulateNewGameOptions();
    }

    void MainWindow::PopulateNewGameOptions()
    {
        OpponentPicker().Items().Clear();
        VariantPicker().Items().Clear();
        ColorPicker().Items().Clear();
        TimeControlPicker().Items().Clear();
        InitialTimePicker().Items().Clear();
        IncrementPicker().Items().Clear();
        CorrespondenceDaysPicker().Items().Clear();
        if (!selected_provider_ || *selected_provider_ >= providers_.size())
        {
            CreateGameButton().IsEnabled(false);
            return;
        }
        auto const& options = providers_[*selected_provider_].bot_game_options;
        if (!options)
        {
            CreateGameButton().IsEnabled(false);
            return;
        }

        for (auto const& opponent : options->opponents)
        {
            AppendComboItem(OpponentPicker(), opponent.display_name, opponent.id);
        }
        for (auto const& variant : options->variants)
        {
            AppendComboItem(VariantPicker(), variant.display_name, variant.id);
        }
        for (auto const& color : options->colors)
        {
            auto label = color;
            if (!label.empty())
            {
                auto text = std::wstring(label);
                text[0] = static_cast<wchar_t>(std::towupper(text[0]));
                label = hstring(text);
            }
            AppendComboItem(ColorPicker(), label, color);
        }
        SelectComboTag(OpponentPicker(), options->default_opponent_id);
        SelectComboTag(VariantPicker(), options->default_variant_id);
        SelectComboTag(ColorPicker(), options->default_color);

        hstring default_mode;
        std::uint32_t default_initial = 0;
        std::uint32_t default_increment = 0;
        std::uint32_t default_days = 0;
        if (!options->default_time_control_json.empty())
        {
            try
            {
                auto const time_control = JsonObject::Parse(options->default_time_control_json);
                default_mode = String(time_control, L"type");
                if (default_mode == L"clock")
                {
                    default_initial = static_cast<std::uint32_t>(
                        time_control.GetNamedNumber(L"initial_seconds"));
                    default_increment = static_cast<std::uint32_t>(
                        time_control.GetNamedNumber(L"increment_seconds"));
                }
                else if (default_mode == L"correspondence")
                {
                    default_days = static_cast<std::uint32_t>(
                        time_control.GetNamedNumber(L"days_per_move"));
                }
            }
            catch (...)
            {
                default_mode.clear();
            }
        }

        populating_time_controls_ = true;
        if (options->clock)
        {
            AppendComboItem(TimeControlPicker(), L"Real time", L"clock");
            for (auto const initial : options->clock->initial_seconds)
            {
                AppendComboItem(
                    InitialTimePicker(),
                    FormatInitialTime(initial),
                    winrt::to_hstring(initial));
            }
            SelectComboTag(InitialTimePicker(), winrt::to_hstring(default_initial));
            PopulateClockIncrementOptions(default_increment);
        }
        if (!options->correspondence_days.empty())
        {
            AppendComboItem(TimeControlPicker(), L"Correspondence", L"correspondence");
            for (auto const days : options->correspondence_days)
            {
                AppendComboItem(
                    CorrespondenceDaysPicker(),
                    FormatDays(days) + L" per move",
                    winrt::to_hstring(days));
            }
            SelectComboTag(CorrespondenceDaysPicker(), winrt::to_hstring(default_days));
        }
        if (options->unlimited)
        {
            AppendComboItem(TimeControlPicker(), L"Unlimited", L"unlimited");
        }
        SelectComboTag(TimeControlPicker(), default_mode);
        populating_time_controls_ = false;
        UpdateTimeControlEditor();
    }

    void MainWindow::PopulateClockIncrementOptions(std::uint32_t preferred_increment)
    {
        IncrementPicker().Items().Clear();
        if (!selected_provider_ || *selected_provider_ >= providers_.size())
        {
            return;
        }
        auto const& options = providers_[*selected_provider_].bot_game_options;
        if (!options || !options->clock)
        {
            return;
        }
        auto const initial = ComboNumber(InitialTimePicker());
        for (auto const increment : options->clock->increment_seconds)
        {
            if (options->clock->Supports(initial, increment))
            {
                AppendComboItem(
                    IncrementPicker(),
                    FormatIncrement(increment),
                    winrt::to_hstring(increment));
            }
        }
        SelectComboTag(IncrementPicker(), winrt::to_hstring(preferred_increment));
    }

    void MainWindow::UpdateTimeControlEditor()
    {
        auto const mode = ComboTag(TimeControlPicker());
        ClockOptionsPanel().Visibility(mode == L"clock" ? Visibility::Visible : Visibility::Collapsed);
        CorrespondenceOptionsPanel().Visibility(
            mode == L"correspondence" ? Visibility::Visible : Visibility::Collapsed);
        UnlimitedTimeDescription().Visibility(
            mode == L"unlimited" ? Visibility::Visible : Visibility::Collapsed);

        if (mode == L"clock")
        {
            TimeControlSummary().Text(L"A clock runs during each player's turn.");
        }
        else if (mode == L"correspondence")
        {
            TimeControlSummary().Text(L"Each move can be played over several days.");
        }
        else if (mode == L"unlimited")
        {
            TimeControlSummary().Text(L"No clock and no move deadline.");
        }
        else
        {
            TimeControlSummary().Text(L"This service did not provide a time control.");
        }

        CreateGameButton().IsEnabled(
            OpponentPicker().Items().Size() > 0
            && VariantPicker().Items().Size() > 0
            && !mode.empty());
    }

    void MainWindow::TimeControlPicker_SelectionChanged(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&)
    {
        if (!populating_time_controls_)
        {
            UpdateTimeControlEditor();
        }
    }

    void MainWindow::InitialTimePicker_SelectionChanged(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&)
    {
        if (populating_time_controls_)
        {
            return;
        }
        auto const previous_increment = ComboNumber(IncrementPicker());
        populating_time_controls_ = true;
        PopulateClockIncrementOptions(previous_increment);
        populating_time_controls_ = false;
        UpdateTimeControlEditor();
    }

    void MainWindow::VariantPicker_SelectionChanged(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&)
    {
        auto const selected = VariantPicker().SelectedIndex();
        bool supports_position = false;
        if (selected_provider_ && selected >= 0)
        {
            auto const& options = providers_[*selected_provider_].bot_game_options;
            if (options && static_cast<std::size_t>(selected) < options->variants.size())
            {
                supports_position = options->variants[static_cast<std::size_t>(selected)]
                    .supports_custom_position;
            }
        }
        PositionPanel().Visibility(supports_position ? Visibility::Visible : Visibility::Collapsed);
        PositionDivider().Visibility(supports_position ? Visibility::Visible : Visibility::Collapsed);
    }

    hstring MainWindow::ComboTag(ComboBox const& picker)
    {
        auto const item = picker.SelectedItem().try_as<ComboBoxItem>();
        return item ? unbox_value_or<hstring>(item.Tag(), {}) : hstring{};
    }

    std::uint32_t MainWindow::ComboNumber(ComboBox const& picker)
    {
        auto const value = ComboTag(picker);
        if (value.empty())
        {
            return 0;
        }
        wchar_t* end = nullptr;
        auto const number = std::wcstoull(value.c_str(), &end, 10);
        if (end == value.c_str() || *end != L'\0' || number > UINT32_MAX)
        {
            return 0;
        }
        return static_cast<std::uint32_t>(number);
    }

    JsonObject MainWindow::SelectedTimeControl()
    {
        if (!selected_provider_ || *selected_provider_ >= providers_.size())
        {
            return nullptr;
        }
        auto const& options = providers_[*selected_provider_].bot_game_options;
        if (!options)
        {
            return nullptr;
        }

        auto const mode = ComboTag(TimeControlPicker());
        JsonObject time_control;
        if (mode == L"clock" && options->clock)
        {
            auto const initial = ComboNumber(InitialTimePicker());
            auto const increment = ComboNumber(IncrementPicker());
            if (!options->clock->Supports(initial, increment))
            {
                return nullptr;
            }
            time_control.Insert(L"type", JsonString(L"clock"));
            time_control.Insert(L"initial_seconds", JsonNumber(initial));
            time_control.Insert(L"increment_seconds", JsonNumber(increment));
            return time_control;
        }
        if (mode == L"correspondence")
        {
            auto const days = ComboNumber(CorrespondenceDaysPicker());
            if (std::find(
                    options->correspondence_days.begin(),
                    options->correspondence_days.end(),
                    days) == options->correspondence_days.end())
            {
                return nullptr;
            }
            time_control.Insert(L"type", JsonString(L"correspondence"));
            time_control.Insert(L"days_per_move", JsonNumber(days));
            return time_control;
        }
        if (mode == L"unlimited" && options->unlimited)
        {
            time_control.Insert(L"type", JsonString(L"unlimited"));
            return time_control;
        }
        return nullptr;
    }

    void MainWindow::CreateGame_Click(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        if (!selected_provider_)
        {
            return;
        }
        auto const& options = providers_[*selected_provider_].bot_game_options;
        if (!options)
        {
            return;
        }

        try
        {
            auto const time_control = SelectedTimeControl();
            if (!time_control)
            {
                ShowMessage(L"Choose a valid time control before creating the game.");
                return;
            }
            JsonObject command;
            command.Insert(L"type", JsonString(L"create_bot_game"));
            command.Insert(L"opponent_id", JsonString(ComboTag(OpponentPicker())));
            command.Insert(L"variant_id", JsonString(ComboTag(VariantPicker())));
            command.Insert(L"color", JsonString(ComboTag(ColorPicker())));
            command.Insert(L"time_control", time_control);
            if (options->has_reply_delay)
            {
                command.Insert(L"reply_delay_millis", JsonNumber(options->default_reply_delay_millis));
            }
            auto const fen = PositionFen().Text();
            if (!fen.empty())
            {
                command.Insert(L"initial_fen", JsonString(fen));
            }
            CreateGameButton().IsEnabled(false);
            CreateGameProgress().Visibility(Visibility::Visible);
            WorkspaceInfoBar().IsOpen(false);
            SendCommand(command);
        }
        catch (winrt::hresult_error const& error)
        {
            static_cast<void>(error);
            CreateGameButton().IsEnabled(true);
            CreateGameProgress().Visibility(Visibility::Collapsed);
            ShowMessage(L"The game couldn't be created. Check your choices and try again.");
        }
        catch (std::exception const& error)
        {
            static_cast<void>(error);
            CreateGameButton().IsEnabled(true);
            CreateGameProgress().Visibility(Visibility::Collapsed);
            ShowMessage(L"The game couldn't be created. Check your choices and try again.");
        }
    }

    void MainWindow::StartCreatedGame(Windows::Data::Json::JsonObject const& game)
    {
        if (!game)
        {
            ShowMessage(L"The game couldn't be opened. Please try again.");
            return;
        }
        StartLiveGame(String(game, L"id"), String(game, L"player_color"));
    }

    void MainWindow::SetLiveGames(
        std::vector<::LibChess::Windows::Wire::LiveGameSummary> games)
    {
        live_game_summaries_ = std::move(games);
        RefreshLiveGameNavigation();
        if (!current_game_id_.empty() || live_game_summaries_.empty())
        {
            return;
        }
        auto selected = std::find_if(
            live_game_summaries_.begin(), live_game_summaries_.end(),
            [](auto const& game) { return game.is_my_turn; });
        if (selected == live_game_summaries_.end())
        {
            selected = live_game_summaries_.begin();
        }
        StartLiveGame(selected->id, selected->player_color);
    }

    void MainWindow::ClearLiveGames()
    {
        if (floating_board_window_)
        {
            SaveFloatingBoardFrame();
            floating_board_window_.Close();
        }
        clock_timer_.Stop();
        live_game_.reset();
        live_game_summaries_.clear();
        live_games_.clear();
        live_stream_states_.clear();
        live_start_requests_.clear();
        live_latest_start_request_by_game_.clear();
        live_game_received_times_.clear();
        live_game_claim_received_times_.clear();
        current_game_id_.clear();
        selected_square_.clear();
        selected_drop_.clear();
        pending_move_request_id_.clear();
        pending_game_action_request_id_.clear();
        pending_export_request_id_.clear();
        pending_export_game_id_.clear();
        move_rollback_board_.reset();
        move_rollback_white_time_millis_.reset();
        move_rollback_black_time_millis_.reset();
        game_history_.clear();
        next_history_before_millis_.reset();
        game_review_.reset();
        review_board_.reset();
        review_game_id_.clear();
        pending_history_request_id_.clear();
        pending_review_request_id_.clear();
        pending_review_position_request_id_.clear();
        history_request_pending_ = false;
        review_request_pending_ = false;
        RefreshLiveGameNavigation();
        PopulateGameHistory();
    }

    void MainWindow::RefreshLiveGameNavigation()
    {
        auto const menu = MainNavigation().MenuItems();
        for (auto index = static_cast<std::int32_t>(menu.Size()) - 1; index >= 0; --index)
        {
            auto const item = menu.GetAt(static_cast<std::uint32_t>(index))
                .try_as<NavigationViewItem>();
            auto const tag = item ? unbox_value_or<hstring>(item.Tag(), {}) : hstring{};
            auto const value = std::wstring(tag);
            if (value.size() > 5 && value.compare(0, 5, L"game:") == 0)
            {
                menu.RemoveAt(static_cast<std::uint32_t>(index));
            }
        }
        std::uint32_t insert_index = 2;
        auto append = [&](hstring const& id, hstring const& name, hstring const& detail, bool my_turn)
        {
            NavigationViewItem item;
            item.Tag(box_value(L"game:" + id));
            item.Icon(SymbolIcon(Symbol::Play));
            item.Margin(Thickness{ 12, 0, 0, 0 });
            if (my_turn)
            {
                item.InfoBadge(InfoBadge());
            }
            StackPanel content;
            content.Spacing(1);
            TextBlock title;
            title.Text(name);
            title.FontWeight(my_turn
                ? Windows::UI::Text::FontWeights::SemiBold()
                : Windows::UI::Text::FontWeights::Normal());
            title.TextTrimming(TextTrimming::CharacterEllipsis);
            content.Children().Append(title);
            if (!detail.empty())
            {
                TextBlock subtitle;
                subtitle.Text(detail);
                subtitle.Style(Application::Current().Resources()
                    .Lookup(box_value(L"CaptionTextBlockStyle")).as<Style>());
                subtitle.Opacity(0.72);
                subtitle.TextTrimming(TextTrimming::CharacterEllipsis);
                content.Children().Append(subtitle);
            }
            item.Content(content);
            ToolTipService::SetToolTip(item, box_value(my_turn
                ? name + L" · your move" : name));
            menu.InsertAt(insert_index++, item);
        };

        bool current_is_listed = false;
        for (auto const& game : live_game_summaries_)
        {
            current_is_listed = current_is_listed || game.id == current_game_id_;
            auto detail = game.variant_name;
            if (!game.speed.empty())
            {
                detail = detail + L" · " + DisplayLabel(game.speed);
            }
            auto my_turn = game.is_my_turn;
            if (live_game_ && live_game_->id == game.id && live_game_->status == L"started")
            {
                my_turn = live_game_->board.turn == live_game_->player_color;
            }
            append(game.id, game.display_name.empty() ? L"Game" : game.display_name,
                detail, my_turn);
        }
        if (!current_game_id_.empty() && !current_is_listed && live_game_)
        {
            auto const opponent = live_game_->player_color == L"white"
                ? live_game_->black : live_game_->white;
            append(current_game_id_, PlayerDisplayName(opponent), live_game_->variant_name,
                live_game_->status == L"started"
                    && live_game_->board.turn == live_game_->player_color);
        }
        BoardNavigationItem().Content(box_value(
            L"Games (" + winrt::to_hstring(insert_index - 2) + L")"));
        PopulateGamesPage();
        if (!current_game_id_.empty())
        {
            SelectNavigationForGame(current_game_id_);
        }
    }

    void MainWindow::PopulateGamesPage()
    {
        GamesListPanel().Children().Clear();
        auto const card_style = Application::Current().Resources()
            .Lookup(box_value(L"LauncherCardButtonStyle")).as<Style>();
        auto append = [&](hstring const& id, hstring const& name, hstring const& detail, bool my_turn)
        {
            Button button;
            button.Style(card_style);
            button.MinHeight(86);
            button.Tag(box_value(id));
            button.Click({ this, &MainWindow::GameCard_Click });
            Grid content;
            ColumnDefinition text_column;
            text_column.Width(GridLength{ 1, GridUnitType::Star });
            content.ColumnDefinitions().Append(text_column);
            ColumnDefinition status_column;
            status_column.Width(GridLengthHelper::Auto());
            content.ColumnDefinitions().Append(status_column);
            StackPanel text;
            text.Spacing(4);
            TextBlock title;
            title.Text(name);
            title.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
            title.FontSize(16);
            text.Children().Append(title);
            TextBlock subtitle;
            subtitle.Text(detail);
            subtitle.Foreground(CreateBrush(Windows::UI::Colors::Gray()));
            text.Children().Append(subtitle);
            content.Children().Append(text);
            TextBlock status;
            status.Text(my_turn ? L"Your move" : L"Waiting");
            status.VerticalAlignment(VerticalAlignment::Center);
            status.FontWeight(my_turn
                ? Windows::UI::Text::FontWeights::SemiBold()
                : Windows::UI::Text::FontWeights::Normal());
            Grid::SetColumn(status, 1);
            content.Children().Append(status);
            button.Content(content);
            GamesListPanel().Children().Append(button);
        };
        bool current_is_listed = false;
        for (auto const& game : live_game_summaries_)
        {
            current_is_listed = current_is_listed || game.id == current_game_id_;
            auto const detail = game.variant_name + (game.speed.empty()
                ? hstring{} : L" · " + DisplayLabel(game.speed));
            auto my_turn = game.is_my_turn;
            if (live_game_ && live_game_->id == game.id && live_game_->status == L"started")
            {
                my_turn = live_game_->board.turn == live_game_->player_color;
            }
            append(game.id, game.display_name.empty() ? L"Game" : game.display_name,
                detail, my_turn);
        }
        if (!current_game_id_.empty() && !current_is_listed && live_game_)
        {
            auto const opponent = live_game_->player_color == L"white"
                ? live_game_->black : live_game_->white;
            append(current_game_id_, PlayerDisplayName(opponent), live_game_->variant_name,
                live_game_->status == L"started"
                    && live_game_->board.turn == live_game_->player_color);
        }
        GamesEmptyInfo().IsOpen(GamesListPanel().Children().Size() == 0);
    }

    void MainWindow::RefreshGameHistory(bool append)
    {
        if (history_request_pending_ || !selected_provider_
            || *selected_provider_ >= providers_.size()
            || !providers_[*selected_provider_].Supports(L"game_history"))
        {
            return;
        }
        JsonObject command;
        command.Insert(L"type", JsonString(L"refresh_game_history"));
        command.Insert(L"limit", JsonNumber(20));
        if (append && next_history_before_millis_)
        {
            command.Insert(L"before_millis", JsonNumber(
                static_cast<double>(*next_history_before_millis_)));
        }
        history_request_pending_ = true;
        pending_history_request_id_ = SendCommand(command);
        PopulateGameHistory();
    }

    void MainWindow::PopulateGameHistory()
    {
        HistoryProgress().Visibility(
            history_request_pending_ ? Visibility::Visible : Visibility::Collapsed);
        HistoryListPanel().Children().Clear();
        auto const card_style = Application::Current().Resources()
            .Lookup(box_value(L"LauncherCardButtonStyle")).as<Style>();
        for (auto const& game : game_history_)
        {
            Button button;
            button.Style(card_style);
            button.MinHeight(92);
            button.Tag(box_value(game.id));
            button.Click({ this, &MainWindow::HistoryGame_Click });
            Grid content;
            ColumnDefinition details_column;
            details_column.Width(GridLength{ 1, GridUnitType::Star });
            content.ColumnDefinitions().Append(details_column);
            ColumnDefinition result_column;
            result_column.Width(GridLengthHelper::Auto());
            content.ColumnDefinitions().Append(result_column);
            StackPanel details;
            details.Spacing(4);
            TextBlock title;
            auto opponent = game.opponent_title.empty()
                ? game.opponent_name : game.opponent_title + L" " + game.opponent_name;
            if (game.opponent_rating)
            {
                opponent = opponent + L" (" + winrt::to_hstring(*game.opponent_rating) + L")";
            }
            else if (game.opponent_ai_level)
            {
                opponent = opponent + L" · Level "
                    + winrt::to_hstring(*game.opponent_ai_level);
            }
            title.Text(opponent);
            title.FontSize(16);
            title.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
            details.Children().Append(title);
            TextBlock subtitle;
            subtitle.Text(game.variant_name + (game.speed.empty()
                ? hstring{} : L" · " + DisplayLabel(game.speed))
                + (game.rated ? L" · Rated" : L" · Casual"));
            subtitle.Style(Application::Current().Resources()
                .Lookup(box_value(L"CaptionTextBlockStyle")).as<Style>());
            details.Children().Append(subtitle);
            content.Children().Append(details);
            TextBlock result;
            auto result_text = DisplayLabel(game.status);
            if (!game.winner.empty())
            {
                result_text = game.winner == game.player_color ? hstring(L"Won") : hstring(L"Lost");
            }
            else if (game.status == L"draw" || game.status == L"stalemate")
            {
                result_text = L"Draw";
            }
            result.Text(result_text);
            result.VerticalAlignment(VerticalAlignment::Center);
            result.FontWeight(Windows::UI::Text::FontWeights::SemiBold());
            Grid::SetColumn(result, 1);
            content.Children().Append(result);
            button.Content(content);
            HistoryListPanel().Children().Append(button);
        }
        HistoryEmptyInfo().IsOpen(!history_request_pending_ && game_history_.empty());
        LoadMoreHistoryButton().Visibility(next_history_before_millis_
            ? Visibility::Visible : Visibility::Collapsed);
        LoadMoreHistoryButton().IsEnabled(!history_request_pending_);
    }

    void MainWindow::LoadGameReview(hstring const& game_id)
    {
        if (game_id.empty() || review_request_pending_ || !selected_provider_
            || *selected_provider_ >= providers_.size()
            || !providers_[*selected_provider_].Supports(L"game_review"))
        {
            return;
        }
        review_game_id_ = game_id;
        game_review_.reset();
        review_board_.reset();
        review_ply_ = 0;
        review_request_pending_ = true;
        ReviewTitle().Text(L"Loading game review…");
        ReviewSubtitle().Text({});
        ReviewOpening().Text({});
        ReviewEvaluation().Text({});
        ReviewVariation().Text({});
        ReviewJudgment().IsOpen(false);
        ReviewMovesPanel().Children().Clear();
        ReviewBoardGrid().Children().Clear();
        HideWorkspacePanes();
        ReviewPane().Visibility(Visibility::Visible);
        JsonObject command;
        command.Insert(L"type", JsonString(L"load_game_review"));
        command.Insert(L"game_id", JsonString(game_id));
        pending_review_request_id_ = SendCommand(command);
    }

    void MainWindow::ShowReviewPosition(std::uint32_t ply)
    {
        if (!game_review_ || ply > game_review_->moves.size()
            || !pending_review_position_request_id_.empty())
        {
            return;
        }
        JsonObject command;
        command.Insert(L"type", JsonString(L"show_game_review_position"));
        command.Insert(L"game_id", JsonString(game_review_->game_id));
        command.Insert(L"ply", JsonNumber(ply));
        pending_review_position_request_id_ = SendCommand(command);
    }

    void MainWindow::PopulateReview()
    {
        if (!game_review_)
        {
            return;
        }
        auto const history = std::find_if(
            game_history_.begin(), game_history_.end(),
            [&](auto const& game) { return game.id == game_review_->game_id; });
        ReviewTitle().Text(history == game_history_.end()
            ? L"Game review" : L"vs " + history->opponent_name);
        ReviewSubtitle().Text(history == game_history_.end()
            ? DisplayLabel(game_review_->variant_id)
            : history->variant_name + L" · " + DisplayLabel(history->status));
        ReviewOpening().Text(game_review_->opening
            ? game_review_->opening->eco + L" · " + game_review_->opening->name
            : hstring(L"Opening not identified"));
        ReviewMovesPanel().Children().Clear();
        for (auto const& move : game_review_->moves)
        {
            Button button;
            button.Tag(box_value(move.ply));
            button.HorizontalAlignment(HorizontalAlignment::Stretch);
            button.HorizontalContentAlignment(HorizontalAlignment::Left);
            button.Click({ this, &MainWindow::ReviewMove_Click });
            auto const move_number = (move.ply + 1) / 2;
            button.Content(box_value(winrt::to_hstring(move_number)
                + (move.ply % 2 == 1 ? L". " : L"… ") + move.san));
            if (move.ply == review_ply_)
            {
                button.Style(Application::Current().Resources()
                    .Lookup(box_value(L"AccentButtonStyle")).as<Style>());
            }
            ReviewMovesPanel().Children().Append(button);
        }
        OpenAnalysisButton().Visibility(history != game_history_.end()
            && !history->analysis_url.empty() ? Visibility::Visible : Visibility::Collapsed);
        auto const supports_export = selected_provider_ && *selected_provider_ < providers_.size()
            && providers_[*selected_provider_].Supports(L"pgn_export");
        ExportPgnButton().IsEnabled(supports_export && pending_export_request_id_.empty());
        UpdateReviewAnalysis();
    }

    void MainWindow::UpdateReviewAnalysis()
    {
        ReviewJudgment().IsOpen(false);
        ReviewVariation().Text({});
        if (!game_review_ || review_ply_ == 0 || review_ply_ > game_review_->moves.size())
        {
            ReviewEvaluation().Text(L"Start position");
            return;
        }
        auto const& move = game_review_->moves[review_ply_ - 1];
        if (!move.evaluation)
        {
            ReviewEvaluation().Text(L"No stored evaluation");
            return;
        }
        auto const& evaluation = *move.evaluation;
        if (evaluation.mate)
        {
            ReviewEvaluation().Text((*evaluation.mate >= 0 ? L"M" : L"−M")
                + winrt::to_hstring(std::abs(*evaluation.mate)));
        }
        else if (evaluation.centipawns)
        {
            wchar_t value[32]{};
            swprintf_s(value, L"%+.2f", static_cast<double>(*evaluation.centipawns) / 100.0);
            ReviewEvaluation().Text(value);
        }
        else
        {
            ReviewEvaluation().Text(L"Evaluation unavailable");
        }
        if (!evaluation.judgment_kind.empty())
        {
            ReviewJudgment().Title(DisplayLabel(evaluation.judgment_kind));
            ReviewJudgment().Message(evaluation.judgment_comment);
            ReviewJudgment().Severity(evaluation.judgment_kind == L"blunder"
                ? InfoBarSeverity::Error : InfoBarSeverity::Warning);
            ReviewJudgment().IsOpen(true);
        }
        auto variation = evaluation.best_move.empty()
            ? hstring{} : L"Best: " + evaluation.best_move;
        if (!evaluation.variation.empty())
        {
            variation = variation + (variation.empty() ? hstring{} : hstring(L"\n"))
                + L"Line: " + evaluation.variation;
        }
        ReviewVariation().Text(variation);
    }

    void MainWindow::RenderReviewBoard()
    {
        if (!review_board_)
        {
            return;
        }
        auto const& metrics = board_presentation_.board_metrics;
        auto const radius = static_cast<double>(metrics.corner_radius);
        ReviewBoardOutline().CornerRadius(CornerRadius{ radius, radius, radius, radius });
        ReviewBoardOutline().BorderThickness(Thickness{
            static_cast<double>(metrics.border_width), static_cast<double>(metrics.border_width),
            static_cast<double>(metrics.border_width), static_cast<double>(metrics.border_width) });
        ReviewBoardOutline().BorderBrush(CreateBrush(Color(board_presentation_.border)));
        auto const visual = Microsoft::UI::Xaml::Hosting::ElementCompositionPreview::
            GetElementVisual(ReviewBoardClipHost());
        auto const clip = visual.Compositor().CreateRectangleClip();
        clip.Right(640.0f);
        clip.Bottom(640.0f);
        auto const corner = Windows::Foundation::Numerics::float2{
            static_cast<float>(radius), static_cast<float>(radius) };
        clip.TopLeftRadius(corner);
        clip.TopRightRadius(corner);
        clip.BottomLeftRadius(corner);
        clip.BottomRightRadius(corner);
        visual.Clip(clip);
        ReviewBoardGrid().Children().Clear();
        ReviewBoardGrid().RowDefinitions().Clear();
        ReviewBoardGrid().ColumnDefinitions().Clear();
        for (int index = 0; index < 8; ++index)
        {
            RowDefinition row;
            row.Height(GridLength{ 1, GridUnitType::Star });
            ReviewBoardGrid().RowDefinitions().Append(row);
            ColumnDefinition column;
            column.Width(GridLength{ 1, GridUnitType::Star });
            ReviewBoardGrid().ColumnDefinitions().Append(column);
        }
        auto const history = std::find_if(
            game_history_.begin(), game_history_.end(),
            [&](auto const& game) { return game.id == review_game_id_; });
        auto const black_perspective = history != game_history_.end()
            && history->player_color == L"black";
        for (int row = 0; row < 8; ++row)
        {
            for (int column = 0; column < 8; ++column)
            {
                auto const file_index = black_perspective ? 7 - column : column;
                auto const rank = black_perspective ? row + 1 : 8 - row;
                std::wstring square;
                square.push_back(static_cast<wchar_t>(L'a' + file_index));
                square += std::to_wstring(rank);
                hstring const square_id(square);
                auto const light = (file_index + rank) % 2 == 0;
                Border cell;
                cell.Background(CreateBrush(Color(
                    light ? board_presentation_.light_square : board_presentation_.dark_square)));
                Grid content;
                if (review_board_->last_move
                    && (review_board_->last_move->from == square_id
                        || review_board_->last_move->to == square_id))
                {
                    Shapes::Rectangle overlay;
                    overlay.Fill(CreateBrush(Color(board_presentation_.last_move)));
                    content.Children().Append(overlay);
                }
                auto const coordinate_color = light
                    ? board_presentation_.coordinate_on_light
                    : board_presentation_.coordinate_on_dark;
                if (column == 0)
                {
                    TextBlock label;
                    label.Text(winrt::to_hstring(rank));
                    label.FontSize(8.8);
                    label.FontWeight(Windows::UI::Text::FontWeights::Bold());
                    label.Foreground(CreateBrush(Color(coordinate_color)));
                    label.HorizontalAlignment(HorizontalAlignment::Left);
                    label.VerticalAlignment(VerticalAlignment::Top);
                    label.Margin(Thickness{ 3, 3, 0, 0 });
                    content.Children().Append(label);
                }
                if (row == 7)
                {
                    wchar_t const file_label[]{ static_cast<wchar_t>(L'a' + file_index), L'\0' };
                    TextBlock label;
                    label.Text(file_label);
                    label.FontSize(8.8);
                    label.FontWeight(Windows::UI::Text::FontWeights::Bold());
                    label.Foreground(CreateBrush(Color(coordinate_color)));
                    label.HorizontalAlignment(HorizontalAlignment::Right);
                    label.VerticalAlignment(VerticalAlignment::Bottom);
                    label.Margin(Thickness{ 0, 0, 3, 3 });
                    content.Children().Append(label);
                }
                auto const piece = std::find_if(
                    review_board_->pieces.begin(), review_board_->pieces.end(),
                    [&](auto const& candidate) { return candidate.square == square_id; });
                if (piece != review_board_->pieces.end())
                {
                    content.Children().Append(CreatePieceVisual(*piece, 80.0));
                }
                cell.Child(content);
                Grid::SetRow(cell, row);
                Grid::SetColumn(cell, column);
                ReviewBoardGrid().Children().Append(cell);
            }
        }
    }

    void MainWindow::HideWorkspacePanes()
    {
        NewGamePane().Visibility(Visibility::Collapsed);
        GamesPane().Visibility(Visibility::Collapsed);
        HistoryPane().Visibility(Visibility::Collapsed);
        ReviewPane().Visibility(Visibility::Collapsed);
        AppearancePane().Visibility(Visibility::Collapsed);
        GameLoadingPane().Visibility(Visibility::Collapsed);
        GamePane().Visibility(Visibility::Collapsed);
    }

    void MainWindow::StartLiveGame(hstring const& game_id, hstring const& player_color)
    {
        if (game_id.empty() || player_color.empty())
        {
            ShowMessage(L"The game couldn't be opened. Please try again.");
            return;
        }
        auto const already_connected = live_stream_states_.find(std::wstring(game_id));
        if (current_game_id_ == game_id
            && already_connected != live_stream_states_.end() && already_connected->second)
        {
            if (auto const cached = live_games_.find(std::wstring(game_id));
                cached != live_games_.end())
            {
                ShowLiveGame(cached->second);
            }
            return;
        }
        if (!current_game_id_.empty() && current_game_id_ != game_id)
        {
            auto const previous_game_id = current_game_id_;
            JsonObject stop;
            stop.Insert(L"type", JsonString(L"stop_live_game"));
            stop.Insert(L"game_id", JsonString(previous_game_id));
            SendCommand(stop);
            live_stream_states_.insert_or_assign(std::wstring(previous_game_id), false);
            for (auto iterator = live_start_requests_.begin();
                iterator != live_start_requests_.end();)
            {
                if (iterator->second == previous_game_id)
                {
                    iterator = live_start_requests_.erase(iterator);
                }
                else
                {
                    ++iterator;
                }
            }
            live_latest_start_request_by_game_.erase(std::wstring(previous_game_id));
        }
        current_game_id_ = game_id;
        pending_move_request_id_.clear();
        pending_game_action_request_id_.clear();
        move_rollback_board_.reset();
        live_stream_connected_ = false;
        if (auto const cached = live_games_.find(std::wstring(game_id)); cached != live_games_.end())
        {
            ShowLiveGame(cached->second);
        }
        else
        {
            live_game_.reset();
            clock_timer_.Stop();
            HideWorkspacePanes();
            GameLoadingPane().Visibility(Visibility::Visible);
        }
        JsonObject command;
        command.Insert(L"type", JsonString(L"start_live_game"));
        command.Insert(L"game_id", JsonString(game_id));
        command.Insert(L"player_color", JsonString(player_color));
        auto const request_id = SendCommand(command);
        if (auto const previous = live_latest_start_request_by_game_.find(std::wstring(game_id));
            previous != live_latest_start_request_by_game_.end())
        {
            live_start_requests_.erase(std::wstring(previous->second));
        }
        live_start_requests_.insert_or_assign(std::wstring(request_id), game_id);
        live_latest_start_request_by_game_.insert_or_assign(
            std::wstring(game_id), request_id);
        live_stream_states_.insert_or_assign(std::wstring(game_id), false);
        RefreshLiveGameNavigation();
    }

    void MainWindow::SelectNavigationForGame(hstring const& game_id)
    {
        auto const wanted = L"game:" + game_id;
        for (std::uint32_t index = 0; index < MainNavigation().MenuItems().Size(); ++index)
        {
            auto const item = MainNavigation().MenuItems().GetAt(index)
                .try_as<NavigationViewItem>();
            if (item && unbox_value_or<hstring>(item.Tag(), {}) == wanted)
            {
                if (MainNavigation().SelectedItem() != item)
                {
                    MainNavigation().SelectedItem(item);
                }
                return;
            }
        }
    }

    void MainWindow::ShowLiveGame(::LibChess::Windows::Wire::LiveGame game)
    {
        auto const previous = live_game_;
        auto const changed_game = previous && previous->id != game.id;
        PreparePieceAnimations(previous, game);
        live_game_ = std::move(game);
        current_game_id_ = live_game_->id;
        live_games_.insert_or_assign(std::wstring(live_game_->id), *live_game_);
        auto const received = live_game_received_times_.find(std::wstring(live_game_->id));
        if (received != live_game_received_times_.end())
        {
            live_game_received_at_ = received->second;
        }
        else
        {
            live_game_received_at_ = std::chrono::steady_clock::now();
            live_game_received_times_.insert_or_assign(
                std::wstring(live_game_->id), live_game_received_at_);
        }
        auto const claim_received = live_game_claim_received_times_.find(
            std::wstring(live_game_->id));
        live_game_claim_received_at_ = claim_received != live_game_claim_received_times_.end()
            ? claim_received->second : live_game_received_at_;
        move_rollback_board_.reset();
        move_rollback_white_time_millis_.reset();
        move_rollback_black_time_millis_.reset();
        selected_square_.clear();
        selected_drop_.clear();
        if (changed_game)
        {
            pending_move_request_id_.clear();
            pending_game_action_request_id_.clear();
        }
        CreateGameButton().IsEnabled(true);
        CreateGameProgress().Visibility(Visibility::Collapsed);
        BoardNavigationItem().IsEnabled(true);
        RefreshLiveGameNavigation();
        HideWorkspacePanes();
        GamePane().Visibility(Visibility::Visible);

        UpdateGameInspector();
        RenderBoard();
        if (live_game_->status == L"started"
            && (live_game_->has_clock || live_game_->opponent_gone))
        {
            clock_timer_.Start();
        }
        else
        {
            clock_timer_.Stop();
        }
    }

    void MainWindow::UpdateGameInspector()
    {
        if (!live_game_)
        {
            return;
        }
        auto const player_is_white = live_game_->player_color == L"white";
        auto const& player = player_is_white ? live_game_->white : live_game_->black;
        auto const& opponent = player_is_white ? live_game_->black : live_game_->white;
        auto const player_color = player_is_white ? hstring(L"white") : hstring(L"black");
        auto const opponent_color = player_is_white ? hstring(L"black") : hstring(L"white");

        PlayerName().Text(PlayerDisplayName(player));
        PlayerMetadata().Text(::PlayerMetadata(player, true));
        OpponentPlayer().Text(PlayerDisplayName(opponent));
        OpponentMetadata().Text(::PlayerMetadata(opponent, false));
        PlayerColorIndicator().Fill(CreateBrush(player_color == L"white"
            ? Windows::UI::Colors::White() : Windows::UI::Colors::Black()));
        OpponentColorIndicator().Fill(CreateBrush(opponent_color == L"white"
            ? Windows::UI::Colors::White() : Windows::UI::Colors::Black()));

        GameVariant().Text(live_game_->variant_name);
        auto metadata = live_game_->rated ? hstring(L"Rated") : hstring(L"Casual");
        if (!live_game_->speed.empty())
        {
            metadata = metadata + L" · " + DisplayLabel(live_game_->speed);
        }
        GameMetadata().Text(metadata);

        auto const playable = live_game_->status == L"created"
            || live_game_->status == L"started";
        hstring status = DisplayLabel(live_game_->status);
        if (live_game_->status == L"started")
        {
            status = live_game_->board.turn == live_game_->player_color
                ? L"In progress · Your move"
                : L"In progress · Waiting for opponent";
        }
        else if (!live_game_->winner.empty())
        {
            status = live_game_->winner == live_game_->player_color
                ? L"Game finished · You won"
                : L"Game finished · You lost";
        }
        else if (!playable)
        {
            static std::vector<std::wstring> const drawn{
                L"draw", L"stalemate", L"insufficientMaterialClaim" };
            status = std::find(drawn.begin(), drawn.end(), std::wstring(live_game_->status))
                    != drawn.end()
                ? L"Game finished · Draw"
                : status;
        }
        GameStatus().Text(status);

        LiveConnectionPanel().Visibility(
            playable && !live_stream_connected_ ? Visibility::Visible : Visibility::Collapsed);
        auto const latest_start = live_latest_start_request_by_game_.find(
            std::wstring(live_game_->id));
        auto const start_is_pending = !live_stream_connected_
            && latest_start != live_latest_start_request_by_game_.end();
        ReconnectGameButton().IsEnabled(!start_is_pending);
        ReconnectGameButton().Content(box_value(
            start_is_pending ? hstring(L"Connecting…") : hstring(L"Reconnect")));
        OpponentGoneInfoBar().IsOpen(playable && live_game_->opponent_gone);
        if (live_game_->opponent_gone)
        {
            auto message = hstring(L"Opponent disconnected");
            if (live_game_->claim_win_in_seconds && *live_game_->claim_win_in_seconds > 0)
            {
                message = message + L" · claim in "
                    + winrt::to_hstring(*live_game_->claim_win_in_seconds) + L"s";
            }
            OpponentGoneInfoBar().Message(message);
        }

        auto const opponent_draw = player_is_white
            ? live_game_->black_draw_offer : live_game_->white_draw_offer;
        auto const own_draw = player_is_white
            ? live_game_->white_draw_offer : live_game_->black_draw_offer;
        auto const opponent_takeback = player_is_white
            ? live_game_->black_takeback_offer : live_game_->white_takeback_offer;
        auto const own_takeback = player_is_white
            ? live_game_->white_takeback_offer : live_game_->black_takeback_offer;
        incoming_offer_ = opponent_draw ? L"draw" : opponent_takeback ? L"takeback" : L"";
        IncomingOfferPanel().Visibility(
            playable && !incoming_offer_.empty() ? Visibility::Visible : Visibility::Collapsed);
        IncomingOfferText().Text(incoming_offer_ == L"draw"
            ? L"Your opponent offered a draw."
            : L"Your opponent requested a takeback.");

        auto const pending = !pending_move_request_id_.empty()
            || !pending_game_action_request_id_.empty();
        auto const busy = pending || termination_dialog_open_;
        AcceptOfferButton().IsEnabled(!busy);
        DeclineOfferButton().IsEnabled(!busy);
        OfferDrawButton().IsEnabled(playable && !busy && !own_draw && incoming_offer_.empty());
        OfferDrawButton().Label(own_draw ? L"Draw offered" : L"Offer draw");
        TakebackButton().IsEnabled(playable && !busy && !own_takeback && incoming_offer_.empty());
        TakebackButton().Label(own_takeback ? L"Takeback requested" : L"Request takeback");
        TerminateGameButton().Label(live_game_->board.ply < 2 ? L"Abort" : L"Resign");
        TerminateGameButton().IsEnabled(playable && !busy);
        ClaimDrawButton().IsEnabled(playable && !busy);
        ClaimVictoryButton().Visibility(
            playable && live_game_->opponent_gone
                && live_game_->claim_win_in_seconds == std::optional<std::uint32_t>{ 0 }
                ? Visibility::Visible : Visibility::Collapsed);
        ClaimVictoryButton().IsEnabled(!busy);
        OpenGameButton().IsEnabled(!live_game_->url.empty());
        OfferDrawButton().Visibility(playable ? Visibility::Visible : Visibility::Collapsed);
        TakebackButton().Visibility(playable ? Visibility::Visible : Visibility::Collapsed);
        TerminateGameButton().Visibility(playable ? Visibility::Visible : Visibility::Collapsed);
        ClaimDrawButton().Visibility(playable ? Visibility::Visible : Visibility::Collapsed);

        GameActionProgress().Visibility(pending ? Visibility::Visible : Visibility::Collapsed);
        PendingGameText().Visibility(pending ? Visibility::Visible : Visibility::Collapsed);
        PendingGameText().Text(!pending_move_request_id_.empty()
            ? L"Move pending server confirmation"
            : L"Updating game…");

        PopulateMoveList();
        PopulatePockets();
        UpdateClocks();
    }

    void MainWindow::UpdateClocks()
    {
        if (!live_game_)
        {
            return;
        }
        auto const now = std::chrono::steady_clock::now();
        auto const elapsed = static_cast<std::uint64_t>(std::max<std::int64_t>(
            0,
            std::chrono::duration_cast<std::chrono::milliseconds>(
                now - live_game_received_at_).count()));
        auto clock_text = [&](hstring const& color) -> hstring
        {
            if (!live_game_->has_clock)
            {
                if (live_game_->days_per_turn)
                {
                    return FormatDays(*live_game_->days_per_turn);
                }
                return L"∞";
            }
            auto milliseconds = color == L"white"
                ? live_game_->white_time_millis : live_game_->black_time_millis;
            if (!milliseconds)
            {
                return L"∞";
            }
            if (live_game_->status == L"started" && live_game_->board.turn == color)
            {
                *milliseconds = *milliseconds > elapsed ? *milliseconds - elapsed : 0;
            }
            wchar_t buffer[32]{};
            if (*milliseconds < 10'000)
            {
                swprintf_s(buffer, L"%.1f", static_cast<double>(*milliseconds) / 1'000.0);
                return hstring(buffer);
            }
            auto const seconds = *milliseconds / 1'000;
            if (seconds >= 3'600)
            {
                swprintf_s(buffer, L"%llu:%02llu:%02llu",
                    seconds / 3'600, (seconds / 60) % 60, seconds % 60);
            }
            else
            {
                swprintf_s(buffer, L"%llu:%02llu", seconds / 60, seconds % 60);
            }
            return hstring(buffer);
        };

        auto const player_is_white = live_game_->player_color == L"white";
        PlayerClock().Text(clock_text(player_is_white ? L"white" : L"black"));
        OpponentClock().Text(clock_text(player_is_white ? L"black" : L"white"));

        Windows::UI::Color active{ 0, 0, 0, 0 };
        try
        {
            active = Windows::UI::ViewManagement::UISettings().GetColorValue(
                Windows::UI::ViewManagement::UIColorType::Accent);
            active.A = 28;
        }
        catch (...)
        {
            active = Windows::UI::Color{ 28, 0, 120, 212 };
        }
        auto const transparent = CreateBrush(Windows::UI::Color{ 0, 0, 0, 0 });
        auto const accent = CreateBrush(active);
        auto const playable = live_game_->status == L"created" || live_game_->status == L"started";
        PlayerRow().Background(playable && live_game_->board.turn == live_game_->player_color
            ? accent : transparent);
        auto const opponent_color = player_is_white ? hstring(L"black") : hstring(L"white");
        OpponentRow().Background(playable && live_game_->board.turn == opponent_color
            ? accent : transparent);
    }

    void MainWindow::ClockTimer_Tick(
        Windows::Foundation::IInspectable const&,
        Windows::Foundation::IInspectable const&)
    {
        UpdateClocks();
        if (!live_game_ || !live_game_->opponent_gone || !live_game_->claim_win_in_seconds)
        {
            return;
        }
        auto const elapsed = std::chrono::duration_cast<std::chrono::seconds>(
            std::chrono::steady_clock::now() - live_game_claim_received_at_).count();
        auto const initial = static_cast<std::int64_t>(*live_game_->claim_win_in_seconds);
        auto const remaining = static_cast<std::uint32_t>(std::max<std::int64_t>(0, initial - elapsed));
        OpponentGoneInfoBar().Message(remaining > 0
            ? L"Opponent disconnected · claim in " + winrt::to_hstring(remaining) + L"s"
            : L"Opponent disconnected · victory can be claimed");
        ClaimVictoryButton().Visibility(remaining == 0
            ? Visibility::Visible : Visibility::Collapsed);
    }

    void MainWindow::PopulateMoveList()
    {
        MoveListView().Items().Clear();
        if (!live_game_ || live_game_->board.moves.empty())
        {
            TextBlock empty;
            empty.Text(L"The game has not started.");
            empty.Foreground(Application::Current().Resources()
                .Lookup(box_value(L"TextFillColorSecondaryBrush")).as<Brush>());
            empty.Margin(Thickness{ 8, 6, 8, 6 });
            MoveListView().Items().Append(empty);
            return;
        }
        for (std::size_t index = 0; index < live_game_->board.moves.size(); index += 2)
        {
            Grid row;
            row.ColumnSpacing(8);
            ColumnDefinition number_column;
            number_column.Width(GridLength{ 34, GridUnitType::Pixel });
            row.ColumnDefinitions().Append(number_column);
            for (int column_index = 0; column_index < 2; ++column_index)
            {
                ColumnDefinition move_column;
                move_column.Width(GridLength{ 1, GridUnitType::Star });
                row.ColumnDefinitions().Append(move_column);
            }
            TextBlock number;
            number.Text(winrt::to_hstring(index / 2 + 1) + L".");
            number.HorizontalAlignment(HorizontalAlignment::Right);
            number.Opacity(0.58);
            Grid::SetColumn(number, 0);
            row.Children().Append(number);
            TextBlock white;
            white.Text(live_game_->board.moves[index]);
            white.FontFamily(Media::FontFamily(L"Cascadia Mono, Consolas"));
            Grid::SetColumn(white, 1);
            row.Children().Append(white);
            if (index + 1 < live_game_->board.moves.size())
            {
                TextBlock black;
                black.Text(live_game_->board.moves[index + 1]);
                black.FontFamily(Media::FontFamily(L"Cascadia Mono, Consolas"));
                Grid::SetColumn(black, 2);
                row.Children().Append(black);
            }
            MoveListView().Items().Append(row);
        }
        auto const last = MoveListView().Items().GetAt(MoveListView().Items().Size() - 1);
        MoveListView().ScrollIntoView(last);
    }

    void MainWindow::PopulatePockets()
    {
        if (!live_game_)
        {
            return;
        }
        auto const player_color = live_game_->player_color;
        auto const opponent_color = player_color == L"white" ? hstring(L"black") : hstring(L"white");
        PopulatePocketRow(OpponentPocketRow(), opponent_color, false);
        PopulatePocketRow(PlayerPocketRow(), player_color, true);
    }

    void MainWindow::PopulatePocketRow(
        ItemsControl const& row,
        hstring const& color,
        bool selectable)
    {
        row.Items().Clear();
        if (!live_game_)
        {
            row.Visibility(Visibility::Collapsed);
            return;
        }
        auto const can_move = selectable
            && (live_game_->status == L"created" || live_game_->status == L"started")
            && live_game_->board.turn == live_game_->player_color
            && pending_move_request_id_.empty()
            && pending_game_action_request_id_.empty();
        for (auto const& pocket : live_game_->board.pockets)
        {
            if (pocket.color != color || pocket.count == 0)
            {
                continue;
            }
            Controls::Primitives::ToggleButton button;
            button.Tag(box_value(pocket.role));
            button.IsChecked(selected_drop_ == pocket.role);
            button.IsEnabled(can_move && std::any_of(
                live_game_->board.legal_moves.begin(), live_game_->board.legal_moves.end(),
                [&](auto const& move) { return move.drop == pocket.role; }));
            button.Click({ this, &MainWindow::PocketPiece_Click });
            button.Padding(Thickness{ 8, 4, 8, 4 });

            StackPanel content;
            content.Orientation(Orientation::Horizontal);
            content.Spacing(4);
            ::LibChess::Windows::Wire::BoardPiece piece{
                {}, pocket.color, pocket.role, false };
            content.Children().Append(CreatePieceVisual(piece, 38));
            TextBlock count;
            count.Text(L"×" + winrt::to_hstring(pocket.count));
            count.VerticalAlignment(VerticalAlignment::Center);
            count.Style(Application::Current().Resources()
                .Lookup(box_value(L"CaptionTextBlockStyle")).as<Style>());
            content.Children().Append(count);
            button.Content(content);
            row.Items().Append(button);
        }
        row.Visibility(row.Items().Size() > 0 ? Visibility::Visible : Visibility::Collapsed);
    }

    void MainWindow::PocketPiece_Click(
        Windows::Foundation::IInspectable const& sender,
        Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        auto const role = unbox_value<hstring>(
            sender.as<Controls::Primitives::ToggleButton>().Tag());
        selected_drop_ = selected_drop_ == role ? hstring{} : role;
        selected_square_.clear();
        PopulatePockets();
        RenderBoard();
    }

    void MainWindow::RefreshHistory_Click(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        RefreshGameHistory(false);
    }

    void MainWindow::LoadMoreHistory_Click(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        RefreshGameHistory(true);
    }

    void MainWindow::HistoryGame_Click(
        Windows::Foundation::IInspectable const& sender,
        Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        LoadGameReview(unbox_value<hstring>(sender.as<Button>().Tag()));
    }

    void MainWindow::GameCard_Click(
        Windows::Foundation::IInspectable const& sender,
        Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        auto const game_id = unbox_value<hstring>(sender.as<Button>().Tag());
        auto const summary = std::find_if(
            live_game_summaries_.begin(), live_game_summaries_.end(),
            [&](auto const& game) { return game.id == game_id; });
        if (summary != live_game_summaries_.end())
        {
            StartLiveGame(summary->id, summary->player_color);
        }
        else if (live_game_ && live_game_->id == game_id)
        {
            SelectNavigationForGame(game_id);
            HideWorkspacePanes();
            GamePane().Visibility(Visibility::Visible);
        }
    }

    void MainWindow::ReviewMove_Click(
        Windows::Foundation::IInspectable const& sender,
        Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        ShowReviewPosition(unbox_value<std::uint32_t>(sender.as<Button>().Tag()));
    }

    void MainWindow::ReviewFirst_Click(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        ShowReviewPosition(0);
    }

    void MainWindow::ReviewPrevious_Click(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        ShowReviewPosition(review_ply_ == 0 ? 0 : review_ply_ - 1);
    }

    void MainWindow::ReviewNext_Click(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        if (game_review_)
        {
            ShowReviewPosition((std::min)(
                review_ply_ + 1, static_cast<std::uint32_t>(game_review_->moves.size())));
        }
    }

    void MainWindow::ReviewLast_Click(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        if (game_review_)
        {
            ShowReviewPosition(static_cast<std::uint32_t>(game_review_->moves.size()));
        }
    }

    void MainWindow::OpenAnalysis_Click(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        OpenAnalysisAsync();
    }

    void MainWindow::ExportPgn_Click(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        if (review_game_id_.empty() || !pending_export_request_id_.empty()) return;
        if (!selected_provider_ || *selected_provider_ >= providers_.size()
            || !providers_[*selected_provider_].Supports(L"pgn_export"))
        {
            ShowMessage(L"The connected service does not support PGN export.", false);
            return;
        }
        JsonObject command;
        command.Insert(L"type", JsonString(L"export_game"));
        command.Insert(L"game_id", JsonString(review_game_id_));
        pending_export_game_id_ = review_game_id_;
        pending_export_request_id_ = SendCommand(command);
        ExportPgnButton().IsEnabled(false);
        ExportPgnButton().Content(box_value(L"Preparing PGN…"));
    }

    winrt::fire_and_forget MainWindow::SavePgnAsync(hstring filename, hstring pgn)
    {
        auto lifetime = get_strong();
        try
        {
            Windows::Storage::Pickers::FileSavePicker picker;
            HWND hwnd = nullptr;
            Microsoft::UI::Xaml::Window window = *this;
            check_hresult(window.as<::IWindowNative>()->get_WindowHandle(&hwnd));
            check_hresult(picker.as<::IInitializeWithWindow>()->Initialize(hwnd));
            picker.SuggestedFileName(filename);
            picker.FileTypeChoices().Insert(
                L"Portable Game Notation",
                winrt::single_threaded_vector<hstring>({ L".pgn" }));
            auto const file = co_await picker.PickSaveFileAsync();
            if (!file) co_return;
            co_await Windows::Storage::FileIO::WriteTextAsync(
                file, pgn, Windows::Storage::Streams::UnicodeEncoding::Utf8);
            ShowMessage(L"PGN exported to " + file.Name() + L".", false);
        }
        catch (winrt::hresult_error const& error)
        {
            ShowMessage(L"The PGN could not be saved: " + error.message());
        }
    }

    void MainWindow::MainNavigation_SelectionChanged(
        Microsoft::UI::Xaml::Controls::NavigationView const&,
        Microsoft::UI::Xaml::Controls::NavigationViewSelectionChangedEventArgs const& args)
    {
        auto const item = args.SelectedItem().try_as<NavigationViewItem>();
        auto const tag = item ? unbox_value_or<hstring>(item.Tag(), {}) : hstring{};
        auto const tag_value = std::wstring(tag);
        if (tag_value.size() > 5 && tag_value.compare(0, 5, L"game:") == 0)
        {
            auto const game_id = hstring(tag_value.substr(5));
            if (game_id != current_game_id_)
            {
                if (!pending_move_request_id_.empty() || !pending_game_action_request_id_.empty()
                    || termination_dialog_open_)
                {
                    ShowMessage(L"Wait for the current game update before switching games.", false);
                    SelectNavigationForGame(current_game_id_);
                    return;
                }
                auto const summary = std::find_if(
                    live_game_summaries_.begin(), live_game_summaries_.end(),
                    [&](auto const& game) { return game.id == game_id; });
                if (summary != live_game_summaries_.end())
                {
                    StartLiveGame(summary->id, summary->player_color);
                }
            }
            auto const board = live_game_ && live_game_->id == game_id;
            auto const loading = !board && current_game_id_ == game_id;
            HideWorkspacePanes();
            GamePane().Visibility(board ? Visibility::Visible : Visibility::Collapsed);
            GameLoadingPane().Visibility(
                loading ? Visibility::Visible : Visibility::Collapsed);
            return;
        }
        HideWorkspacePanes();
        if (tag == L"games")
        {
            PopulateGamesPage();
            GamesPane().Visibility(Visibility::Visible);
        }
        else if (tag == L"history")
        {
            HistoryPane().Visibility(Visibility::Visible);
            if (game_history_.empty() && !history_request_pending_)
            {
                RefreshGameHistory(false);
            }
        }
        else if (tag == L"appearance")
        {
            PopulateSettingsAppearance();
            PopulateCustomizationEditors();
            RenderAppearancePreview();
            AppearancePane().Visibility(Visibility::Visible);
        }
        else
        {
            NewGamePane().Visibility(Visibility::Visible);
        }
    }

    Windows::UI::Color MainWindow::Color(::LibChess::Windows::Wire::RgbaColor const& color)
    {
        return Windows::UI::Color{ color.alpha, color.red, color.green, color.blue };
    }

    hstring MainWindow::PieceFallback(hstring const& color, hstring const& role)
    {
        static std::unordered_map<std::wstring, wchar_t> const pieces{
            { L"white/pawn", L'\u2659' }, { L"white/knight", L'\u2658' },
            { L"white/bishop", L'\u2657' }, { L"white/rook", L'\u2656' },
            { L"white/queen", L'\u2655' }, { L"white/king", L'\u2654' },
            { L"black/pawn", L'\u265F' }, { L"black/knight", L'\u265E' },
            { L"black/bishop", L'\u265D' }, { L"black/rook", L'\u265C' },
            { L"black/queen", L'\u265B' }, { L"black/king", L'\u265A' },
        };
        auto const key = std::wstring(color) + L"/" + std::wstring(role);
        auto const found = pieces.find(key);
        if (found == pieces.end())
        {
            return {};
        }
        wchar_t const glyph[]{ found->second, L'\0' };
        return hstring(glyph);
    }

    void MainWindow::PreparePieceAnimations(
        std::optional<::LibChess::Windows::Wire::LiveGame> const& previous,
        ::LibChess::Windows::Wire::LiveGame const& current)
    {
        piece_animation_origins_.clear();
        piece_appearance_squares_.clear();
        if (!previous || previous->id != current.id)
        {
            return;
        }
        auto const ply_distance = previous->board.ply > current.board.ply
            ? previous->board.ply - current.board.ply
            : current.board.ply - previous->board.ply;
        if (ply_distance == 0
            || ply_distance > board_presentation_.motion.maximum_animated_ply_distance)
        {
            return;
        }
        try
        {
            if (!Windows::UI::ViewManagement::UISettings().AnimationsEnabled())
            {
                return;
            }
        }
        catch (...)
        {
        }

        auto const& old_pieces = previous->board.pieces;
        auto const& new_pieces = current.board.pieces;
        std::vector<bool> old_used(old_pieces.size(), false);
        std::vector<bool> new_used(new_pieces.size(), false);

        if (current.board.last_move && !current.board.last_move->from.empty())
        {
            auto const& from = current.board.last_move->from;
            auto const& to = current.board.last_move->to;
            auto const old_index = std::find_if(
                old_pieces.begin(), old_pieces.end(),
                [&](auto const& piece) { return piece.square == from; });
            auto const new_index = std::find_if(
                new_pieces.begin(), new_pieces.end(),
                [&](auto const& piece) { return piece.square == to; });
            if (old_index != old_pieces.end() && new_index != new_pieces.end()
                && old_index->color == new_index->color)
            {
                auto const old_offset = static_cast<std::size_t>(old_index - old_pieces.begin());
                auto const new_offset = static_cast<std::size_t>(new_index - new_pieces.begin());
                old_used[old_offset] = true;
                new_used[new_offset] = true;
                piece_animation_origins_.insert_or_assign(std::wstring(to), from);
            }
        }

        for (std::size_t next = 0; next < new_pieces.size(); ++next)
        {
            if (new_used[next])
            {
                continue;
            }
            for (std::size_t old = 0; old < old_pieces.size(); ++old)
            {
                if (!old_used[old]
                    && old_pieces[old].square == new_pieces[next].square
                    && old_pieces[old].color == new_pieces[next].color
                    && old_pieces[old].role == new_pieces[next].role)
                {
                    old_used[old] = true;
                    new_used[next] = true;
                    break;
                }
            }
        }
        for (std::size_t next = 0; next < new_pieces.size(); ++next)
        {
            if (!new_used[next])
            {
                piece_appearance_squares_.push_back(new_pieces[next].square);
            }
        }

        for (std::size_t next = 0; next < new_pieces.size(); ++next)
        {
            if (new_used[next])
            {
                continue;
            }
            std::optional<std::size_t> nearest;
            for (std::size_t old = 0; old < old_pieces.size(); ++old)
            {
                if (old_used[old]
                    || old_pieces[old].color != new_pieces[next].color
                    || old_pieces[old].role != new_pieces[next].role)
                {
                    continue;
                }
                if (!nearest
                    || SquareDistance(old_pieces[old].square, new_pieces[next].square)
                        < SquareDistance(old_pieces[*nearest].square, new_pieces[next].square))
                {
                    nearest = old;
                }
            }
            if (nearest)
            {
                old_used[*nearest] = true;
                new_used[next] = true;
                if (old_pieces[*nearest].square != new_pieces[next].square)
                {
                    piece_animation_origins_.insert_or_assign(
                        std::wstring(new_pieces[next].square),
                        old_pieces[*nearest].square);
                }
            }
        }
    }

    void MainWindow::PopulateThemeChoices(
        ::LibChess::Windows::Wire::BoardProvider const& provider,
        hstring const& board_theme,
        hstring const& piece_theme)
    {
        BoardThemePicker().Items().Clear();
        PieceThemePicker().Items().Clear();
        for (auto const& theme : provider.board_themes)
        {
            AppendComboItem(BoardThemePicker(), theme.display_name, theme.id);
        }
        for (auto const& theme : provider.piece_themes)
        {
            AppendComboItem(PieceThemePicker(), theme.display_name, theme.id);
        }
        SelectComboTag(
            BoardThemePicker(),
            board_theme.empty() ? provider.default_board_theme : board_theme);
        SelectComboTag(
            PieceThemePicker(),
            piece_theme.empty() ? provider.default_piece_theme : piece_theme);
    }

    void MainWindow::PopulateBoardAppearance()
    {
        populating_board_appearance_ = true;
        BoardProviderPicker().Items().Clear();
        for (auto const& provider : board_providers_)
        {
            AppendComboItem(BoardProviderPicker(), provider.display_name, provider.id);
        }
        SelectComboTag(BoardProviderPicker(), board_presentation_.provider);
        auto const provider_id = ComboTag(BoardProviderPicker());
        auto const provider = std::find_if(
            board_providers_.begin(), board_providers_.end(),
            [&](auto const& candidate) { return candidate.id == provider_id; });
        if (provider != board_providers_.end())
        {
            PopulateThemeChoices(
                *provider,
                board_presentation_.provider == provider->id
                    ? board_presentation_.board_theme : provider->default_board_theme,
                board_presentation_.provider == provider->id
                    ? board_presentation_.piece_theme : provider->default_piece_theme);
        }

        BoardZoomPicker().Items().Clear();
        for (auto const& preset : board_presentation_.zoom_presets)
        {
            AppendComboItem(BoardZoomPicker(), preset.display_name, preset.id);
        }
        auto saved_zoom = ReadPreference(L"BoardZoom");
        auto const saved_is_valid = std::any_of(
            board_presentation_.zoom_presets.begin(),
            board_presentation_.zoom_presets.end(),
            [&](auto const& preset) { return preset.id == saved_zoom; });
        SelectComboTag(
            BoardZoomPicker(),
            saved_is_valid ? saved_zoom : board_presentation_.default_zoom_preset);
        auto const selected_zoom = ComboTag(BoardZoomPicker());
        auto const zoom = std::find_if(
            board_presentation_.zoom_presets.begin(),
            board_presentation_.zoom_presets.end(),
            [&](auto const& preset) { return preset.id == selected_zoom; });
        board_zoom_scale_percent_ = zoom == board_presentation_.zoom_presets.end()
            ? 100 : zoom->scale_percent;
        populating_board_appearance_ = false;
        ApplyBoardChrome();
    }

    void MainWindow::PopulateSettingsAppearance()
    {
        populating_board_appearance_ = true;
        SettingsBoardProviderPicker().Items().Clear();
        for (auto const& provider : board_providers_)
        {
            AppendComboItem(SettingsBoardProviderPicker(), provider.display_name, provider.id);
        }
        SelectComboTag(SettingsBoardProviderPicker(), board_presentation_.provider);
        auto const provider_id = ComboTag(SettingsBoardProviderPicker());
        auto const provider = std::find_if(
            board_providers_.begin(), board_providers_.end(),
            [&](auto const& candidate) { return candidate.id == provider_id; });
        SettingsBoardThemePicker().Items().Clear();
        SettingsPieceThemePicker().Items().Clear();
        if (provider != board_providers_.end())
        {
            for (auto const& theme : provider->board_themes)
            {
                AppendComboItem(SettingsBoardThemePicker(), theme.display_name, theme.id);
            }
            for (auto const& theme : provider->piece_themes)
            {
                AppendComboItem(SettingsPieceThemePicker(), theme.display_name, theme.id);
            }
            SelectComboTag(SettingsBoardThemePicker(),
                provider->id == board_presentation_.provider
                    ? board_presentation_.board_theme : provider->default_board_theme);
            SelectComboTag(SettingsPieceThemePicker(),
                provider->id == board_presentation_.provider
                    ? board_presentation_.piece_theme : provider->default_piece_theme);
        }
        SettingsBoardZoomPicker().Items().Clear();
        for (auto const& preset : board_presentation_.zoom_presets)
        {
            AppendComboItem(SettingsBoardZoomPicker(), preset.display_name, preset.id);
        }
        SelectComboTag(SettingsBoardZoomPicker(), ComboTag(BoardZoomPicker()));
        populating_board_appearance_ = false;
    }

    void MainWindow::RestoreBoardAppearance()
    {
        auto const provider_id = ReadPreference(L"BoardProvider");
        auto const board_theme = ReadPreference(L"BoardTheme");
        auto const piece_theme = ReadPreference(L"PieceTheme");
        auto const provider = std::find_if(
            board_providers_.begin(), board_providers_.end(),
            [&](auto const& candidate) { return candidate.id == provider_id; });
        if (provider == board_providers_.end()
            || std::none_of(provider->board_themes.begin(), provider->board_themes.end(),
                [&](auto const& theme) { return theme.id == board_theme; })
            || std::none_of(provider->piece_themes.begin(), provider->piece_themes.end(),
                [&](auto const& theme) { return theme.id == piece_theme; }))
        {
            return;
        }
        if (provider_id == board_presentation_.provider
            && board_theme == board_presentation_.board_theme
            && piece_theme == board_presentation_.piece_theme)
        {
            return;
        }

        populating_board_appearance_ = true;
        SelectComboTag(BoardProviderPicker(), provider_id);
        PopulateThemeChoices(*provider, board_theme, piece_theme);
        populating_board_appearance_ = false;
        RequestBoardPresentation(BoardProviderPicker(), BoardThemePicker(), PieceThemePicker());
    }

    void MainWindow::RequestBoardPresentation(
        ComboBox const& provider_picker,
        ComboBox const& board_picker,
        ComboBox const& piece_picker)
    {
        auto const provider = ComboTag(provider_picker);
        auto const board_theme = ComboTag(board_picker);
        auto const piece_theme = ComboTag(piece_picker);
        if (provider.empty() || board_theme.empty() || piece_theme.empty())
        {
            return;
        }
        JsonObject command;
        command.Insert(L"type", JsonString(L"load_board_presentation"));
        command.Insert(L"provider", JsonString(provider));
        command.Insert(L"board_theme", JsonString(board_theme));
        command.Insert(L"piece_theme", JsonString(piece_theme));
        pending_board_presentation_request_id_ = SendCommand(command);
        AppearanceProgress().Visibility(Visibility::Visible);
    }

    void MainWindow::BoardAppearancePicker_SelectionChanged(
        Windows::Foundation::IInspectable const& sender,
        Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&)
    {
        if (populating_board_appearance_)
        {
            return;
        }
        if (sender == BoardProviderPicker())
        {
            auto const provider_id = ComboTag(BoardProviderPicker());
            auto const provider = std::find_if(
                board_providers_.begin(), board_providers_.end(),
                [&](auto const& candidate) { return candidate.id == provider_id; });
            if (provider == board_providers_.end())
            {
                return;
            }
            populating_board_appearance_ = true;
            PopulateThemeChoices(
                *provider, provider->default_board_theme, provider->default_piece_theme);
            populating_board_appearance_ = false;
        }
        RequestBoardPresentation(BoardProviderPicker(), BoardThemePicker(), PieceThemePicker());
    }

    void MainWindow::GameAppearance_Click(
        Windows::Foundation::IInspectable const& sender,
        Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        PopulateBoardAppearance();
        Microsoft::UI::Xaml::Controls::Primitives::FlyoutBase::ShowAttachedFlyout(
            sender.as<Microsoft::UI::Xaml::FrameworkElement>());
    }

    void MainWindow::SettingsBoardAppearancePicker_SelectionChanged(
        Windows::Foundation::IInspectable const& sender,
        Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&)
    {
        if (populating_board_appearance_)
        {
            return;
        }
        if (sender == SettingsBoardProviderPicker())
        {
            auto const provider_id = ComboTag(SettingsBoardProviderPicker());
            auto const provider = std::find_if(
                board_providers_.begin(), board_providers_.end(),
                [&](auto const& candidate) { return candidate.id == provider_id; });
            if (provider == board_providers_.end())
            {
                return;
            }
            populating_board_appearance_ = true;
            SettingsBoardThemePicker().Items().Clear();
            SettingsPieceThemePicker().Items().Clear();
            for (auto const& theme : provider->board_themes)
            {
                AppendComboItem(SettingsBoardThemePicker(), theme.display_name, theme.id);
            }
            for (auto const& theme : provider->piece_themes)
            {
                AppendComboItem(SettingsPieceThemePicker(), theme.display_name, theme.id);
            }
            SelectComboTag(SettingsBoardThemePicker(), provider->default_board_theme);
            SelectComboTag(SettingsPieceThemePicker(), provider->default_piece_theme);
            populating_board_appearance_ = false;
        }
        RequestBoardPresentation(
            SettingsBoardProviderPicker(), SettingsBoardThemePicker(), SettingsPieceThemePicker());
    }

    void MainWindow::BoardZoomPicker_SelectionChanged(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&)
    {
        if (populating_board_appearance_)
        {
            return;
        }
        auto const selected = ComboTag(BoardZoomPicker());
        auto const preset = std::find_if(
            board_presentation_.zoom_presets.begin(),
            board_presentation_.zoom_presets.end(),
            [&](auto const& candidate) { return candidate.id == selected; });
        if (preset == board_presentation_.zoom_presets.end())
        {
            return;
        }
        board_zoom_scale_percent_ = preset->scale_percent;
        WritePreference(L"BoardZoom", preset->id);
        ApplyBoardChrome();
        PopulateSettingsAppearance();
    }

    void MainWindow::SettingsBoardZoomPicker_SelectionChanged(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&)
    {
        if (populating_board_appearance_)
        {
            return;
        }
        auto const selected = ComboTag(SettingsBoardZoomPicker());
        auto const preset = std::find_if(
            board_presentation_.zoom_presets.begin(), board_presentation_.zoom_presets.end(),
            [&](auto const& candidate) { return candidate.id == selected; });
        if (preset == board_presentation_.zoom_presets.end())
        {
            return;
        }
        board_zoom_scale_percent_ = preset->scale_percent;
        WritePreference(L"BoardZoom", preset->id);
        populating_board_appearance_ = true;
        SelectComboTag(BoardZoomPicker(), preset->id);
        populating_board_appearance_ = false;
        ApplyBoardChrome();
    }

    void MainWindow::PopulateCustomizationEditors()
    {
        populating_customization_ = true;
        auto const board_selection = ComboTag(CustomBoardThemePicker());
        auto const piece_selection = ComboTag(CustomPieceThemePicker());
        CustomBoardThemePicker().Items().Clear();
        CustomPieceThemePicker().Items().Clear();
        AppendComboItem(CustomBoardThemePicker(), L"New board theme", L"");
        AppendComboItem(CustomPieceThemePicker(), L"New piece theme", L"");
        if (auto const themes = Array(board_customization_state_, L"board_themes"))
        {
            for (auto const& value : themes)
            {
                auto const theme = value.GetObject();
                AppendComboItem(CustomBoardThemePicker(),
                    String(theme, L"display_name"), CustomThemeKey(theme));
            }
        }
        if (auto const themes = Array(board_customization_state_, L"piece_themes"))
        {
            for (auto const& value : themes)
            {
                auto const theme = value.GetObject();
                AppendComboItem(CustomPieceThemePicker(),
                    String(theme, L"display_name"), CustomThemeKey(theme));
            }
        }

        auto populate_providers = [&](ComboBox const& picker)
        {
            auto const selected = ComboTag(picker);
            picker.Items().Clear();
            for (auto const& provider : board_providers_)
            {
                AppendComboItem(picker, provider.display_name, provider.id);
            }
            SelectComboTag(picker, selected.empty() ? board_presentation_.provider : selected);
        };
        populate_providers(BoardThemeProviderBox());
        populate_providers(PieceThemeProviderBox());
        SelectComboTag(CustomBoardThemePicker(), board_selection);
        SelectComboTag(CustomPieceThemePicker(), piece_selection);
        populating_customization_ = false;

        if (board_selection.empty()) ResetBoardThemeEditor();
        else CustomBoardThemePicker_SelectionChanged(nullptr, nullptr);
        if (piece_selection.empty()) ResetPieceThemeEditor();
        else CustomPieceThemePicker_SelectionChanged(nullptr, nullptr);
    }

    void MainWindow::PopulateBaseThemes(bool board)
    {
        auto const provider_id = ComboTag(board ? BoardThemeProviderBox() : PieceThemeProviderBox());
        auto const provider = std::find_if(board_providers_.begin(), board_providers_.end(),
            [&](auto const& candidate) { return candidate.id == provider_id; });
        auto const picker = board ? BoardBaseThemeBox() : PieceBaseThemeBox();
        auto const selected = ComboTag(picker);
        picker.Items().Clear();
        if (provider != board_providers_.end())
        {
            if (board)
            {
                for (auto const& theme : provider->board_themes)
                {
                    bool custom = false;
                    if (auto const themes = Array(board_customization_state_, L"board_themes"))
                    {
                        custom = std::any_of(themes.begin(), themes.end(), [&](auto const& value)
                        {
                            auto const candidate = value.GetObject();
                            return String(candidate, L"provider") == provider_id
                                && String(candidate, L"id") == theme.id;
                        });
                    }
                    if (!custom) AppendComboItem(picker, theme.display_name, theme.id);
                }
            }
            else
            {
                for (auto const& theme : provider->piece_themes)
                {
                    bool custom = false;
                    if (auto const themes = Array(board_customization_state_, L"piece_themes"))
                    {
                        custom = std::any_of(themes.begin(), themes.end(), [&](auto const& value)
                        {
                            auto const candidate = value.GetObject();
                            return String(candidate, L"provider") == provider_id
                                && String(candidate, L"id") == theme.id;
                        });
                    }
                    if (!custom) AppendComboItem(picker, theme.display_name, theme.id);
                }
            }
        }
        SelectComboTag(picker, selected);
    }

    void MainWindow::ResetBoardThemeEditor()
    {
        populating_customization_ = true;
        BoardThemeNameBox().Text(L"");
        BoardThemeIdBox().Text(L"custom-board");
        BoardThemeIdBox().IsEnabled(true);
        BoardThemeProviderBox().IsEnabled(true);
        SelectComboTag(BoardThemeProviderBox(), board_presentation_.provider);
        PopulateBaseThemes(true);
        SelectComboTag(BoardBaseThemeBox(), board_presentation_.board_theme);
        BoardHueBox().Value(0); BoardSaturationBox().Value(0); BoardBrightnessBox().Value(0);
        BoardLightColorPicker().Color(Color(board_presentation_.light_square));
        BoardDarkColorPicker().Color(Color(board_presentation_.dark_square));
        BoardLastMoveColorPicker().Color(Color(board_presentation_.last_move));
        BoardSelectionColorPicker().Color(Color(board_presentation_.selection));
        BoardLegalMoveColorPicker().Color(Color(board_presentation_.legal_move));
        populating_customization_ = false;
    }

    void MainWindow::ResetPieceThemeEditor()
    {
        populating_customization_ = true;
        PieceThemeNameBox().Text(L"");
        PieceThemeIdBox().Text(L"custom-pieces");
        PieceThemeIdBox().IsEnabled(true);
        PieceThemeProviderBox().IsEnabled(true);
        SelectComboTag(PieceThemeProviderBox(), board_presentation_.provider);
        PopulateBaseThemes(false);
        SelectComboTag(PieceBaseThemeBox(), board_presentation_.piece_theme);
        PieceHueBox().Value(0); PieceSaturationBox().Value(0); PieceBrightnessBox().Value(0);
        WhitePieceColorPicker().Color(Color(board_presentation_.white_piece));
        BlackPieceColorPicker().Color(Color(board_presentation_.black_piece));
        PromotedMarkerColorPicker().Color(Color(board_presentation_.promoted_marker_color));
        pending_piece_assets_ = nullptr;
        PieceAssetsStatus().Text(L"Using assets from the base theme.");
        populating_customization_ = false;
    }

    void MainWindow::LoadBoardThemeEditor(JsonObject const& theme)
    {
        populating_customization_ = true;
        BoardThemeNameBox().Text(String(theme, L"display_name"));
        BoardThemeIdBox().Text(String(theme, L"id"));
        BoardThemeIdBox().IsEnabled(false);
        BoardThemeProviderBox().IsEnabled(false);
        SelectComboTag(BoardThemeProviderBox(), String(theme, L"provider"));
        PopulateBaseThemes(true);
        SelectComboTag(BoardBaseThemeBox(), String(theme, L"base_theme"));
        auto const adjustment = Object(theme, L"adjustment");
        BoardHueBox().Value(adjustment ? adjustment.GetNamedNumber(L"hue_degrees", 0) : 0);
        BoardSaturationBox().Value(adjustment ? adjustment.GetNamedNumber(L"saturation_percent", 0) : 0);
        BoardBrightnessBox().Value(adjustment ? adjustment.GetNamedNumber(L"brightness_percent", 0) : 0);
        auto const colors = Object(theme, L"colors");
        BoardLightColorPicker().Color(JsonUiColor(Object(colors, L"light_square"), Color(board_presentation_.light_square)));
        BoardDarkColorPicker().Color(JsonUiColor(Object(colors, L"dark_square"), Color(board_presentation_.dark_square)));
        BoardLastMoveColorPicker().Color(JsonUiColor(Object(colors, L"last_move"), Color(board_presentation_.last_move)));
        BoardSelectionColorPicker().Color(JsonUiColor(Object(colors, L"selection"), Color(board_presentation_.selection)));
        BoardLegalMoveColorPicker().Color(JsonUiColor(Object(colors, L"legal_move"), Color(board_presentation_.legal_move)));
        populating_customization_ = false;
    }

    void MainWindow::LoadPieceThemeEditor(JsonObject const& theme)
    {
        populating_customization_ = true;
        PieceThemeNameBox().Text(String(theme, L"display_name"));
        PieceThemeIdBox().Text(String(theme, L"id"));
        PieceThemeIdBox().IsEnabled(false);
        PieceThemeProviderBox().IsEnabled(false);
        SelectComboTag(PieceThemeProviderBox(), String(theme, L"provider"));
        PopulateBaseThemes(false);
        SelectComboTag(PieceBaseThemeBox(), String(theme, L"base_theme"));
        auto const adjustment = Object(theme, L"adjustment");
        PieceHueBox().Value(adjustment ? adjustment.GetNamedNumber(L"hue_degrees", 0) : 0);
        PieceSaturationBox().Value(adjustment ? adjustment.GetNamedNumber(L"saturation_percent", 0) : 0);
        PieceBrightnessBox().Value(adjustment ? adjustment.GetNamedNumber(L"brightness_percent", 0) : 0);
        auto const colors = Object(theme, L"colors");
        WhitePieceColorPicker().Color(JsonUiColor(Object(colors, L"white_piece"), Color(board_presentation_.white_piece)));
        BlackPieceColorPicker().Color(JsonUiColor(Object(colors, L"black_piece"), Color(board_presentation_.black_piece)));
        PromotedMarkerColorPicker().Color(JsonUiColor(Object(colors, L"promoted_marker"), Color(board_presentation_.promoted_marker_color)));
        pending_piece_assets_ = Object(theme, L"assets");
        PieceAssetsStatus().Text(pending_piece_assets_
            ? L"Six custom SVG roles are registered with this theme."
            : L"Using assets from the base theme.");
        populating_customization_ = false;
    }

    void MainWindow::CustomBoardThemePicker_SelectionChanged(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&)
    {
        if (populating_customization_) return;
        auto const key = ComboTag(CustomBoardThemePicker());
        if (key.empty()) { ResetBoardThemeEditor(); return; }
        if (auto const themes = Array(board_customization_state_, L"board_themes"))
        {
            for (auto const& value : themes)
            {
                auto const theme = value.GetObject();
                if (CustomThemeKey(theme) == key) { LoadBoardThemeEditor(theme); return; }
            }
        }
    }

    void MainWindow::CustomPieceThemePicker_SelectionChanged(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&)
    {
        if (populating_customization_) return;
        auto const key = ComboTag(CustomPieceThemePicker());
        if (key.empty()) { ResetPieceThemeEditor(); return; }
        if (auto const themes = Array(board_customization_state_, L"piece_themes"))
        {
            for (auto const& value : themes)
            {
                auto const theme = value.GetObject();
                if (CustomThemeKey(theme) == key) { LoadPieceThemeEditor(theme); return; }
            }
        }
    }

    void MainWindow::BoardThemeProviderBox_SelectionChanged(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&)
    {
        if (!populating_customization_) PopulateBaseThemes(true);
    }

    void MainWindow::PieceThemeProviderBox_SelectionChanged(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::Controls::SelectionChangedEventArgs const&)
    {
        if (!populating_customization_) PopulateBaseThemes(false);
    }

    void MainWindow::NewBoardTheme_Click(
        Windows::Foundation::IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        populating_customization_ = true;
        CustomBoardThemePicker().SelectedIndex(0);
        populating_customization_ = false;
        ResetBoardThemeEditor();
    }

    void MainWindow::NewPieceTheme_Click(
        Windows::Foundation::IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        populating_customization_ = true;
        CustomPieceThemePicker().SelectedIndex(0);
        populating_customization_ = false;
        ResetPieceThemeEditor();
    }

    void MainWindow::SaveBoardTheme_Click(
        Windows::Foundation::IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        auto const name = BoardThemeNameBox().Text();
        auto const id = BoardThemeIdBox().Text();
        auto const provider = ComboTag(BoardThemeProviderBox());
        auto const base = ComboTag(BoardBaseThemeBox());
        if (name.empty() || name.size() > 128 || !IsStableThemeId(id)
            || provider.empty() || base.empty())
        {
            AppearanceInfoBar().Severity(InfoBarSeverity::Error);
            AppearanceInfoBar().Message(L"Enter a name and an identifier using lowercase letters, digits, or hyphens.");
            AppearanceInfoBar().IsOpen(true);
            return;
        }
        JsonObject adjustment;
        adjustment.Insert(L"hue_degrees", JsonNumber(BoardHueBox().Value()));
        adjustment.Insert(L"saturation_percent", JsonNumber(BoardSaturationBox().Value()));
        adjustment.Insert(L"brightness_percent", JsonNumber(BoardBrightnessBox().Value()));
        JsonObject colors;
        colors.Insert(L"light_square", JsonColor(BoardLightColorPicker().Color()));
        colors.Insert(L"dark_square", JsonColor(BoardDarkColorPicker().Color()));
        colors.Insert(L"last_move", JsonColor(BoardLastMoveColorPicker().Color()));
        colors.Insert(L"selection", JsonColor(BoardSelectionColorPicker().Color()));
        colors.Insert(L"legal_move", JsonColor(BoardLegalMoveColorPicker().Color()));
        JsonObject theme;
        theme.Insert(L"provider", JsonString(provider)); theme.Insert(L"id", JsonString(id));
        theme.Insert(L"display_name", JsonString(name)); theme.Insert(L"base_theme", JsonString(base));
        theme.Insert(L"adjustment", adjustment); theme.Insert(L"colors", colors);
        JsonObject command;
        command.Insert(L"type", JsonString(L"register_custom_board_theme"));
        command.Insert(L"theme", theme);
        pending_customization_request_id_ = SendCommand(command);
        customization_edit_pending_ = true;
    }

    void MainWindow::SavePieceTheme_Click(
        Windows::Foundation::IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        auto const name = PieceThemeNameBox().Text();
        auto const id = PieceThemeIdBox().Text();
        auto const provider = ComboTag(PieceThemeProviderBox());
        auto const base = ComboTag(PieceBaseThemeBox());
        if (name.empty() || name.size() > 128 || !IsStableThemeId(id)
            || provider.empty() || base.empty())
        {
            AppearanceInfoBar().Severity(InfoBarSeverity::Error);
            AppearanceInfoBar().Message(L"Enter a name and an identifier using lowercase letters, digits, or hyphens.");
            AppearanceInfoBar().IsOpen(true);
            return;
        }
        JsonObject adjustment;
        adjustment.Insert(L"hue_degrees", JsonNumber(PieceHueBox().Value()));
        adjustment.Insert(L"saturation_percent", JsonNumber(PieceSaturationBox().Value()));
        adjustment.Insert(L"brightness_percent", JsonNumber(PieceBrightnessBox().Value()));
        JsonObject colors;
        colors.Insert(L"white_piece", JsonColor(WhitePieceColorPicker().Color()));
        colors.Insert(L"black_piece", JsonColor(BlackPieceColorPicker().Color()));
        colors.Insert(L"promoted_marker", JsonColor(PromotedMarkerColorPicker().Color()));
        JsonObject theme;
        theme.Insert(L"provider", JsonString(provider)); theme.Insert(L"id", JsonString(id));
        theme.Insert(L"display_name", JsonString(name)); theme.Insert(L"base_theme", JsonString(base));
        theme.Insert(L"adjustment", adjustment); theme.Insert(L"colors", colors);
        if (pending_piece_assets_) theme.Insert(L"assets", pending_piece_assets_);
        else theme.Insert(L"assets", JsonValue::CreateNullValue());
        JsonObject command;
        command.Insert(L"type", JsonString(L"register_custom_piece_theme"));
        command.Insert(L"theme", theme);
        pending_customization_request_id_ = SendCommand(command);
        customization_edit_pending_ = true;
    }

    void MainWindow::RemoveBoardTheme_Click(
        Windows::Foundation::IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        auto const [provider, theme] = SplitThemeKey(ComboTag(CustomBoardThemePicker()));
        if (provider.empty() || theme.empty()) return;
        JsonObject command; command.Insert(L"type", JsonString(L"remove_custom_board_theme"));
        command.Insert(L"provider", JsonString(provider)); command.Insert(L"theme", JsonString(theme));
        pending_customization_request_id_ = SendCommand(command);
        customization_edit_pending_ = true;
    }

    void MainWindow::RemovePieceTheme_Click(
        Windows::Foundation::IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        auto const [provider, theme] = SplitThemeKey(ComboTag(CustomPieceThemePicker()));
        if (provider.empty() || theme.empty()) return;
        JsonObject command; command.Insert(L"type", JsonString(L"remove_custom_piece_theme"));
        command.Insert(L"provider", JsonString(provider)); command.Insert(L"theme", JsonString(theme));
        pending_customization_request_id_ = SendCommand(command);
        customization_edit_pending_ = true;
    }

    void MainWindow::ClearPieceAssets_Click(
        Windows::Foundation::IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        pending_piece_assets_ = nullptr;
        PieceAssetsStatus().Text(L"Using assets from the base theme.");
    }

    void MainWindow::ImportPieceSvgFolder_Click(
        Windows::Foundation::IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        ImportPieceSvgFolderAsync();
    }

    winrt::fire_and_forget MainWindow::ImportPieceSvgFolderAsync()
    {
        auto lifetime = get_strong();
        try
        {
            Windows::Storage::Pickers::FolderPicker picker;
            picker.FileTypeFilter().Append(L"*");
            HWND hwnd = nullptr;
            Microsoft::UI::Xaml::Window window = *this;
            check_hresult(window.as<::IWindowNative>()->get_WindowHandle(&hwnd));
            check_hresult(picker.as<::IInitializeWithWindow>()->Initialize(hwnd));
            auto const folder = co_await picker.PickSingleFolderAsync();
            if (!folder) co_return;
            static std::array<wchar_t const*, 6> const roles{
                L"pawn", L"knight", L"bishop", L"rook", L"queen", L"king" };
            JsonArray pieces;
            for (auto const role : roles)
            {
                auto const file = co_await folder.GetFileAsync(hstring(role) + L".svg");
                auto const properties = co_await file.GetBasicPropertiesAsync();
                if (properties.Size() == 0 || properties.Size() > 65'536)
                {
                    throw std::runtime_error("SVG files must contain between 1 and 65536 bytes");
                }
                auto const svg = co_await Windows::Storage::FileIO::ReadTextAsync(file);
                JsonObject asset;
                asset.Insert(L"kind", JsonString(L"svg"));
                asset.Insert(L"value", JsonString(svg));
                asset.Insert(L"tintable", JsonBool(true));
                JsonObject piece;
                piece.Insert(L"role", JsonString(role));
                piece.Insert(L"asset", asset);
                pieces.Append(piece);
            }
            JsonObject assets;
            assets.Insert(L"pieces", pieces);
            pending_piece_assets_ = assets;
            PieceAssetsStatus().Text(L"Imported pawn, knight, bishop, rook, queen, and king SVG files.");
        }
        catch (winrt::hresult_error const& error)
        {
            PieceAssetsStatus().Text(L"Import failed: " + error.message());
        }
        catch (std::exception const& error)
        {
            PieceAssetsStatus().Text(L"Import failed: " + winrt::to_hstring(error.what()));
        }
    }

    void MainWindow::SaveCustomizationState(JsonObject const& state)
    {
        try
        {
            auto const path = CustomizationPath();
            if (path.empty()) return;
            auto const utf8 = winrt::to_string(state.Stringify());
            std::ofstream output(path, std::ios::binary | std::ios::trunc);
            output.write(utf8.data(), static_cast<std::streamsize>(utf8.size()));
        }
        catch (...)
        {
            ::LibChess::Windows::DiagnosticLog::Write(L"appearance", L"Could not save the theme library.");
        }
    }

    void MainWindow::RestoreCustomizationState()
    {
        try
        {
            auto const path = CustomizationPath();
            if (path.empty() || !std::filesystem::exists(path))
            {
                if (board_customization_state_) SaveCustomizationState(board_customization_state_);
                return;
            }
            auto const size = std::filesystem::file_size(path);
            if (size == 0 || size > 32ull * 1024ull * 1024ull) return;
            std::ifstream input(path, std::ios::binary);
            std::string utf8(static_cast<std::size_t>(size), '\0');
            input.read(utf8.data(), static_cast<std::streamsize>(utf8.size()));
            auto const state = JsonObject::Parse(winrt::to_hstring(utf8));
            JsonObject command;
            command.Insert(L"type", JsonString(L"load_board_customization_state"));
            command.Insert(L"state", state);
            pending_customization_request_id_ = SendCommand(command);
        }
        catch (...)
        {
            ::LibChess::Windows::DiagnosticLog::Write(L"appearance", L"Could not restore the saved theme library.");
        }
    }

    void MainWindow::ApplyBoardChrome()
    {
        auto const& metrics = board_presentation_.board_metrics;
        auto const radius = static_cast<double>(metrics.corner_radius);
        BoardOutline().CornerRadius(CornerRadius{ radius, radius, radius, radius });
        BoardOutline().BorderThickness(Thickness{
            static_cast<double>(metrics.border_width),
            static_cast<double>(metrics.border_width),
            static_cast<double>(metrics.border_width),
            static_cast<double>(metrics.border_width),
        });
        BoardOutline().BorderBrush(CreateBrush(Color(board_presentation_.border)));
        auto const maximum_extent = static_cast<double>(metrics.maximum_extent)
            * static_cast<double>(board_zoom_scale_percent_) / 100.0;
        BoardViewbox().MaxWidth(maximum_extent);
        BoardViewbox().MaxHeight(maximum_extent);
        ReviewBoardViewbox().MaxWidth(maximum_extent);
        ReviewBoardViewbox().MaxHeight(maximum_extent);

        auto const visual = Microsoft::UI::Xaml::Hosting::ElementCompositionPreview::
            GetElementVisual(BoardClipHost());
        auto const compositor = visual.Compositor();
        auto const clip = compositor.CreateRectangleClip();
        clip.Right(640.0f);
        clip.Bottom(640.0f);
        auto const corner = Windows::Foundation::Numerics::float2{
            static_cast<float>(radius), static_cast<float>(radius) };
        clip.TopLeftRadius(corner);
        clip.TopRightRadius(corner);
        clip.BottomLeftRadius(corner);
        clip.BottomRightRadius(corner);
        visual.Clip(clip);

        auto const shadow = compositor.CreateDropShadow();
        shadow.Color(Color(board_presentation_.shadow));
        shadow.BlurRadius(static_cast<float>(metrics.shadow_radius));
        shadow.Offset({ 0.0f, static_cast<float>(metrics.shadow_offset_y), 0.0f });
        auto const shadow_visual = compositor.CreateLayerVisual();
        shadow_visual.RelativeSizeAdjustment({ 1.0f, 1.0f });
        shadow_visual.Shadow(shadow);
        auto const shadow_shape_visual = compositor.CreateShapeVisual();
        shadow_shape_visual.Size({ 640.0f, 640.0f });
        auto const shadow_geometry = compositor.CreateRoundedRectangleGeometry();
        shadow_geometry.Size({ 640.0f, 640.0f });
        shadow_geometry.CornerRadius(corner);
        auto const shadow_shape = compositor.CreateSpriteShape(shadow_geometry);
        shadow_shape.FillBrush(compositor.CreateColorBrush(Windows::UI::Colors::White()));
        shadow_shape_visual.Shapes().Append(shadow_shape);
        shadow_visual.Children().InsertAtTop(shadow_shape_visual);
        Microsoft::UI::Xaml::Hosting::ElementCompositionPreview::SetElementChildVisual(
            BoardShadowHost(), shadow_visual);
    }

    Microsoft::UI::Xaml::Media::Imaging::SvgImageSource MainWindow::SvgSource(
        ::LibChess::Windows::Wire::BoardAsset const& asset,
        ::LibChess::Windows::Wire::RgbaColor const& tint)
    {
        auto const svg = asset.tintable ? TintSvg(asset.value, tint) : asset.value;
        auto const key = (asset.tintable ? HexColor(tint) : std::wstring(L"original"))
            + L"\n" + std::wstring(svg);
        if (auto const found = svg_sources_.find(key); found != svg_sources_.end())
        {
            return found->second;
        }
        Microsoft::UI::Xaml::Media::Imaging::SvgImageSource source;
        svg_sources_.insert_or_assign(key, source);
        LoadSvgAsync(source, svg);
        return source;
    }

    winrt::fire_and_forget MainWindow::LoadSvgAsync(
        Microsoft::UI::Xaml::Media::Imaging::SvgImageSource source,
        hstring svg)
    {
        auto lifetime = get_strong();
        try
        {
            Windows::Storage::Streams::InMemoryRandomAccessStream stream;
            Windows::Storage::Streams::DataWriter writer(stream);
            writer.UnicodeEncoding(Windows::Storage::Streams::UnicodeEncoding::Utf8);
            writer.WriteString(svg);
            co_await writer.StoreAsync();
            co_await writer.FlushAsync();
            writer.DetachStream();
            stream.Seek(0);
            static_cast<void>(co_await source.SetSourceAsync(stream));
        }
        catch (...)
        {
        }
    }

    FrameworkElement MainWindow::CreatePieceVisual(
        ::LibChess::Windows::Wire::BoardPiece const& piece,
        double square_extent)
    {
        auto const tint = piece.color == L"white"
            ? board_presentation_.white_piece
            : board_presentation_.black_piece;
        auto const shadow_tint = piece.color == L"white"
            ? board_presentation_.white_piece_shadow
            : board_presentation_.black_piece_shadow;
        auto const extent = square_extent
            * static_cast<double>(board_presentation_.piece_metrics.scale_percent) / 100.0;
        auto const key = std::wstring(piece.color) + L"/" + std::wstring(piece.role);
        auto const asset = board_presentation_.assets.find(key);
        auto make_visual = [&](::LibChess::Windows::Wire::RgbaColor const& color)
            -> FrameworkElement
        {
            if (asset != board_presentation_.assets.end() && asset->second.kind == L"svg")
            {
                Image image;
                image.Width(extent);
                image.Height(extent);
                image.Stretch(Media::Stretch::Uniform);
                image.Opacity(static_cast<double>(color.alpha) / 255.0);
                image.Source(SvgSource(asset->second, color));
                image.IsHitTestVisible(false);
                return image;
            }
            TextBlock text;
            text.FontFamily(Media::FontFamily(L"Segoe UI Symbol"));
            text.FontSize(extent);
            text.Text(asset != board_presentation_.assets.end()
                && asset->second.kind == L"text_glyph"
                ? asset->second.value
                : PieceFallback(piece.color, piece.role));
            text.Foreground(CreateBrush(Color(color)));
            text.HorizontalAlignment(HorizontalAlignment::Center);
            text.VerticalAlignment(VerticalAlignment::Center);
            text.IsHitTestVisible(false);
            return text;
        };

        Grid layers;
        layers.Width(extent);
        layers.Height(extent);
        layers.HorizontalAlignment(HorizontalAlignment::Center);
        layers.VerticalAlignment(VerticalAlignment::Center);
        layers.IsHitTestVisible(false);
        auto const can_tint_shadow = asset == board_presentation_.assets.end()
            || asset->second.kind != L"svg" || asset->second.tintable;
        if (shadow_tint.alpha > 0 && can_tint_shadow)
        {
            auto shadow = make_visual(shadow_tint);
            auto const shadow_radius = static_cast<double>(
                board_presentation_.piece_metrics.shadow_radius_tenths) / 10.0;
            auto const shadow_scale = 1.0 + shadow_radius / (std::max)(1.0, extent);
            shadow.RenderTransformOrigin({ 0.5, 0.5 });
            Media::CompositeTransform offset;
            offset.ScaleX(shadow_scale);
            offset.ScaleY(shadow_scale);
            offset.TranslateY(static_cast<double>(
                board_presentation_.piece_metrics.shadow_offset_y_tenths) / 10.0);
            shadow.RenderTransform(offset);
            layers.Children().Append(shadow);
        }
        layers.Children().Append(make_visual(tint));
        return layers;
    }

    void MainWindow::AnimatePiece(
        FrameworkElement const& piece,
        hstring const& from,
        hstring const& to,
        bool black_perspective)
    {
        auto const duration_millis = board_presentation_.motion.piece_move.duration_millis;
        if (duration_millis == 0 || from == to)
        {
            return;
        }
        auto const [from_row, from_column] = DisplayLocation(from, black_perspective);
        auto const [to_row, to_column] = DisplayLocation(to, black_perspective);
        try
        {
            if (!Windows::UI::ViewManagement::UISettings().AnimationsEnabled())
            {
                return;
            }
        }
        catch (...)
        {
        }

        auto const translation = Windows::Foundation::Numerics::float3{
            static_cast<float>(from_column - to_column) * 80.0f,
            static_cast<float>(from_row - to_row) * 80.0f,
            0.0f,
        };
        Microsoft::UI::Xaml::Hosting::ElementCompositionPreview::
            SetIsTranslationEnabled(piece, true);
        auto const visual = Microsoft::UI::Xaml::Hosting::ElementCompositionPreview::
            GetElementVisual(piece);
        auto const compositor = visual.Compositor();
        auto const animation = compositor.CreateVector3KeyFrameAnimation();
        animation.InsertKeyFrame(0.0f, translation);
        if (board_presentation_.motion.piece_move.curve == L"linear")
        {
            animation.InsertKeyFrame(1.0f, { 0.0f, 0.0f, 0.0f });
        }
        else
        {
            auto const easing = compositor.CreateCubicBezierEasingFunction(
                { 0.16f, 1.0f }, { 0.3f, 1.0f });
            animation.InsertKeyFrame(1.0f, { 0.0f, 0.0f, 0.0f }, easing);
        }
        auto const fast_duration = (std::min)(
            std::uint32_t{ 125 }, (std::max)(std::uint32_t{ 70 }, duration_millis * 2 / 3));
        animation.Duration(Windows::Foundation::TimeSpan{
            static_cast<std::int64_t>(fast_duration) * 10'000 });
        animation.Target(L"Translation");
        piece.StartAnimation(animation);
    }

    void MainWindow::AnimatePieceAppearance(FrameworkElement const& piece)
    {
        auto const duration_millis = board_presentation_.motion.piece_move.duration_millis;
        if (duration_millis == 0)
        {
            return;
        }
        try
        {
            if (!Windows::UI::ViewManagement::UISettings().AnimationsEnabled())
            {
                return;
            }
        }
        catch (...)
        {
        }
        auto const start_scale = static_cast<double>(
            board_presentation_.motion.piece_appearance_scale_percent) / 100.0;
        piece.RenderTransformOrigin({ 0.5, 0.5 });
        Media::CompositeTransform transform;
        piece.RenderTransform(transform);
        Media::Animation::Storyboard storyboard;
        auto const duration = Duration{ Windows::Foundation::TimeSpan{
            static_cast<std::int64_t>(duration_millis) * 10'000 } };
        auto append = [&](hstring const& property, double from)
        {
            Media::Animation::DoubleAnimation animation;
            animation.From(from);
            animation.To(1.0);
            animation.Duration(duration);
            Media::Animation::CubicEase easing;
            easing.EasingMode(Media::Animation::EasingMode::EaseOut);
            animation.EasingFunction(easing);
            Media::Animation::Storyboard::SetTarget(animation, transform);
            Media::Animation::Storyboard::SetTargetProperty(animation, property);
            storyboard.Children().Append(animation);
        };
        append(L"ScaleX", start_scale);
        append(L"ScaleY", start_scale);
        if (board_presentation_.motion.fade_piece_appearance)
        {
            auto const target_opacity = piece.Opacity();
            Media::Animation::DoubleAnimation opacity;
            opacity.From(0.0);
            opacity.To(target_opacity);
            opacity.Duration(duration);
            Media::Animation::Storyboard::SetTarget(opacity, piece);
            Media::Animation::Storyboard::SetTargetProperty(opacity, L"Opacity");
            storyboard.Children().Append(opacity);
        }
        active_storyboards_.push_back(storyboard);
        if (active_storyboards_.size() > 64)
        {
            active_storyboards_.erase(
                active_storyboards_.begin(), active_storyboards_.begin() + 32);
        }
        storyboard.Begin();
    }

    void MainWindow::ApplyRoundedClip(FrameworkElement const& element, double extent)
    {
        if (!element) return;
        auto const visual = Microsoft::UI::Xaml::Hosting::ElementCompositionPreview::
            GetElementVisual(element);
        auto const compositor = visual.Compositor();
        auto const clip = compositor.CreateRectangleClip();
        clip.Right(static_cast<float>(extent));
        clip.Bottom(static_cast<float>(extent));
        auto const radius = static_cast<float>(board_presentation_.board_metrics.corner_radius)
            * static_cast<float>(extent / 640.0);
        auto const corner = Windows::Foundation::Numerics::float2{ radius, radius };
        clip.TopLeftRadius(corner); clip.TopRightRadius(corner);
        clip.BottomLeftRadius(corner); clip.BottomRightRadius(corner);
        visual.Clip(clip);
    }

    void MainWindow::RenderBoardInto(
        Grid const& grid,
        std::optional<::LibChess::Windows::Wire::BoardState> const& board,
        bool black_perspective,
        double square_extent,
        bool interactive)
    {
        if (!grid || !board) return;
        grid.Children().Clear();
        grid.RowDefinitions().Clear();
        grid.ColumnDefinitions().Clear();
        for (int index = 0; index < 8; ++index)
        {
            RowDefinition row; row.Height(GridLength{ 1, GridUnitType::Star });
            ColumnDefinition column; column.Width(GridLength{ 1, GridUnitType::Star });
            grid.RowDefinitions().Append(row); grid.ColumnDefinitions().Append(column);
        }
        auto const square_style = Application::Current().Resources()
            .Lookup(box_value(L"BoardSquareButtonStyle")).as<Style>();
        for (int row = 0; row < 8; ++row)
        {
            for (int column = 0; column < 8; ++column)
            {
                auto const file_index = black_perspective ? 7 - column : column;
                auto const rank = black_perspective ? row + 1 : 8 - row;
                std::wstring square{ static_cast<wchar_t>(L'a' + file_index) };
                square += std::to_wstring(rank);
                hstring const square_id(square);
                auto const light = (file_index + rank) % 2 == 0;
                auto const piece = std::find_if(board->pieces.begin(), board->pieces.end(),
                    [&](auto const& candidate) { return candidate.square == square_id; });
                auto const legal = std::any_of(board->legal_moves.begin(), board->legal_moves.end(),
                    [&](auto const& move)
                    {
                        return move.to == square_id
                            && ((!selected_square_.empty() && move.from == selected_square_)
                                || (!selected_drop_.empty() && move.drop == selected_drop_));
                    });
                Button button;
                button.Style(square_style);
                button.Tag(box_value(square_id));
                button.Background(CreateBrush(Color(
                    light ? board_presentation_.light_square : board_presentation_.dark_square)));
                button.IsHitTestVisible(interactive);
                if (interactive) button.Click({ this, &MainWindow::Square_Click });
                Grid content;
                if (board->last_move
                    && (board->last_move->from == square_id || board->last_move->to == square_id))
                {
                    Shapes::Rectangle overlay;
                    overlay.Fill(CreateBrush(Color(board_presentation_.last_move)));
                    overlay.IsHitTestVisible(false); content.Children().Append(overlay);
                }
                if (interactive && selected_square_ == square_id)
                {
                    Shapes::Rectangle overlay;
                    overlay.Fill(CreateBrush(Color(board_presentation_.selection)));
                    overlay.IsHitTestVisible(false); content.Children().Append(overlay);
                }
                if (legal)
                {
                    Shapes::Ellipse marker;
                    marker.HorizontalAlignment(HorizontalAlignment::Center);
                    marker.VerticalAlignment(VerticalAlignment::Center);
                    marker.IsHitTestVisible(false);
                    if (piece == board->pieces.end())
                    {
                        auto const extent = square_extent
                            * board_presentation_.board_metrics.destination_dot_scale_percent / 100.0;
                        marker.Width(extent); marker.Height(extent);
                        marker.Fill(CreateBrush(Color(board_presentation_.legal_move)));
                    }
                    else
                    {
                        auto const inset = square_extent
                            * board_presentation_.board_metrics.destination_ring_inset_percent / 100.0;
                        marker.Width(square_extent - inset * 2.0);
                        marker.Height(square_extent - inset * 2.0);
                        marker.Stroke(CreateBrush(Color(board_presentation_.legal_move)));
                        marker.StrokeThickness(square_extent
                            * board_presentation_.board_metrics.destination_ring_width_percent / 100.0);
                        Canvas::SetZIndex(marker, 20);
                    }
                    content.Children().Append(marker);
                }
                if (piece != board->pieces.end())
                {
                    auto visual = CreatePieceVisual(*piece, square_extent);
                    content.Children().Append(visual);
                    if (interactive)
                    {
                        auto const origin = piece_animation_origins_.find(std::wstring(square_id));
                        if (origin != piece_animation_origins_.end())
                        {
                            Canvas::SetZIndex(button, 10);
                            AnimatePiece(visual, origin->second, square_id, black_perspective);
                        }
                    }
                }
                auto const coordinate_color = light
                    ? board_presentation_.coordinate_on_light : board_presentation_.coordinate_on_dark;
                auto const coordinate_size = square_extent
                    * board_presentation_.board_metrics.coordinate_font_scale_percent / 100.0;
                auto const inset = board_presentation_.board_metrics.coordinate_inset
                    * square_extent / 80.0;
                if (column == 0)
                {
                    TextBlock label; label.Text(winrt::to_hstring(rank)); label.FontSize(coordinate_size);
                    label.FontWeight(Windows::UI::Text::FontWeights::Bold());
                    label.Foreground(CreateBrush(Color(coordinate_color)));
                    label.HorizontalAlignment(HorizontalAlignment::Left);
                    label.VerticalAlignment(VerticalAlignment::Top);
                    label.Margin(Thickness{ inset, inset, 0, 0 }); label.IsHitTestVisible(false);
                    content.Children().Append(label);
                }
                if (row == 7)
                {
                    wchar_t const text[]{ static_cast<wchar_t>(L'a' + file_index), L'\0' };
                    TextBlock label; label.Text(text); label.FontSize(coordinate_size);
                    label.FontWeight(Windows::UI::Text::FontWeights::Bold());
                    label.Foreground(CreateBrush(Color(coordinate_color)));
                    label.HorizontalAlignment(HorizontalAlignment::Right);
                    label.VerticalAlignment(VerticalAlignment::Bottom);
                    label.Margin(Thickness{ 0, 0, inset, inset }); label.IsHitTestVisible(false);
                    content.Children().Append(label);
                }
                button.Content(content);
                Grid::SetRow(button, row); Grid::SetColumn(button, column);
                grid.Children().Append(button);
            }
        }
    }

    void MainWindow::RenderAppearancePreview()
    {
        ::LibChess::Windows::Wire::BoardState board;
        static std::array<wchar_t const*, 8> const roles{
            L"rook", L"knight", L"bishop", L"queen", L"king", L"bishop", L"knight", L"rook" };
        for (int file = 0; file < 8; ++file)
        {
            wchar_t const letter = static_cast<wchar_t>(L'a' + file);
            board.pieces.push_back({ hstring(std::wstring{ letter } + L"8"), L"black", roles[file], false });
            board.pieces.push_back({ hstring(std::wstring{ letter } + L"7"), L"black", L"pawn", false });
            board.pieces.push_back({ hstring(std::wstring{ letter } + L"2"), L"white", L"pawn", false });
            board.pieces.push_back({ hstring(std::wstring{ letter } + L"1"), L"white", roles[file], false });
        }
        RenderBoardInto(AppearancePreviewGrid(), board, false, 50.0, false);
        auto const radius = static_cast<double>(board_presentation_.board_metrics.corner_radius) * 400.0 / 640.0;
        AppearancePreviewOutline().CornerRadius(CornerRadius{ radius, radius, radius, radius });
        AppearancePreviewOutline().BorderBrush(CreateBrush(Color(board_presentation_.border)));
        ApplyRoundedClip(AppearancePreviewClipHost(), 400.0);
    }

    void MainWindow::RenderFloatingBoard()
    {
        if (!floating_board_window_ || !floating_board_grid_) return;
        if (!live_game_ || (live_game_->status != L"created" && live_game_->status != L"started"))
        {
            SaveFloatingBoardFrame();
            floating_board_window_.Close();
            return;
        }
        RenderBoardInto(floating_board_grid_, live_game_->board,
            live_game_->player_color == L"black", 80.0, true);
        ApplyRoundedClip(floating_board_grid_, 640.0);
        auto const menu = BuildFloatingBoardMenu();
        floating_board_grid_.ContextFlyout(menu);
    }

    MenuFlyout MainWindow::BuildFloatingBoardMenu()
    {
        MenuFlyout menu;
        if (!live_game_) return menu;
        auto append = [&](hstring const& label, auto&& action, bool enabled = true)
        {
            MenuFlyoutItem item;
            item.Text(label);
            item.IsEnabled(enabled);
            item.Click(std::forward<decltype(action)>(action));
            menu.Items().Append(item);
        };
        auto const busy = !pending_move_request_id_.empty() || !pending_game_action_request_id_.empty();
        auto const own_draw = live_game_->player_color == L"white"
            ? live_game_->white_draw_offer : live_game_->black_draw_offer;
        auto const own_takeback = live_game_->player_color == L"white"
            ? live_game_->white_takeback_offer : live_game_->black_takeback_offer;
        if (incoming_offer_ == L"draw")
        {
            append(L"Accept draw", [this](auto const&, auto const&) { SendGameAction(L"accept_draw"); }, !busy);
            append(L"Decline draw", [this](auto const&, auto const&) { SendGameAction(L"decline_draw"); }, !busy);
        }
        else if (incoming_offer_ == L"takeback")
        {
            append(L"Accept takeback", [this](auto const&, auto const&) { SendGameAction(L"accept_takeback"); }, !busy);
            append(L"Decline takeback", [this](auto const&, auto const&) { SendGameAction(L"decline_takeback"); }, !busy);
        }
        else
        {
            append(own_draw ? L"Draw offered" : L"Offer draw",
                [this](auto const&, auto const&) { SendGameAction(L"offer_draw"); }, !busy && !own_draw);
            append(own_takeback ? L"Takeback requested" : L"Request takeback",
                [this](auto const&, auto const&) { SendGameAction(L"offer_takeback"); }, !busy && !own_takeback);
        }
        if (live_game_->opponent_gone && live_game_->claim_win_in_seconds.value_or(1) == 0)
        {
            append(L"Claim victory", [this](auto const&, auto const&) { SendGameAction(L"claim_victory"); }, !busy);
        }
        append(L"Claim draw", [this](auto const&, auto const&) { SendGameAction(L"claim_draw"); }, !busy);
        MenuFlyoutSeparator game_separator;
        menu.Items().Append(game_separator);
        append(live_game_->board.ply < 2 ? L"Abort…" : L"Resign…",
            [this](auto const&, auto const&) { ConfirmTerminationAsync(); }, !busy);
        MenuFlyoutSeparator window_separator;
        menu.Items().Append(window_separator);
        append(L"Show full game", [this](auto const&, auto const&)
        {
            if (live_game_) SelectNavigationForGame(live_game_->id);
            Microsoft::UI::Xaml::Window window = *this;
            window.Activate();
        });
        if (!live_game_->url.empty())
        {
            append(L"Open on service", [this](auto const&, auto const&) { OpenGameAsync(); });
        }
        append(L"Close floating board", [this](auto const&, auto const&)
        {
            SaveFloatingBoardFrame();
            if (floating_board_window_) floating_board_window_.Close();
        });
        return menu;
    }

    LRESULT CALLBACK MainWindow::FloatingBoardSubclassProc(
        HWND hwnd,
        UINT message,
        WPARAM wparam,
        LPARAM lparam,
        UINT_PTR subclass_id,
        DWORD_PTR reference_data)
    {
        auto* self = reinterpret_cast<MainWindow*>(reference_data);
        if (!self)
        {
            return DefSubclassProc(hwnd, message, wparam, lparam);
        }

        switch (message)
        {
        case WM_NCCALCSIZE:
            // Make the whole HWND client area. This removes both the caption and
            // the otherwise-reserved resize-frame strip while retaining resize
            // semantics through WM_NCHITTEST below.
            return 0;
        case WM_NCACTIVATE:
            return TRUE;
        case WM_ERASEBKGND:
            return 1;
        case WM_NCHITTEST:
        {
            RECT rect{};
            GetWindowRect(hwnd, &rect);
            auto const dpi = GetDpiForWindow(hwnd);
            auto const resize_inset = (std::max)(6,
                GetSystemMetricsForDpi(SM_CXSIZEFRAME, dpi)
                    + GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi));
            POINT const point{ GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam) };
            auto const left = point.x >= rect.left && point.x < rect.left + resize_inset;
            auto const right = point.x < rect.right && point.x >= rect.right - resize_inset;
            auto const top = point.y >= rect.top && point.y < rect.top + resize_inset;
            auto const bottom = point.y < rect.bottom && point.y >= rect.bottom - resize_inset;
            if (top && left) return HTTOPLEFT;
            if (top && right) return HTTOPRIGHT;
            if (bottom && left) return HTBOTTOMLEFT;
            if (bottom && right) return HTBOTTOMRIGHT;
            if (left) return HTLEFT;
            if (right) return HTRIGHT;
            if (top) return HTTOP;
            if (bottom) return HTBOTTOM;
            return HTCLIENT;
        }
        case WM_GETMINMAXINFO:
        {
            auto* limits = reinterpret_cast<MINMAXINFO*>(lparam);
            auto const dpi = GetDpiForWindow(hwnd);
            auto const minimum = static_cast<LONG>(240.0 * dpi / 96.0);
            auto const maximum = static_cast<LONG>(960.0 * dpi / 96.0);
            limits->ptMinTrackSize = { minimum, minimum };
            limits->ptMaxTrackSize = { maximum, maximum };
            return 0;
        }
        case WM_ENTERSIZEMOVE:
            GetWindowRect(hwnd, &self->floating_board_resize_origin_window_);
            break;
        case WM_SIZING:
        {
            auto* rect = reinterpret_cast<RECT*>(lparam);
            auto origin = self->floating_board_resize_origin_window_;
            if (origin.right <= origin.left || origin.bottom <= origin.top)
            {
                GetWindowRect(hwnd, &origin);
            }
            auto const proposed_width = rect->right - rect->left;
            auto const proposed_height = rect->bottom - rect->top;
            auto const origin_width = origin.right - origin.left;
            auto const origin_height = origin.bottom - origin.top;
            auto const horizontal = wparam == WMSZ_LEFT || wparam == WMSZ_RIGHT;
            auto const vertical = wparam == WMSZ_TOP || wparam == WMSZ_BOTTOM;
            auto const use_width = horizontal || (!vertical
                && std::abs(proposed_width - origin_width)
                    >= std::abs(proposed_height - origin_height));
            auto const dpi = GetDpiForWindow(hwnd);
            auto const minimum = static_cast<LONG>(240.0 * dpi / 96.0);
            auto const maximum = static_cast<LONG>(960.0 * dpi / 96.0);
            auto const extent = (std::clamp)(
                use_width ? proposed_width : proposed_height, minimum, maximum);
            switch (wparam)
            {
            case WMSZ_LEFT:
                rect->left = rect->right - extent;
                rect->bottom = rect->top + extent;
                break;
            case WMSZ_RIGHT:
                rect->right = rect->left + extent;
                rect->bottom = rect->top + extent;
                break;
            case WMSZ_TOP:
                rect->top = rect->bottom - extent;
                rect->right = rect->left + extent;
                break;
            case WMSZ_BOTTOM:
                rect->bottom = rect->top + extent;
                rect->right = rect->left + extent;
                break;
            case WMSZ_TOPLEFT:
                rect->left = rect->right - extent;
                rect->top = rect->bottom - extent;
                break;
            case WMSZ_TOPRIGHT:
                rect->right = rect->left + extent;
                rect->top = rect->bottom - extent;
                break;
            case WMSZ_BOTTOMLEFT:
                rect->left = rect->right - extent;
                rect->bottom = rect->top + extent;
                break;
            case WMSZ_BOTTOMRIGHT:
                rect->right = rect->left + extent;
                rect->bottom = rect->top + extent;
                break;
            default:
                break;
            }
            return TRUE;
        }
        case WM_EXITSIZEMOVE:
            self->SaveFloatingBoardFrame();
            break;
        case WM_NCDESTROY:
            RemoveWindowSubclass(hwnd, FloatingBoardSubclassProc, subclass_id);
            if (self->floating_board_hwnd_ == hwnd)
            {
                self->floating_board_hwnd_ = nullptr;
            }
            break;
        default:
            break;
        }
        return DefSubclassProc(hwnd, message, wparam, lparam);
    }

    void MainWindow::ConfigureFloatingBoardWindow()
    {
        auto const app_window = floating_board_window_.AppWindow();
        app_window.IsShownInSwitchers(false);
        auto const presenter = app_window.Presenter().as<Microsoft::UI::Windowing::OverlappedPresenter>();
        presenter.SetBorderAndTitleBar(false, false);
        presenter.IsAlwaysOnTop(true);
        presenter.IsResizable(true);
        presenter.IsMaximizable(false);
        presenter.IsMinimizable(false);

        check_hresult(floating_board_window_.as<::IWindowNative>()->get_WindowHandle(&floating_board_hwnd_));
        HWND owner_hwnd = nullptr;
        Microsoft::UI::Xaml::Window owner = *this;
        check_hresult(owner.as<::IWindowNative>()->get_WindowHandle(&owner_hwnd));
        auto style = GetWindowLongPtrW(floating_board_hwnd_, GWL_STYLE);
        style &= ~(WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX);
        style |= WS_POPUP | WS_THICKFRAME;
        SetWindowLongPtrW(floating_board_hwnd_, GWL_STYLE, style);
        auto const extended_style = GetWindowLongPtrW(floating_board_hwnd_, GWL_EXSTYLE);
        SetWindowLongPtrW(floating_board_hwnd_, GWL_EXSTYLE,
            extended_style | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE);
        SetWindowLongPtrW(
            floating_board_hwnd_, GWLP_HWNDPARENT, reinterpret_cast<LONG_PTR>(owner_hwnd));
        check_bool(SetWindowSubclass(
            floating_board_hwnd_, FloatingBoardSubclassProc,
            FloatingBoardSubclassId, reinterpret_cast<DWORD_PTR>(this)));
        SetWindowPos(floating_board_hwnd_, nullptr, 0, 0, 0, 0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);
        DWM_WINDOW_CORNER_PREFERENCE corner = DWMWCP_ROUND;
        static_cast<void>(DwmSetWindowAttribute(
            floating_board_hwnd_, DWMWA_WINDOW_CORNER_PREFERENCE, &corner, sizeof(corner)));
        constexpr COLORREF border_color = 0xFFFFFFFE;
        static_cast<void>(DwmSetWindowAttribute(
            floating_board_hwnd_, DWMWA_BORDER_COLOR, &border_color, sizeof(border_color)));

        auto const dpi = GetDpiForWindow(owner_hwnd);
        auto const minimum = static_cast<std::int32_t>(240.0 * dpi / 96.0);
        auto const maximum = static_cast<std::int32_t>(960.0 * dpi / 96.0);
        presenter.PreferredMinimumWidth(box_value(minimum).as<Windows::Foundation::IReference<std::int32_t>>());
        presenter.PreferredMinimumHeight(box_value(minimum).as<Windows::Foundation::IReference<std::int32_t>>());
        presenter.PreferredMaximumWidth(box_value(maximum).as<Windows::Foundation::IReference<std::int32_t>>());
        presenter.PreferredMaximumHeight(box_value(maximum).as<Windows::Foundation::IReference<std::int32_t>>());

        auto extent = static_cast<std::int32_t>(460.0 * dpi / 96.0);
        try
        {
            auto const saved = std::stoi(std::wstring(ReadPreference(L"FloatingBoardExtent")));
            extent = (std::clamp)(saved, minimum, maximum);
        }
        catch (...) {}
        RECT owner_rect{};
        GetWindowRect(owner_hwnd, &owner_rect);
        MONITORINFO monitor{ sizeof(monitor) };
        GetMonitorInfoW(MonitorFromWindow(owner_hwnd, MONITOR_DEFAULTTONEAREST), &monitor);
        auto const margin = static_cast<std::int32_t>(24.0 * dpi / 96.0);
        auto x = owner_rect.right + margin;
        if (x + extent > monitor.rcWork.right - margin)
        {
            x = owner_rect.left - extent - margin;
        }
        if (x < monitor.rcWork.left + margin)
        {
            x = monitor.rcWork.right - extent - margin;
        }
        auto y = (std::clamp)(owner_rect.top, monitor.rcWork.top + margin,
            monitor.rcWork.bottom - extent - margin);
        try
        {
            auto const saved_x = std::stoi(std::wstring(ReadPreference(L"FloatingBoardX")));
            auto const saved_y = std::stoi(std::wstring(ReadPreference(L"FloatingBoardY")));
            POINT saved_point{ saved_x, saved_y };
            MONITORINFO saved_monitor{ sizeof(saved_monitor) };
            if (GetMonitorInfoW(MonitorFromPoint(saved_point, MONITOR_DEFAULTTONULL), &saved_monitor))
            {
                x = (std::clamp<int32_t>)(saved_x,
                    static_cast<int32_t>(saved_monitor.rcWork.left),
                    static_cast<int32_t>(saved_monitor.rcWork.right - extent));
                y = (std::clamp<int32_t>)(saved_y,
                    static_cast<int32_t>(saved_monitor.rcWork.top),
                    static_cast<int32_t>(saved_monitor.rcWork.bottom - extent));
            }
        }
        catch (...) {}
        app_window.MoveAndResize({ x, y, extent, extent });
        GetWindowRect(floating_board_hwnd_, &floating_board_resize_origin_window_);
    }

    void MainWindow::SaveFloatingBoardFrame()
    {
        if (!floating_board_window_) return;
        auto const app_window = floating_board_window_.AppWindow();
        auto const position = app_window.Position();
        auto const size = app_window.Size();
        WritePreference(L"FloatingBoardX", winrt::to_hstring(position.X));
        WritePreference(L"FloatingBoardY", winrt::to_hstring(position.Y));
        WritePreference(L"FloatingBoardExtent", winrt::to_hstring((std::min)(size.Width, size.Height)));
    }

    void MainWindow::FloatingBoard_PointerPressed(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::Input::PointerRoutedEventArgs const& args)
    {
        if (!live_game_ || !floating_board_root_) return;
        auto const point = args.GetCurrentPoint(floating_board_root_);
        if (!point.Properties().IsLeftButtonPressed()) return;
        auto const width = floating_board_root_.ActualWidth();
        auto const height = floating_board_root_.ActualHeight();
        if (width <= 0 || height <= 0) return;
        auto const position = point.Position();
        auto const column = (std::clamp)(static_cast<int>(position.X / width * 8.0), 0, 7);
        auto const row = (std::clamp)(static_cast<int>(position.Y / height * 8.0), 0, 7);
        auto const black = live_game_->player_color == L"black";
        auto const file_index = black ? 7 - column : column;
        auto const rank = black ? row + 1 : 8 - row;
        std::wstring square{ static_cast<wchar_t>(L'a' + file_index) };
        square += std::to_wstring(rank);
        if (std::any_of(live_game_->board.pieces.begin(), live_game_->board.pieces.end(),
            [&](auto const& piece) { return piece.square == square; })) return;
        HWND hwnd = nullptr;
        check_hresult(floating_board_window_.as<::IWindowNative>()->get_WindowHandle(&hwnd));
        GetCursorPos(&floating_board_drag_origin_cursor_);
        GetWindowRect(hwnd, &floating_board_drag_origin_window_);
        floating_board_drag_pointer_id_ = point.PointerId();
        floating_board_drag_pending_ = true;
        floating_board_drag_started_ = false;
    }

    void MainWindow::FloatingBoard_PointerMoved(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::Input::PointerRoutedEventArgs const& args)
    {
        if (!floating_board_drag_pending_ || !floating_board_root_) return;
        auto const point = args.GetCurrentPoint(floating_board_root_);
        if (point.PointerId() != floating_board_drag_pointer_id_
            || !point.Properties().IsLeftButtonPressed()) return;
        POINT cursor{};
        GetCursorPos(&cursor);
        auto const dx = cursor.x - floating_board_drag_origin_cursor_.x;
        auto const dy = cursor.y - floating_board_drag_origin_cursor_.y;
        if (!floating_board_drag_started_ && std::hypot(dx, dy) < 3.0) return;
        if (!floating_board_drag_started_)
        {
            floating_board_drag_started_ = true;
            floating_board_root_.CapturePointer(args.Pointer());
        }
        HWND hwnd = nullptr;
        check_hresult(floating_board_window_.as<::IWindowNative>()->get_WindowHandle(&hwnd));
        SetWindowPos(hwnd, HWND_TOPMOST,
            floating_board_drag_origin_window_.left + dx,
            floating_board_drag_origin_window_.top + dy,
            0, 0, SWP_NOSIZE | SWP_NOACTIVATE);
        args.Handled(true);
    }

    void MainWindow::FloatingBoard_PointerReleased(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::Input::PointerRoutedEventArgs const& args)
    {
        if (!floating_board_drag_pending_) return;
        if (floating_board_drag_started_ && floating_board_root_)
        {
            floating_board_root_.ReleasePointerCapture(args.Pointer());
            args.Handled(true);
            SaveFloatingBoardFrame();
        }
        floating_board_drag_pending_ = false;
        floating_board_drag_started_ = false;
        floating_board_drag_pointer_id_ = 0;
    }

    void MainWindow::OpenFloatingBoard()
    {
        if (!live_game_ || (live_game_->status != L"created" && live_game_->status != L"started"))
        {
            ShowMessage(L"Open a playable live game before opening the floating board.", false);
            return;
        }
        if (floating_board_window_)
        {
            RenderFloatingBoard();
            floating_board_window_.AppWindow().Show(false);
            return;
        }
        floating_board_window_ = Microsoft::UI::Xaml::Window();
        floating_board_window_.Title(L"Floating Chessboard");
        floating_board_window_.SystemBackdrop(nullptr);
        floating_board_window_.ExtendsContentIntoTitleBar(true);
        floating_board_root_ = Grid();
        floating_board_root_.Background(CreateBrush(Windows::UI::Colors::Transparent()));
        Viewbox viewbox; viewbox.Stretch(Stretch::Uniform);
        viewbox.HorizontalAlignment(HorizontalAlignment::Stretch);
        viewbox.VerticalAlignment(VerticalAlignment::Stretch);
        Grid frame; frame.Width(640); frame.Height(640);
        floating_board_grid_ = Grid();
        frame.Children().Append(floating_board_grid_);
        Border outline; outline.IsHitTestVisible(false);
        auto const radius = static_cast<double>(board_presentation_.board_metrics.corner_radius);
        outline.CornerRadius(CornerRadius{ radius, radius, radius, radius });
        outline.BorderThickness(Thickness{ 1, 1, 1, 1 });
        outline.BorderBrush(CreateBrush(Color(board_presentation_.border)));
        frame.Children().Append(outline);
        viewbox.Child(frame); floating_board_root_.Children().Append(viewbox);
        floating_board_root_.AddHandler(UIElement::PointerPressedEvent(),
            winrt::box_value<Microsoft::UI::Xaml::Input::PointerEventHandler>({
                this, &MainWindow::FloatingBoard_PointerPressed }), true);
        floating_board_root_.AddHandler(UIElement::PointerMovedEvent(),
            winrt::box_value<Microsoft::UI::Xaml::Input::PointerEventHandler>({
                this, &MainWindow::FloatingBoard_PointerMoved }), true);
        floating_board_root_.AddHandler(UIElement::PointerReleasedEvent(),
            winrt::box_value<Microsoft::UI::Xaml::Input::PointerEventHandler>({
                this, &MainWindow::FloatingBoard_PointerReleased }), true);
        floating_board_root_.AddHandler(UIElement::PointerCanceledEvent(),
            winrt::box_value<Microsoft::UI::Xaml::Input::PointerEventHandler>({
                this, &MainWindow::FloatingBoard_PointerReleased }), true);
        floating_board_window_.Content(floating_board_root_);
        floating_board_closed_token_ = floating_board_window_.Closed(
            [this](auto const&, auto const&)
            {
                floating_board_drag_pending_ = false;
                floating_board_drag_started_ = false;
                if (floating_board_hwnd_)
                {
                    RemoveWindowSubclass(
                        floating_board_hwnd_, FloatingBoardSubclassProc, FloatingBoardSubclassId);
                    floating_board_hwnd_ = nullptr;
                }
                floating_board_root_ = nullptr;
                floating_board_grid_ = nullptr;
                floating_board_window_ = nullptr;
            });
        ConfigureFloatingBoardWindow();
        RenderFloatingBoard();
        floating_board_window_.AppWindow().Show(false);
    }

    void MainWindow::FloatingBoard_Click(
        Windows::Foundation::IInspectable const&, Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        OpenFloatingBoard();
    }

    void MainWindow::RenderBoard()
    {
        if (!live_game_)
        {
            return;
        }
        ApplyBoardChrome();
        BoardGrid().Children().Clear();
        BoardGrid().RowDefinitions().Clear();
        BoardGrid().ColumnDefinitions().Clear();
        for (int index = 0; index < 8; ++index)
        {
            RowDefinition row;
            row.Height(GridLength{ 1, GridUnitType::Star });
            BoardGrid().RowDefinitions().Append(row);
            ColumnDefinition column;
            column.Width(GridLength{ 1, GridUnitType::Star });
            BoardGrid().ColumnDefinitions().Append(column);
        }

        auto const square_extent = 80.0;
        auto const black_perspective = live_game_->player_color == L"black";
        auto const square_style = Application::Current().Resources()
            .Lookup(box_value(L"BoardSquareButtonStyle")).as<Style>();
        for (int row = 0; row < 8; ++row)
        {
            for (int column = 0; column < 8; ++column)
            {
                auto const file_index = black_perspective ? 7 - column : column;
                auto const rank = black_perspective ? row + 1 : 8 - row;
                std::wstring square;
                square.push_back(static_cast<wchar_t>(L'a' + file_index));
                square += std::to_wstring(rank);
                hstring const square_id(square);
                auto const light = (file_index + rank) % 2 == 0;
                auto const piece = std::find_if(
                    live_game_->board.pieces.begin(),
                    live_game_->board.pieces.end(),
                    [&](auto const& candidate) { return candidate.square == square_id; });
                auto const legal_destination = std::any_of(
                        live_game_->board.legal_moves.begin(),
                        live_game_->board.legal_moves.end(),
                        [&](auto const& move)
                        {
                            return move.to == square_id
                                && ((!selected_square_.empty() && move.from == selected_square_)
                                    || (!selected_drop_.empty() && move.drop == selected_drop_));
                        });

                Button button;
                button.Style(square_style);
                button.Tag(box_value(square_id));
                button.Background(CreateBrush(Color(
                    light ? board_presentation_.light_square : board_presentation_.dark_square)));
                button.Click({ this, &MainWindow::Square_Click });

                Grid content;
                if (live_game_->board.last_move
                    && (live_game_->board.last_move->from == square_id
                        || live_game_->board.last_move->to == square_id))
                {
                    Shapes::Rectangle overlay;
                    overlay.Fill(CreateBrush(Color(board_presentation_.last_move)));
                    overlay.IsHitTestVisible(false);
                    content.Children().Append(overlay);
                }
                if (selected_square_ == square_id)
                {
                    Shapes::Rectangle overlay;
                    overlay.Fill(CreateBrush(Color(board_presentation_.selection)));
                    overlay.IsHitTestVisible(false);
                    content.Children().Append(overlay);
                }
                if (live_game_->board.in_check && piece != live_game_->board.pieces.end()
                    && piece->role == L"king" && piece->color == live_game_->board.turn)
                {
                    Media::RadialGradientBrush brush;
                    brush.Center({ 0.5, 0.5 });
                    brush.GradientOrigin({ 0.5, 0.5 });
                    auto const radius = static_cast<double>(
                        board_presentation_.board_metrics.check_gradient_radius_percent) / 100.0;
                    brush.RadiusX(radius);
                    brush.RadiusY(radius);
                    Media::GradientStop center;
                    center.Offset(0);
                    center.Color(Color(board_presentation_.check_center));
                    Media::GradientStop edge;
                    edge.Offset(1);
                    edge.Color(Color(board_presentation_.check_edge));
                    brush.GradientStops().Append(center);
                    brush.GradientStops().Append(edge);
                    Shapes::Rectangle overlay;
                    overlay.Fill(brush);
                    overlay.IsHitTestVisible(false);
                    content.Children().Append(overlay);
                }
                if (legal_destination)
                {
                    Shapes::Ellipse marker;
                    marker.HorizontalAlignment(HorizontalAlignment::Center);
                    marker.VerticalAlignment(VerticalAlignment::Center);
                    marker.IsHitTestVisible(false);
                    if (piece == live_game_->board.pieces.end())
                    {
                        auto const extent = square_extent
                            * board_presentation_.board_metrics.destination_dot_scale_percent / 100.0;
                        marker.Width(extent);
                        marker.Height(extent);
                        marker.Fill(CreateBrush(Color(board_presentation_.legal_move)));
                    }
                    else
                    {
                        auto const inset = square_extent
                            * board_presentation_.board_metrics.destination_ring_inset_percent / 100.0;
                        marker.Width(square_extent - inset * 2.0);
                        marker.Height(square_extent - inset * 2.0);
                        marker.Stroke(CreateBrush(Color(board_presentation_.legal_move)));
                        marker.StrokeThickness(square_extent
                            * board_presentation_.board_metrics.destination_ring_width_percent / 100.0);
                        Canvas::SetZIndex(marker, 20);
                    }
                    content.Children().Append(marker);
                }

                auto const coordinate_color = light
                    ? board_presentation_.coordinate_on_light
                    : board_presentation_.coordinate_on_dark;
                auto const coordinate_size = square_extent
                    * board_presentation_.board_metrics.coordinate_font_scale_percent / 100.0;
                auto const coordinate_inset = static_cast<double>(
                    board_presentation_.board_metrics.coordinate_inset);
                if (column == 0)
                {
                    TextBlock rank_label;
                    rank_label.Text(winrt::to_hstring(rank));
                    rank_label.FontSize(coordinate_size);
                    rank_label.FontWeight(Windows::UI::Text::FontWeights::Bold());
                    rank_label.Foreground(CreateBrush(Color(coordinate_color)));
                    rank_label.HorizontalAlignment(HorizontalAlignment::Left);
                    rank_label.VerticalAlignment(VerticalAlignment::Top);
                    rank_label.Margin(Thickness{ coordinate_inset, coordinate_inset, 0, 0 });
                    rank_label.IsHitTestVisible(false);
                    content.Children().Append(rank_label);
                }
                if (row == 7)
                {
                    wchar_t const file_label[]{ static_cast<wchar_t>(L'a' + file_index), L'\0' };
                    TextBlock file;
                    file.Text(file_label);
                    file.FontSize(coordinate_size);
                    file.FontWeight(Windows::UI::Text::FontWeights::Bold());
                    file.Foreground(CreateBrush(Color(coordinate_color)));
                    file.HorizontalAlignment(HorizontalAlignment::Right);
                    file.VerticalAlignment(VerticalAlignment::Bottom);
                    file.Margin(Thickness{ 0, 0, coordinate_inset, coordinate_inset });
                    file.IsHitTestVisible(false);
                    content.Children().Append(file);
                }

                FrameworkElement piece_visual{ nullptr };
                if (piece != live_game_->board.pieces.end())
                {
                    piece_visual = CreatePieceVisual(*piece, square_extent);
                    content.Children().Append(piece_visual);
                    if (piece->promoted && !board_presentation_.promoted_marker.value.empty())
                    {
                        auto const marker_extent = square_extent
                            * board_presentation_.piece_metrics.promoted_marker_scale_percent / 100.0;
                        FrameworkElement marker{ nullptr };
                        if (board_presentation_.promoted_marker.kind == L"svg")
                        {
                            Image image;
                            image.Width(marker_extent);
                            image.Height(marker_extent);
                            image.Stretch(Media::Stretch::Uniform);
                            image.Opacity(static_cast<double>(
                                board_presentation_.promoted_marker_color.alpha) / 255.0);
                            image.Source(SvgSource(
                                board_presentation_.promoted_marker,
                                board_presentation_.promoted_marker_color));
                            marker = image;
                        }
                        else
                        {
                            TextBlock text;
                            text.Text(board_presentation_.promoted_marker.value);
                            text.FontSize(marker_extent);
                            text.Foreground(CreateBrush(Color(
                                board_presentation_.promoted_marker_color)));
                            marker = text;
                        }
                        marker.HorizontalAlignment(HorizontalAlignment::Right);
                        marker.VerticalAlignment(VerticalAlignment::Top);
                        auto const inset = static_cast<double>(
                            board_presentation_.piece_metrics.promoted_marker_inset);
                        marker.Margin(Thickness{ inset, inset, inset, inset });
                        marker.IsHitTestVisible(false);
                        content.Children().Append(marker);
                    }
                }

                button.Content(content);
                Grid::SetRow(button, row);
                Grid::SetColumn(button, column);
                BoardGrid().Children().Append(button);

                if (piece_visual)
                {
                    auto const origin = piece_animation_origins_.find(std::wstring(square_id));
                    if (origin != piece_animation_origins_.end())
                    {
                        Canvas::SetZIndex(button, 10);
                        AnimatePiece(piece_visual, origin->second, square_id, black_perspective);
                    }
                    else if (std::find(
                        piece_appearance_squares_.begin(),
                        piece_appearance_squares_.end(),
                        square_id) != piece_appearance_squares_.end())
                    {
                        Canvas::SetZIndex(button, 5);
                        AnimatePieceAppearance(piece_visual);
                    }
                }
            }
        }
        RenderFloatingBoard();
        piece_animation_origins_.clear();
        piece_appearance_squares_.clear();
        if (BoardGrid().Children().Size() != 64)
        {
            ::LibChess::Windows::DiagnosticLog::Write(
                L"board",
                L"Board render invariant failed: expected 64 squares, received "
                    + winrt::to_hstring(BoardGrid().Children().Size()) + L".");
        }
    }

    void MainWindow::Square_Click(
        Windows::Foundation::IInspectable const& sender,
        Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        if (!live_game_
            || (live_game_->status != L"created" && live_game_->status != L"started")
            || live_game_->board.turn != live_game_->player_color
            || !pending_move_request_id_.empty()
            || !pending_game_action_request_id_.empty())
        {
            return;
        }
        auto const anchor = sender.as<Button>();
        auto const square = unbox_value<hstring>(anchor.Tag());
        if (!selected_drop_.empty())
        {
            auto const move = std::find_if(
                live_game_->board.legal_moves.begin(),
                live_game_->board.legal_moves.end(),
                [&](auto const& candidate)
                {
                    return candidate.drop == selected_drop_ && candidate.to == square;
                });
            if (move != live_game_->board.legal_moves.end())
            {
                SubmitMove(move->id);
                return;
            }
            auto const own_piece = std::find_if(
                live_game_->board.pieces.begin(), live_game_->board.pieces.end(),
                [&](auto const& piece)
                {
                    return piece.square == square && piece.color == live_game_->player_color;
                });
            if (own_piece != live_game_->board.pieces.end())
            {
                selected_drop_.clear();
            }
            else
            {
                return;
            }
        }
        auto const can_select = [&](hstring const& from)
        {
            return std::any_of(
                live_game_->board.legal_moves.begin(),
                live_game_->board.legal_moves.end(),
                [&](auto const& move) { return move.from == from; });
        };

        if (selected_square_.empty())
        {
            if (can_select(square))
            {
                selected_square_ = square;
                RenderBoard();
            }
            return;
        }
        if (selected_square_ == square)
        {
            selected_square_.clear();
            RenderBoard();
            return;
        }

        std::vector<::LibChess::Windows::Wire::LegalMove> candidates;
        std::copy_if(
            live_game_->board.legal_moves.begin(),
            live_game_->board.legal_moves.end(),
            std::back_inserter(candidates),
            [&](auto const& candidate)
            {
                return candidate.from == selected_square_ && candidate.to == square;
            });
        if (candidates.size() == 1)
        {
            SubmitMove(candidates.front().id);
            return;
        }
        if (candidates.size() > 1)
        {
            ShowPromotionMenu(anchor, std::move(candidates));
            return;
        }

        selected_square_ = can_select(square) ? square : hstring{};
        RenderBoard();
    }

    void MainWindow::ShowPromotionMenu(
        Button const& anchor,
        std::vector<::LibChess::Windows::Wire::LegalMove> moves)
    {
        auto const order = [](hstring const& role)
        {
            if (role == L"queen") return 0;
            if (role == L"rook") return 1;
            if (role == L"bishop") return 2;
            if (role == L"knight") return 3;
            return 4;
        };
        std::sort(moves.begin(), moves.end(), [&](auto const& left, auto const& right)
        {
            return order(left.promotion) < order(right.promotion);
        });
        MenuFlyout flyout;
        for (auto const& move : moves)
        {
            MenuFlyoutItem item;
            item.Text(RoleDisplayName(move.promotion));
            auto const move_id = move.id;
            item.Click([lifetime = get_strong(), move_id](auto const&, auto const&)
            {
                lifetime->SubmitMove(move_id);
            });
            flyout.Items().Append(item);
        }
        flyout.ShowAt(anchor);
    }

    void MainWindow::SubmitMove(hstring const& move_id)
    {
        if (!live_game_ || move_id.empty()
            || !pending_move_request_id_.empty()
            || !pending_game_action_request_id_.empty())
        {
            return;
        }
        JsonObject command;
        command.Insert(L"type", JsonString(L"play_move"));
        command.Insert(L"game_id", JsonString(live_game_->id));
        command.Insert(L"move_id", JsonString(move_id));
        command.Insert(L"offer_draw", JsonValue::CreateBooleanValue(false));
        selected_square_.clear();
        selected_drop_.clear();
        move_rollback_board_.reset();
        move_rollback_white_time_millis_.reset();
        move_rollback_black_time_millis_.reset();
        pending_move_request_id_ = SendCommand(command);
        UpdateGameInspector();
        RenderBoard();
    }

    void MainWindow::SendGameAction(hstring const& action)
    {
        if (!live_game_ || !pending_move_request_id_.empty()
            || !pending_game_action_request_id_.empty())
        {
            return;
        }
        JsonObject command;
        command.Insert(L"type", JsonString(L"perform_game_action"));
        command.Insert(L"game_id", JsonString(live_game_->id));
        command.Insert(L"action", JsonString(action));
        pending_game_action_request_id_ = SendCommand(command);
        UpdateGameInspector();
    }

    void MainWindow::OfferDraw_Click(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        SendGameAction(L"offer_draw");
    }

    void MainWindow::OfferTakeback_Click(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        SendGameAction(L"offer_takeback");
    }

    void MainWindow::AcceptOffer_Click(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        if (incoming_offer_ == L"draw")
        {
            SendGameAction(L"accept_draw");
        }
        else if (incoming_offer_ == L"takeback")
        {
            SendGameAction(L"accept_takeback");
        }
    }

    void MainWindow::DeclineOffer_Click(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        if (incoming_offer_ == L"draw")
        {
            SendGameAction(L"decline_draw");
        }
        else if (incoming_offer_ == L"takeback")
        {
            SendGameAction(L"decline_takeback");
        }
    }

    void MainWindow::ClaimVictory_Click(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        SendGameAction(L"claim_victory");
    }

    void MainWindow::ClaimDraw_Click(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        SendGameAction(L"claim_draw");
    }

    void MainWindow::OpenGame_Click(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        OpenGameAsync();
    }

    winrt::fire_and_forget MainWindow::OpenGameAsync()
    {
        auto lifetime = get_strong();
        if (!live_game_ || live_game_->url.empty())
        {
            co_return;
        }
        try
        {
            auto const launched = co_await Windows::System::Launcher::LaunchUriAsync(
                Windows::Foundation::Uri(live_game_->url));
            if (!launched)
            {
                ShowMessage(L"Windows couldn't open this game in your browser.");
            }
        }
        catch (...)
        {
            ShowMessage(L"Windows couldn't open this game in your browser.");
        }
    }

    winrt::fire_and_forget MainWindow::OpenAnalysisAsync()
    {
        auto lifetime = get_strong();
        auto const history = std::find_if(
            game_history_.begin(), game_history_.end(),
            [&](auto const& game) { return game.id == review_game_id_; });
        if (history == game_history_.end() || history->analysis_url.empty())
        {
            co_return;
        }
        try
        {
            auto const launched = co_await Windows::System::Launcher::LaunchUriAsync(
                Windows::Foundation::Uri(history->analysis_url));
            if (!launched)
            {
                ShowMessage(L"Windows couldn't open the service analysis.");
            }
        }
        catch (...)
        {
            ShowMessage(L"Windows couldn't open the service analysis.");
        }
    }

    void MainWindow::ReconnectGame_Click(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        if (!live_game_)
        {
            return;
        }
        StartLiveGame(live_game_->id, live_game_->player_color);
    }

    void MainWindow::Resign_Click(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        ConfirmTerminationAsync();
    }

    winrt::fire_and_forget MainWindow::ConfirmTerminationAsync()
    {
        auto lifetime = get_strong();
        if (!live_game_ || termination_dialog_open_)
        {
            co_return;
        }
        termination_dialog_open_ = true;
        UpdateGameInspector();
        auto const game_id = live_game_->id;
        auto const abort = live_game_->board.ply < 2;
        ContentDialog dialog;
        dialog.XamlRoot(RootGrid().XamlRoot());
        dialog.Title(box_value(abort ? L"Abort this game?" : L"Resign this game?"));
        dialog.Content(box_value(abort
            ? L"The game will end before any result is recorded."
            : L"Your opponent will win the game."));
        dialog.PrimaryButtonText(abort ? L"Abort game" : L"Resign");
        dialog.CloseButtonText(L"Cancel");
        dialog.DefaultButton(ContentDialogButton::Close);
        ContentDialogResult result{ ContentDialogResult::None };
        try
        {
            result = co_await dialog.ShowAsync();
        }
        catch (winrt::hresult_error const&)
        {
            ShowMessage(L"Windows couldn't show the game confirmation.");
        }
        termination_dialog_open_ = false;
        UpdateGameInspector();
        if (result != ContentDialogResult::Primary)
        {
            co_return;
        }
        auto const still_playable = live_game_
            && live_game_->id == game_id
            && (live_game_->status == L"created" || live_game_->status == L"started");
        if (!still_playable || (live_game_->board.ply < 2) != abort)
        {
            ShowMessage(L"The game changed while confirmation was open. Try again.", false);
            co_return;
        }
        SendGameAction(abort ? L"abort" : L"resign");
    }

    void MainWindow::ChangeBackend_Click(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        JsonObject command;
        command.Insert(L"type", JsonString(L"clear_backend_selection"));
        SendCommand(command);
    }

    void MainWindow::ShowMessage(hstring const& message, bool error)
    {
        auto const severity = error ? InfoBarSeverity::Error : InfoBarSeverity::Informational;
        LauncherInfoBar().Severity(severity);
        LauncherInfoBar().Message(message);
        LauncherInfoBar().IsOpen(true);
        WorkspaceInfoBar().Severity(severity);
        WorkspaceInfoBar().Message(message);
        WorkspaceInfoBar().IsOpen(true);
    }

    void MainWindow::ResizeAndCenter()
    {
        HWND hwnd = nullptr;
        Microsoft::UI::Xaml::Window window = *this;
        check_hresult(window.as<::IWindowNative>()->get_WindowHandle(&hwnd));
        auto const dpi = GetDpiForWindow(hwnd);
        auto const scale = static_cast<double>(dpi) / 96.0;
        auto const width = static_cast<int>(1180 * scale);
        auto const height = static_cast<int>(780 * scale);
        RECT work_area{};
        MONITORINFO monitor{ sizeof(monitor) };
        GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &monitor);
        work_area = monitor.rcWork;
        auto const x = work_area.left + (work_area.right - work_area.left - width) / 2;
        auto const y = work_area.top + (work_area.bottom - work_area.top - height) / 2;
        SetWindowPos(hwnd, nullptr, x, y, width, height, SWP_NOZORDER | SWP_NOACTIVATE);
    }
}
