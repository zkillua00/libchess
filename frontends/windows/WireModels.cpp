#include "pch.h"
#include "WireModels.h"

namespace
{
    using namespace winrt;
    using namespace Windows::Data::Json;

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

    bool Boolean(JsonObject const& parent, wchar_t const* name, bool fallback = false)
    {
        if (!parent || !parent.HasKey(name))
        {
            return fallback;
        }
        auto const value = parent.GetNamedValue(name);
        return value.ValueType() == JsonValueType::Boolean ? value.GetBoolean() : fallback;
    }

    double Number(JsonObject const& parent, wchar_t const* name, double fallback = 0)
    {
        if (!parent || !parent.HasKey(name))
        {
            return fallback;
        }
        auto const value = parent.GetNamedValue(name);
        return value.ValueType() == JsonValueType::Number ? value.GetNumber() : fallback;
    }

    LibChess::Windows::Wire::RgbaColor Color(
        JsonObject const& parent,
        wchar_t const* name,
        LibChess::Windows::Wire::RgbaColor fallback)
    {
        auto const color = Object(parent, name);
        if (!color)
        {
            return fallback;
        }
        auto const channel = [](double value)
        {
            return static_cast<std::uint8_t>(std::clamp(value, 0.0, 255.0));
        };
        return {
            channel(Number(color, L"red")),
            channel(Number(color, L"green")),
            channel(Number(color, L"blue")),
            channel(Number(color, L"alpha", 255)),
        };
    }

    hstring PlayerName(JsonObject const& player)
    {
        auto const name = String(player, L"name");
        auto const title = String(player, L"title");
        if (title.empty())
        {
            return name;
        }
        return hstring(std::wstring(title) + L" " + std::wstring(name));
    }
}

namespace LibChess::Windows::Wire
{
    Provider ParseProvider(winrt::Windows::Data::Json::JsonObject const& json)
    {
        Provider provider;
        provider.id = String(json, L"id");
        provider.kind = String(json, L"kind");
        provider.display_name = String(json, L"display_name");
        provider.subtitle = String(json, L"subtitle");
        provider.description = String(json, L"description");
        provider.icon = String(json, L"icon");
        provider.action_title = String(json, L"action_title");
        provider.available = Boolean(json, L"available");
        provider.unavailable_reason = String(json, L"unavailable_reason");
        auto const connection = Object(json, L"connection");
        provider.connection_type = String(connection, L"type");
        provider.authorization_origin = String(connection, L"authorization_origin");

        auto const options_json = Object(json, L"bot_game_options");
        if (!options_json)
        {
            return provider;
        }

        BotGameOptions options;
        if (auto const opponents = Array(json, L"bot_opponents"))
        {
            for (auto const& value : opponents)
            {
                auto const opponent = value.GetObject();
                options.opponents.push_back({
                    String(opponent, L"id"),
                    String(opponent, L"display_name"),
                });
            }
        }
        if (auto const variants = Array(options_json, L"variants"))
        {
            for (auto const& value : variants)
            {
                auto const variant = value.GetObject();
                options.variants.push_back({
                    String(variant, L"id"),
                    String(variant, L"display_name"),
                    Boolean(variant, L"supports_custom_position"),
                    Boolean(variant, L"requires_custom_position"),
                });
            }
        }
        if (auto const colors = Array(options_json, L"colors"))
        {
            for (auto const& value : colors)
            {
                if (value.ValueType() == winrt::Windows::Data::Json::JsonValueType::String)
                {
                    options.colors.push_back(value.GetString());
                }
            }
        }
        if (auto const clock_json = Object(options_json, L"clock"))
        {
            ClockTimeControlOptions clock;
            if (auto const initial_seconds = Array(clock_json, L"initial_seconds"))
            {
                for (auto const& value : initial_seconds)
                {
                    if (value.ValueType() == winrt::Windows::Data::Json::JsonValueType::Number)
                    {
                        clock.initial_seconds.push_back(
                            static_cast<std::uint32_t>(value.GetNumber()));
                    }
                }
            }
            if (auto const increment_seconds = Array(clock_json, L"increment_seconds"))
            {
                for (auto const& value : increment_seconds)
                {
                    if (value.ValueType() == winrt::Windows::Data::Json::JsonValueType::Number)
                    {
                        clock.increment_seconds.push_back(
                            static_cast<std::uint32_t>(value.GetNumber()));
                    }
                }
            }
            if (clock_json.HasKey(L"minimum_estimated_duration_seconds"))
            {
                auto const value = clock_json.GetNamedValue(L"minimum_estimated_duration_seconds");
                if (value.ValueType() == winrt::Windows::Data::Json::JsonValueType::Number)
                {
                    clock.minimum_estimated_duration_seconds =
                        static_cast<std::uint32_t>(value.GetNumber());
                }
            }
            if (!clock.initial_seconds.empty() && !clock.increment_seconds.empty())
            {
                options.clock = std::move(clock);
            }
        }
        if (auto const correspondence_days = Array(options_json, L"correspondence_days"))
        {
            for (auto const& value : correspondence_days)
            {
                if (value.ValueType() == winrt::Windows::Data::Json::JsonValueType::Number)
                {
                    options.correspondence_days.push_back(
                        static_cast<std::uint32_t>(value.GetNumber()));
                }
            }
        }
        options.unlimited = Boolean(options_json, L"unlimited");
        options.default_opponent_id = String(options_json, L"default_opponent_id");
        options.default_variant_id = String(options_json, L"default_variant_id");
        options.default_color = String(options_json, L"default_color");
        if (options_json.HasKey(L"default_time_control"))
        {
            options.default_time_control_json =
                options_json.GetNamedValue(L"default_time_control").Stringify();
        }
        if (auto const reply_delay = Object(options_json, L"reply_delay"))
        {
            options.has_reply_delay = true;
            options.default_reply_delay_millis = static_cast<std::uint32_t>(
                Number(reply_delay, L"default_millis"));
        }
        provider.bot_game_options = std::move(options);
        return provider;
    }

