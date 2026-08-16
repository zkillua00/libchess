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
                }
                return;
            }
            if (type == L"board_presentation_loaded")
            {
                if (auto const presentation = Object(event, L"board_presentation"))
                {
                    board_presentation_ =
                        ::LibChess::Windows::Wire::ParseBoardPresentation(presentation);
                    RenderBoard();
                }
                return;
            }
            if (type == L"backend_selection_changed")
            {
                auto const backend = Object(event, L"backend");
                if (!backend)
                {
                    selected_provider_.reset();
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
                    JsonObject watch;
                    watch.Insert(L"type", JsonString(L"watch_live_games"));
                    SendCommand(watch);
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
                    ShowLiveGame(::LibChess::Windows::Wire::ParseLiveGame(game));
                }
                return;
            }
            if (type == L"error")
            {
                CreateGameButton().IsEnabled(true);
                CreateGameProgress().Visibility(Visibility::Collapsed);
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

    void MainWindow::SendCommand(Windows::Data::Json::JsonObject const& command)
    {
        if (!native_client_)
        {
            throw std::runtime_error("LibChess is not available");
        }
        command.Insert(L"version", JsonNumber(1));
        command.Insert(
            L"request_id",
            JsonString(L"windows-" + winrt::to_hstring(next_request_id_++)));
        native_client_->Send(winrt::to_string(command.Stringify()));
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
        JsonObject command;
        command.Insert(L"type", JsonString(L"start_live_game"));
        command.Insert(L"game_id", JsonString(String(game, L"id")));
        command.Insert(L"player_color", JsonString(String(game, L"player_color")));
        SendCommand(command);
    }

    void MainWindow::ShowLiveGame(::LibChess::Windows::Wire::LiveGame game)
    {
        live_game_ = std::move(game);
        selected_square_.clear();
        CreateGameButton().IsEnabled(true);
        CreateGameProgress().Visibility(Visibility::Collapsed);
        BoardNavigationItem().IsEnabled(true);
        MainNavigation().SelectedItem(BoardNavigationItem());
        NewGamePane().Visibility(Visibility::Collapsed);
        GamePane().Visibility(Visibility::Visible);

        GameVariant().Text(live_game_->variant_name);
        BlackPlayer().Text(live_game_->black_name);
        WhitePlayer().Text(live_game_->white_name);
        auto status = live_game_->status;
        if (status == L"started")
        {
            status = live_game_->board.turn == live_game_->player_color
                ? L"Your move"
                : L"Waiting for opponent";
        }
        else if (!live_game_->winner.empty())
        {
            status = L"Game finished \u00B7 " + live_game_->winner + L" won";
        }
        GameStatus().Text(status);
        RenderBoard();
    }

    void MainWindow::MainNavigation_SelectionChanged(
        Microsoft::UI::Xaml::Controls::NavigationView const&,
        Microsoft::UI::Xaml::Controls::NavigationViewSelectionChangedEventArgs const& args)
    {
        auto const item = args.SelectedItem().try_as<NavigationViewItem>();
        auto const tag = item ? unbox_value_or<hstring>(item.Tag(), {}) : hstring{};
        auto const board = tag == L"board" && live_game_.has_value();
        NewGamePane().Visibility(board ? Visibility::Collapsed : Visibility::Visible);
        GamePane().Visibility(board ? Visibility::Visible : Visibility::Collapsed);
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

    void MainWindow::RenderBoard()
    {
        if (!live_game_)
        {
            return;
        }
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

        auto const black_perspective = live_game_->player_color == L"black";
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

                auto const light = (file_index + rank) % 2 == 1;
                auto square_color = light
                    ? board_presentation_.light_square
                    : board_presentation_.dark_square;
                auto const is_last_move = live_game_->board.last_move
                    && (live_game_->board.last_move->from == square_id
                        || live_game_->board.last_move->to == square_id);
                if (is_last_move)
                {
                    square_color = board_presentation_.last_move;
                }
                if (selected_square_ == square_id)
                {
                    square_color = board_presentation_.selection;
                }
                auto const legal_destination = !selected_square_.empty()
                    && std::any_of(
                        live_game_->board.legal_moves.begin(),
                        live_game_->board.legal_moves.end(),
                        [&](auto const& move)
                        {
                            return move.from == selected_square_ && move.to == square_id;
                        });

                Button button;
                button.Tag(box_value(square_id));
                button.Padding(Thickness{});
                button.Margin(Thickness{});
                button.MinWidth(0);
                button.MinHeight(0);
                button.HorizontalAlignment(HorizontalAlignment::Stretch);
                button.VerticalAlignment(VerticalAlignment::Stretch);
                button.CornerRadius(CornerRadius{});
                button.BorderThickness(
                    legal_destination ? Thickness{ 3, 3, 3, 3 } : Thickness{});
                button.BorderBrush(CreateBrush(Color(board_presentation_.legal_move)));
                button.Background(CreateBrush(Color(square_color)));
                button.HorizontalContentAlignment(HorizontalAlignment::Center);
                button.VerticalContentAlignment(VerticalAlignment::Center);
                button.Click({ this, &MainWindow::Square_Click });

                auto const piece = std::find_if(
                    live_game_->board.pieces.begin(),
                    live_game_->board.pieces.end(),
                    [&](auto const& candidate) { return candidate.square == square_id; });
                TextBlock content;
                content.FontFamily(Media::FontFamily(L"Segoe UI Symbol"));
                content.FontSize(46);
                content.HorizontalAlignment(HorizontalAlignment::Center);
                content.VerticalAlignment(VerticalAlignment::Center);
                if (piece != live_game_->board.pieces.end())
                {
                    auto const key = std::wstring(piece->color) + L"/" + std::wstring(piece->role);
                    auto const asset = board_presentation_.assets.find(key);
                    content.Text(
                        asset != board_presentation_.assets.end() && asset->second.kind == L"text_glyph"
                            ? asset->second.value
                            : PieceFallback(piece->color, piece->role));
                    content.Foreground(CreateBrush(Color(
                        piece->color == L"white"
                            ? board_presentation_.white_piece
                            : board_presentation_.black_piece)));
                }
                else if (legal_destination)
                {
                    content.Text(L"\u2022");
                    content.FontSize(34);
                    content.Foreground(CreateBrush(Color(board_presentation_.legal_move)));
                }
                button.Content(content);
                Grid::SetRow(button, row);
                Grid::SetColumn(button, column);
                BoardGrid().Children().Append(button);
            }
        }
    }

    void MainWindow::Square_Click(
        Windows::Foundation::IInspectable const& sender,
        Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        if (!live_game_ || live_game_->status != L"started"
            || live_game_->board.turn != live_game_->player_color)
        {
            return;
        }
        auto const square = unbox_value<hstring>(sender.as<Button>().Tag());
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

        auto move = std::find_if(
            live_game_->board.legal_moves.begin(),
            live_game_->board.legal_moves.end(),
            [&](auto const& candidate)
            {
                return candidate.from == selected_square_
                    && candidate.to == square
                    && (candidate.promotion.empty() || candidate.promotion == L"queen");
            });
        if (move != live_game_->board.legal_moves.end())
        {
            JsonObject command;
            command.Insert(L"type", JsonString(L"play_move"));
            command.Insert(L"game_id", JsonString(live_game_->id));
            command.Insert(L"move_id", JsonString(move->id));
            selected_square_.clear();
            RenderBoard();
            SendCommand(command);
            return;
        }

        selected_square_ = can_select(square) ? square : hstring{};
        RenderBoard();
    }

    void MainWindow::SendGameAction(hstring const& action)
    {
        if (!live_game_)
        {
            return;
        }
        JsonObject command;
        command.Insert(L"type", JsonString(L"perform_game_action"));
        command.Insert(L"game_id", JsonString(live_game_->id));
        command.Insert(L"action", JsonString(action));
        SendCommand(command);
    }

    void MainWindow::OfferDraw_Click(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        SendGameAction(L"offer_draw");
    }

    void MainWindow::Resign_Click(
        Windows::Foundation::IInspectable const&,
        Microsoft::UI::Xaml::RoutedEventArgs const&)
    {
        SendGameAction(L"resign");
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
