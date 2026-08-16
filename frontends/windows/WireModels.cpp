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

    std::optional<std::uint64_t> OptionalNumber(JsonObject const& parent, wchar_t const* name)
    {
        if (!parent || !parent.HasKey(name))
        {
            return std::nullopt;
        }
        auto const value = parent.GetNamedValue(name);
        if (value.ValueType() != JsonValueType::Number)
        {
            return std::nullopt;
        }
        return static_cast<std::uint64_t>(value.GetNumber());
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

    LibChess::Windows::Wire::LiveGamePlayer Player(JsonObject const& json)
    {
        LibChess::Windows::Wire::LiveGamePlayer player;
        player.id = String(json, L"id");
        player.name = String(json, L"name");
        player.title = String(json, L"title");
        if (auto const rating = OptionalNumber(json, L"rating"))
        {
            player.rating = static_cast<std::uint32_t>(*rating);
        }
        if (auto const level = OptionalNumber(json, L"ai_level"))
        {
            player.ai_level = static_cast<std::uint32_t>(*level);
        }
        player.provisional = Boolean(json, L"provisional");
        return player;
    }

    LibChess::Windows::Wire::BoardAnimationRule AnimationRule(JsonObject const& json)
    {
        return {
            static_cast<std::uint32_t>(Number(json, L"duration_millis")),
            String(json, L"curve"),
            static_cast<std::uint32_t>(Number(json, L"extra_bounce_percent")),
        };
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
        if (auto const capabilities = Array(json, L"capabilities"))
        {
            for (auto const& value : capabilities)
            {
                if (value.ValueType() == JsonValueType::String)
                {
                    provider.capabilities.push_back(value.GetString());
                }
            }
        }

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
        presentation.provider = String(json, L"provider");
        presentation.board_theme = String(json, L"board_theme");
        presentation.piece_theme = String(json, L"piece_theme");
        auto const board_style = Object(json, L"board");
        auto const board_palette = Object(board_style, L"palette");
        presentation.light_square = Color(board_palette, L"light_square", presentation.light_square);
        presentation.dark_square = Color(board_palette, L"dark_square", presentation.dark_square);
        presentation.coordinate_on_light = Color(
            board_palette, L"coordinate_on_light", presentation.coordinate_on_light);
        presentation.coordinate_on_dark = Color(
            board_palette, L"coordinate_on_dark", presentation.coordinate_on_dark);
        presentation.selection = Color(board_palette, L"selection", presentation.selection);
        presentation.legal_move = Color(board_palette, L"legal_move", presentation.legal_move);
        presentation.last_move = Color(board_palette, L"last_move", presentation.last_move);
        presentation.check_center = Color(board_palette, L"check_center", presentation.check_center);
        presentation.check_edge = Color(board_palette, L"check_edge", presentation.check_edge);
        presentation.border = Color(board_palette, L"border", presentation.border);
        presentation.shadow = Color(board_palette, L"shadow", presentation.shadow);
        if (auto const metrics = Object(board_style, L"metrics"))
        {
            presentation.board_metrics.maximum_extent = static_cast<std::uint32_t>(
                Number(metrics, L"maximum_extent", presentation.board_metrics.maximum_extent));
            presentation.board_metrics.corner_radius = static_cast<std::uint32_t>(
                Number(metrics, L"corner_radius", presentation.board_metrics.corner_radius));
            presentation.board_metrics.border_width = static_cast<std::uint32_t>(
                Number(metrics, L"border_width", presentation.board_metrics.border_width));
            presentation.board_metrics.shadow_radius = static_cast<std::uint32_t>(
                Number(metrics, L"shadow_radius", presentation.board_metrics.shadow_radius));
            presentation.board_metrics.shadow_offset_y = static_cast<std::int32_t>(
                Number(metrics, L"shadow_offset_y", presentation.board_metrics.shadow_offset_y));
            presentation.board_metrics.coordinate_font_scale_percent = static_cast<std::uint32_t>(
                Number(metrics, L"coordinate_font_scale_percent", presentation.board_metrics.coordinate_font_scale_percent));
            presentation.board_metrics.coordinate_inset = static_cast<std::uint32_t>(
                Number(metrics, L"coordinate_inset", presentation.board_metrics.coordinate_inset));
            presentation.board_metrics.destination_dot_scale_percent = static_cast<std::uint32_t>(
                Number(metrics, L"destination_dot_scale_percent", presentation.board_metrics.destination_dot_scale_percent));
            presentation.board_metrics.destination_ring_inset_percent = static_cast<std::uint32_t>(
                Number(metrics, L"destination_ring_inset_percent", presentation.board_metrics.destination_ring_inset_percent));
            presentation.board_metrics.destination_ring_width_percent = static_cast<std::uint32_t>(
                Number(metrics, L"destination_ring_width_percent", presentation.board_metrics.destination_ring_width_percent));
            presentation.board_metrics.check_gradient_radius_percent = static_cast<std::uint32_t>(
                Number(metrics, L"check_gradient_radius_percent", presentation.board_metrics.check_gradient_radius_percent));
        }

        auto const piece_style = Object(json, L"pieces");
        auto const piece_palette = Object(piece_style, L"palette");
        presentation.white_piece = Color(piece_palette, L"white_piece", presentation.white_piece);
        presentation.black_piece = Color(piece_palette, L"black_piece", presentation.black_piece);
        presentation.white_piece_shadow = Color(
            piece_palette, L"white_piece_shadow", presentation.white_piece_shadow);
        presentation.black_piece_shadow = Color(
            piece_palette, L"black_piece_shadow", presentation.black_piece_shadow);
        presentation.promoted_marker_color = Color(
            piece_palette, L"promoted_marker", presentation.promoted_marker_color);
        if (auto const metrics = Object(piece_style, L"metrics"))
        {
            presentation.piece_metrics.scale_percent = static_cast<std::uint32_t>(
                Number(metrics, L"scale_percent", presentation.piece_metrics.scale_percent));
            presentation.piece_metrics.shadow_radius_tenths = static_cast<std::uint32_t>(
                Number(metrics, L"shadow_radius_tenths", presentation.piece_metrics.shadow_radius_tenths));
            presentation.piece_metrics.shadow_offset_y_tenths = static_cast<std::int32_t>(
                Number(metrics, L"shadow_offset_y_tenths", presentation.piece_metrics.shadow_offset_y_tenths));
            presentation.piece_metrics.promoted_marker_scale_percent = static_cast<std::uint32_t>(
                Number(metrics, L"promoted_marker_scale_percent", presentation.piece_metrics.promoted_marker_scale_percent));
            presentation.piece_metrics.promoted_marker_inset = static_cast<std::uint32_t>(
                Number(metrics, L"promoted_marker_inset", presentation.piece_metrics.promoted_marker_inset));
        }
        auto const piece_assets = Object(piece_style, L"assets");
        if (auto const assets = Array(piece_assets, L"pieces"))
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
        if (auto const marker = Object(piece_assets, L"promoted_marker"))
        {
            presentation.promoted_marker = {
                String(marker, L"kind"),
                String(marker, L"value"),
                Boolean(marker, L"tintable", true),
            };
        }
        if (auto const motion = Object(json, L"motion"))
        {
            presentation.motion.board_resize = AnimationRule(Object(motion, L"board_resize"));
            presentation.motion.piece_move = AnimationRule(Object(motion, L"piece_move"));
            presentation.motion.selection = AnimationRule(Object(motion, L"selection"));
            presentation.motion.piece_appearance_scale_percent = static_cast<std::uint32_t>(
                Number(motion, L"piece_appearance_scale_percent", presentation.motion.piece_appearance_scale_percent));
            presentation.motion.fade_piece_appearance = Boolean(
                motion, L"fade_piece_appearance", presentation.motion.fade_piece_appearance);
            presentation.motion.maximum_animated_ply_distance = static_cast<std::uint32_t>(
                Number(motion, L"maximum_animated_ply_distance", presentation.motion.maximum_animated_ply_distance));
        }
        if (auto const zoom = Object(json, L"zoom"))
        {
            presentation.default_zoom_preset = String(zoom, L"default_preset");
            if (auto const presets = Array(zoom, L"presets"))
            {
                for (auto const& value : presets)
                {
                    auto const preset = value.GetObject();
                    presentation.zoom_presets.push_back({
                        String(preset, L"id"),
                        String(preset, L"display_name"),
                        static_cast<std::uint32_t>(Number(preset, L"scale_percent", 100)),
                    });
                }
            }
        }
        return presentation;
    }

    std::vector<BoardProvider> ParseBoardProviders(
        winrt::Windows::Data::Json::JsonArray const& json)
    {
        std::vector<BoardProvider> providers;
        if (!json)
        {
            return providers;
        }
        for (auto const& value : json)
        {
            auto const object = value.GetObject();
            BoardProvider provider;
            provider.id = String(object, L"id");
            provider.display_name = String(object, L"display_name");
            provider.default_board_theme = String(object, L"default_board_theme");
            provider.default_piece_theme = String(object, L"default_piece_theme");
            if (auto const themes = Array(object, L"board_themes"))
            {
                for (auto const& theme_value : themes)
                {
                    auto const theme = theme_value.GetObject();
                    provider.board_themes.push_back({
                        String(theme, L"id"), String(theme, L"display_name") });
                }
            }
            if (auto const themes = Array(object, L"piece_themes"))
            {
                for (auto const& theme_value : themes)
                {
                    auto const theme = theme_value.GetObject();
                    provider.piece_themes.push_back({
                        String(theme, L"id"), String(theme, L"display_name") });
                }
            }
            providers.push_back(std::move(provider));
        }
        return providers;
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

    BoardState ParseBoardState(winrt::Windows::Data::Json::JsonObject const& board)
    {
        BoardState state;
        state.turn = String(board, L"turn");
        state.ply = static_cast<std::uint32_t>(Number(board, L"ply"));
        state.in_check = Boolean(board, L"in_check");
        if (auto const pieces = Array(board, L"pieces"))
        {
            for (auto const& value : pieces)
            {
                auto const piece = value.GetObject();
                state.pieces.push_back({
                    String(piece, L"square"),
                    String(piece, L"color"),
                    String(piece, L"role"),
                    Boolean(piece, L"promoted"),
                });
            }
        }
        if (auto const pockets = Array(board, L"pockets"))
        {
            for (auto const& value : pockets)
            {
                auto const pocket = value.GetObject();
                state.pockets.push_back({
                    String(pocket, L"color"),
                    String(pocket, L"role"),
                    static_cast<std::uint32_t>(Number(pocket, L"count")),
                });
            }
        }
        if (auto const moves = Array(board, L"moves"))
        {
            for (auto const& value : moves)
            {
                if (value.ValueType() == JsonValueType::String)
                {
                    state.moves.push_back(value.GetString());
                }
            }
        }
        if (auto const moves = Array(board, L"legal_moves"))
        {
            for (auto const& value : moves)
            {
                state.legal_moves.push_back(ParseLegalMove(value.GetObject()));
            }
        }
        if (auto const last_move = Object(board, L"last_move"))
        {
            state.last_move = ParseLegalMove(last_move);
        }
        return state;
    }

    LiveGame ParseLiveGame(winrt::Windows::Data::Json::JsonObject const& json)
    {
        LiveGame game;
        game.id = String(json, L"id");
        game.provider = String(json, L"provider");
        game.player_color = String(json, L"player_color");
        game.variant_name = String(json, L"variant_name");
        game.speed = String(json, L"speed");
        game.url = String(json, L"url");
        game.initial_fen = String(json, L"initial_fen");
        game.variant_id = String(json, L"variant_id");
        game.rated = Boolean(json, L"rated");
        if (auto const clock = Object(json, L"clock"))
        {
            game.has_clock = true;
            game.initial_clock_millis = OptionalNumber(clock, L"initial_millis");
            game.clock_increment_millis = OptionalNumber(clock, L"increment_millis");
        }
        game.white = Player(Object(json, L"white"));
        game.black = Player(Object(json, L"black"));
        if (auto const days = OptionalNumber(json, L"days_per_turn"))
        {
            game.days_per_turn = static_cast<std::uint32_t>(*days);
        }

        auto const state = Object(json, L"state");
        game.status = String(state, L"status");
        game.winner = String(state, L"winner");
        game.white_time_millis = OptionalNumber(state, L"white_time_millis");
        game.black_time_millis = OptionalNumber(state, L"black_time_millis");
        game.white_increment_millis = OptionalNumber(state, L"white_increment_millis");
        game.black_increment_millis = OptionalNumber(state, L"black_increment_millis");
        game.white_draw_offer = Boolean(state, L"white_draw_offer");
        game.black_draw_offer = Boolean(state, L"black_draw_offer");
        game.white_takeback_offer = Boolean(state, L"white_takeback_offer");
        game.black_takeback_offer = Boolean(state, L"black_takeback_offer");
        game.opponent_gone = Boolean(state, L"opponent_gone");
        if (auto const seconds = OptionalNumber(state, L"claim_win_in_seconds"))
        {
            game.claim_win_in_seconds = static_cast<std::uint32_t>(*seconds);
        }
        game.board = ParseBoardState(Object(state, L"board"));
        return game;
    }

    std::vector<LiveGameSummary> ParseLiveGameSummaries(
        winrt::Windows::Data::Json::JsonArray const& json)
    {
        std::vector<LiveGameSummary> games;
        if (!json)
        {
            return games;
        }
        for (auto const& value : json)
        {
            auto const game = value.GetObject();
            games.push_back({
                String(game, L"provider"),
                String(game, L"id"),
                String(game, L"url"),
                String(game, L"player_color"),
                String(game, L"display_name"),
                String(game, L"variant_id"),
                String(game, L"variant_name"),
                Boolean(game, L"rated"),
                String(game, L"speed"),
                Boolean(game, L"is_my_turn"),
            });
        }
        return games;
    }

    GameHistoryPage ParseGameHistoryPage(winrt::Windows::Data::Json::JsonObject const& json)
    {
        GameHistoryPage page;
        page.next_before_millis = OptionalNumber(json, L"next_before_millis");
        if (auto const games = Array(json, L"games"))
        {
            for (auto const& value : games)
            {
                auto const game = value.GetObject();
                GameHistoryEntry entry;
                entry.provider = String(game, L"provider");
                entry.id = String(game, L"id");
                entry.url = String(game, L"url");
                entry.analysis_url = String(game, L"analysis_url");
                entry.player_color = String(game, L"player_color");
                entry.opponent_name = String(game, L"opponent_name");
                entry.opponent_title = String(game, L"opponent_title");
                if (auto const rating = OptionalNumber(game, L"opponent_rating"))
                {
                    entry.opponent_rating = static_cast<std::uint32_t>(*rating);
                }
                if (auto const level = OptionalNumber(game, L"opponent_ai_level"))
                {
                    entry.opponent_ai_level = static_cast<std::uint32_t>(*level);
                }
                entry.variant_id = String(game, L"variant_id");
                entry.variant_name = String(game, L"variant_name");
                entry.rated = Boolean(game, L"rated");
                entry.speed = String(game, L"speed");
                entry.status = String(game, L"status");
                entry.winner = String(game, L"winner");
                entry.created_at_millis = static_cast<std::uint64_t>(
                    Number(game, L"created_at_millis"));
                entry.last_move_at_millis = static_cast<std::uint64_t>(
                    Number(game, L"last_move_at_millis"));
                page.games.push_back(std::move(entry));
            }
        }
        return page;
    }

    GameReview ParseGameReview(winrt::Windows::Data::Json::JsonObject const& json)
    {
        GameReview review;
        review.provider = String(json, L"provider");
        review.game_id = String(json, L"game_id");
        review.variant_id = String(json, L"variant_id");
        review.initial_fen = String(json, L"initial_fen");
        if (auto const opening = Object(json, L"opening"))
        {
            review.opening = GameOpening{
                String(opening, L"eco"),
                String(opening, L"name"),
                static_cast<std::uint32_t>(Number(opening, L"ply")),
            };
        }
        if (auto const moves = Array(json, L"moves"))
        {
            for (auto const& value : moves)
            {
                auto const move = value.GetObject();
                GameReviewMove parsed;
                parsed.ply = static_cast<std::uint32_t>(Number(move, L"ply"));
                parsed.san = String(move, L"san");
                parsed.move_id = String(move, L"move_id");
                parsed.clock_millis = OptionalNumber(move, L"clock_millis");
                if (auto const evaluation = Object(move, L"evaluation"))
                {
                    GameMoveEvaluation parsed_evaluation;
                    if (evaluation.HasKey(L"centipawns")
                        && evaluation.GetNamedValue(L"centipawns").ValueType()
                            == JsonValueType::Number)
                    {
                        parsed_evaluation.centipawns = static_cast<std::int32_t>(
                            evaluation.GetNamedNumber(L"centipawns"));
                    }
                    if (evaluation.HasKey(L"mate")
                        && evaluation.GetNamedValue(L"mate").ValueType()
                            == JsonValueType::Number)
                    {
                        parsed_evaluation.mate = static_cast<std::int32_t>(
                            evaluation.GetNamedNumber(L"mate"));
                    }
                    parsed_evaluation.best_move = String(evaluation, L"best_move");
                    parsed_evaluation.variation = String(evaluation, L"variation");
                    if (auto const judgment = Object(evaluation, L"judgment"))
                    {
                        parsed_evaluation.judgment_kind = String(judgment, L"kind");
                        parsed_evaluation.judgment_comment = String(judgment, L"comment");
                    }
                    parsed.evaluation = std::move(parsed_evaluation);
                }
                review.moves.push_back(std::move(parsed));
            }
        }
        return review;
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