    std::vector<Provider> ParseProviders(winrt::Windows::Data::Json::JsonArray const& json)
    {
        std::vector<Provider> providers;
        if (!json)
        {
            return providers;
        }
        providers.reserve(json.Size());
        for (auto const& value : json)
        {
            if (value.ValueType() == winrt::Windows::Data::Json::JsonValueType::Object)
            {
                providers.push_back(ParseProvider(value.GetObject()));
            }
        }
        return providers;
    }

    BoardPresentation ParseBoardPresentation(winrt::Windows::Data::Json::JsonObject const& json)
    {
        BoardPresentation presentation;
        auto const board_palette = Object(Object(json, L"board"), L"palette");
        presentation.light_square = Color(board_palette, L"light_square", presentation.light_square);
        presentation.dark_square = Color(board_palette, L"dark_square", presentation.dark_square);
        presentation.selection = Color(board_palette, L"selection", presentation.selection);
        presentation.legal_move = Color(board_palette, L"legal_move", presentation.legal_move);
        presentation.last_move = Color(board_palette, L"last_move", presentation.last_move);

        auto const piece_style = Object(json, L"pieces");
        auto const piece_palette = Object(piece_style, L"palette");
        presentation.white_piece = Color(piece_palette, L"white_piece", presentation.white_piece);
        presentation.black_piece = Color(piece_palette, L"black_piece", presentation.black_piece);
        if (auto const assets = Array(Object(piece_style, L"assets"), L"pieces"))
        {
            for (auto const& value : assets)
            {
                auto const piece = value.GetObject();
                auto const asset = Object(piece, L"asset");
                auto const key = std::wstring(String(piece, L"color"))
                    + L"/" + std::wstring(String(piece, L"role"));
                presentation.assets.insert_or_assign(key, BoardAsset{
                    String(asset, L"kind"),
                    String(asset, L"value"),
                    Boolean(asset, L"tintable", true),
                });
            }
        }
        return presentation;
    }

    LegalMove ParseLegalMove(winrt::Windows::Data::Json::JsonObject const& json)
    {
        return {
            String(json, L"id"),
            String(json, L"from"),
            String(json, L"to"),
            String(json, L"promotion"),
            String(json, L"drop"),
        };
    }

    LiveGame ParseLiveGame(winrt::Windows::Data::Json::JsonObject const& json)
    {
        LiveGame game;
        game.id = String(json, L"id");
        game.provider = String(json, L"provider");
        game.player_color = String(json, L"player_color");
        game.variant_name = String(json, L"variant_name");
        game.speed = String(json, L"speed");
        game.white_name = PlayerName(Object(json, L"white"));
        game.black_name = PlayerName(Object(json, L"black"));

        auto const state = Object(json, L"state");
        game.status = String(state, L"status");
        game.winner = String(state, L"winner");
        auto const board = Object(state, L"board");
        game.board.turn = String(board, L"turn");
        game.board.ply = static_cast<std::uint32_t>(Number(board, L"ply"));
        game.board.in_check = Boolean(board, L"in_check");
        if (auto const pieces = Array(board, L"pieces"))
        {
            for (auto const& value : pieces)
            {
                auto const piece = value.GetObject();
                game.board.pieces.push_back({
                    String(piece, L"square"),
                    String(piece, L"color"),
                    String(piece, L"role"),
                    Boolean(piece, L"promoted"),
                });
            }
        }
        if (auto const moves = Array(board, L"legal_moves"))
        {
            for (auto const& value : moves)
            {
                game.board.legal_moves.push_back(ParseLegalMove(value.GetObject()));
            }
        }
        if (auto const last_move = Object(board, L"last_move"))
        {
            game.board.last_move = ParseLegalMove(last_move);
        }
        return game;
    }

    winrt::Windows::Data::Json::JsonObject ParseObject(std::string const& utf8)
    {
        return winrt::Windows::Data::Json::JsonObject::Parse(winrt::to_hstring(utf8));
    }

    std::string ToUtf8(winrt::hstring const& value)
    {
        return winrt::to_string(value);
    }
}
