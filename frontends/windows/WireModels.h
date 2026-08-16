#pragma once

namespace LibChess::Windows::Wire
{
    struct RgbaColor
    {
        std::uint8_t red{ 0 };
        std::uint8_t green{ 0 };
        std::uint8_t blue{ 0 };
        std::uint8_t alpha{ 255 };
    };

    struct BoardAsset
    {
        winrt::hstring kind;
        winrt::hstring value;
        bool tintable{ true };
    };

    struct BotOpponent
    {
        winrt::hstring id;
        winrt::hstring display_name;
    };

    struct GameVariant
    {
        winrt::hstring id;
        winrt::hstring display_name;
        bool supports_custom_position{ false };
        bool requires_custom_position{ false };
    };

    struct ClockTimeControlOptions
    {
        std::vector<std::uint32_t> initial_seconds;
        std::vector<std::uint32_t> increment_seconds;
        std::optional<std::uint32_t> minimum_estimated_duration_seconds;

        bool Supports(std::uint32_t initial, std::uint32_t increment) const
        {
            auto const advertised =
                std::find(initial_seconds.begin(), initial_seconds.end(), initial) != initial_seconds.end()
                && std::find(increment_seconds.begin(), increment_seconds.end(), increment) != increment_seconds.end();
            auto const estimated = static_cast<std::uint64_t>(initial)
                + static_cast<std::uint64_t>(increment) * 40;
            return advertised
                && (!minimum_estimated_duration_seconds
                    || estimated >= *minimum_estimated_duration_seconds);
        }
    };

    struct BotGameOptions
    {
        std::vector<BotOpponent> opponents;
        std::vector<GameVariant> variants;
        std::vector<winrt::hstring> colors;
        std::optional<ClockTimeControlOptions> clock;
        std::vector<std::uint32_t> correspondence_days;
        bool unlimited{ false };
        winrt::hstring default_opponent_id;
        winrt::hstring default_variant_id;
        winrt::hstring default_color;
        winrt::hstring default_time_control_json;
        std::uint32_t default_reply_delay_millis{ 0 };
        bool has_reply_delay{ false };
    };

    struct Provider
    {
        winrt::hstring id;
        winrt::hstring kind;
        winrt::hstring display_name;
        winrt::hstring subtitle;
        winrt::hstring description;
        winrt::hstring icon;
        winrt::hstring action_title;
        winrt::hstring connection_type;
        winrt::hstring authorization_origin;
        std::vector<winrt::hstring> capabilities;
        bool available{ false };
        winrt::hstring unavailable_reason;
        std::optional<BotGameOptions> bot_game_options;

        bool Supports(winrt::hstring const& capability) const
        {
            return std::find(capabilities.begin(), capabilities.end(), capability)
                != capabilities.end();
        }
    };

    struct LegalMove
    {
        winrt::hstring id;
        winrt::hstring from;
        winrt::hstring to;
        winrt::hstring promotion;
        winrt::hstring drop;
    };

    struct BoardPiece
    {
        winrt::hstring square;
        winrt::hstring color;
        winrt::hstring role;
        bool promoted{ false };
    };

    struct BoardState
    {
        std::vector<BoardPiece> pieces;
        struct PocketPiece
        {
            winrt::hstring color;
            winrt::hstring role;
            std::uint32_t count{ 0 };
        };
        std::vector<PocketPiece> pockets;
        std::vector<winrt::hstring> moves;
        std::vector<LegalMove> legal_moves;
        winrt::hstring turn;
        std::uint32_t ply{ 0 };
        bool in_check{ false };
        std::optional<LegalMove> last_move;
    };

    struct LiveGamePlayer
    {
        winrt::hstring id;
        winrt::hstring name;
        winrt::hstring title;
        std::optional<std::uint32_t> rating;
        std::optional<std::uint32_t> ai_level;
        bool provisional{ false };
    };

    struct LiveGame
    {
        winrt::hstring id;
        winrt::hstring provider;
        winrt::hstring player_color;
        winrt::hstring variant_name;
        winrt::hstring speed;
        winrt::hstring url;
        winrt::hstring initial_fen;
        winrt::hstring variant_id;
        LiveGamePlayer white;
        LiveGamePlayer black;
        winrt::hstring status;
        winrt::hstring winner;
        bool rated{ false };
        bool has_clock{ false };
        std::optional<std::uint64_t> initial_clock_millis;
        std::optional<std::uint64_t> clock_increment_millis;
        std::optional<std::uint64_t> white_time_millis;
        std::optional<std::uint64_t> black_time_millis;
        std::optional<std::uint64_t> white_increment_millis;
        std::optional<std::uint64_t> black_increment_millis;
        std::optional<std::uint32_t> days_per_turn;
        bool white_draw_offer{ false };
        bool black_draw_offer{ false };
        bool white_takeback_offer{ false };
        bool black_takeback_offer{ false };
        bool opponent_gone{ false };
        std::optional<std::uint32_t> claim_win_in_seconds;
        std::vector<winrt::hstring> san_moves;
        BoardState board;
    };

    struct LiveGameSummary
    {
        winrt::hstring provider;
        winrt::hstring id;
        winrt::hstring url;
        winrt::hstring player_color;
        winrt::hstring display_name;
        winrt::hstring variant_id;
        winrt::hstring variant_name;
        bool rated{ false };
        winrt::hstring speed;
        bool is_my_turn{ false };
    };

    struct GameHistoryEntry
    {
        winrt::hstring provider;
        winrt::hstring id;
        winrt::hstring url;
        winrt::hstring analysis_url;
        winrt::hstring player_color;
        winrt::hstring opponent_name;
        winrt::hstring opponent_title;
        std::optional<std::uint32_t> opponent_rating;
        std::optional<std::uint32_t> opponent_ai_level;
        winrt::hstring variant_id;
        winrt::hstring variant_name;
        bool rated{ false };
        winrt::hstring speed;
        winrt::hstring status;
        winrt::hstring winner;
        std::uint64_t created_at_millis{ 0 };
        std::uint64_t last_move_at_millis{ 0 };
    };

    struct GameHistoryPage
    {
        std::vector<GameHistoryEntry> games;
        std::optional<std::uint64_t> next_before_millis;
    };

    struct GameMoveEvaluation
    {
        std::optional<std::int32_t> centipawns;
        std::optional<std::int32_t> mate;
        winrt::hstring best_move;
        winrt::hstring variation;
        winrt::hstring judgment_kind;
        winrt::hstring judgment_comment;
    };

    struct GameReviewMove
    {
        std::uint32_t ply{ 0 };
        winrt::hstring san;
        winrt::hstring move_id;
        std::optional<std::uint64_t> clock_millis;
        std::optional<GameMoveEvaluation> evaluation;
    };

    struct GameOpening
    {
        winrt::hstring eco;
        winrt::hstring name;
        std::uint32_t ply{ 0 };
    };

    struct GameReview
    {
        winrt::hstring provider;
        winrt::hstring game_id;
        winrt::hstring variant_id;
        winrt::hstring initial_fen;
        std::optional<GameOpening> opening;
        std::vector<GameReviewMove> moves;
    };

    struct BoardMetrics
    {
        std::uint32_t maximum_extent{ 900 };
        std::uint32_t corner_radius{ 6 };
        std::uint32_t border_width{ 1 };
        std::uint32_t shadow_radius{ 10 };
        std::int32_t shadow_offset_y{ 5 };
        std::uint32_t coordinate_font_scale_percent{ 11 };
        std::uint32_t coordinate_inset{ 3 };
        std::uint32_t destination_dot_scale_percent{ 21 };
        std::uint32_t destination_ring_inset_percent{ 5 };
        std::uint32_t destination_ring_width_percent{ 6 };
        std::uint32_t check_gradient_radius_percent{ 53 };
    };

    struct PieceMetrics
    {
        std::uint32_t scale_percent{ 72 };
        std::uint32_t shadow_radius_tenths{ 7 };
        std::int32_t shadow_offset_y_tenths{ 5 };
        std::uint32_t promoted_marker_scale_percent{ 13 };
        std::uint32_t promoted_marker_inset{ 3 };
    };

    struct BoardAnimationRule
    {
        std::uint32_t duration_millis{ 0 };
        winrt::hstring curve;
        std::uint32_t extra_bounce_percent{ 0 };
    };

    struct BoardMotion
    {
        BoardAnimationRule board_resize;
        BoardAnimationRule piece_move{ 180, L"spring", 0 };
        BoardAnimationRule selection{ 120, L"ease_out", 0 };
        std::uint32_t piece_appearance_scale_percent{ 55 };
        bool fade_piece_appearance{ true };
        std::uint32_t maximum_animated_ply_distance{ 1 };
    };

    struct NamedBoardTheme
    {
        winrt::hstring id;
        winrt::hstring display_name;
    };

    struct BoardProvider
    {
        winrt::hstring id;
        winrt::hstring display_name;
        std::vector<NamedBoardTheme> board_themes;
        std::vector<NamedBoardTheme> piece_themes;
        winrt::hstring default_board_theme;
        winrt::hstring default_piece_theme;
    };

    struct BoardZoomPreset
    {
        winrt::hstring id;
        winrt::hstring display_name;
        std::uint32_t scale_percent{ 100 };
    };

    struct BoardPresentation
    {
        winrt::hstring provider;
        winrt::hstring board_theme;
        winrt::hstring piece_theme;
        RgbaColor light_square{ 240, 217, 181, 255 };
        RgbaColor dark_square{ 181, 136, 99, 255 };
        RgbaColor selection{ 246, 246, 105, 190 };
        RgbaColor legal_move{ 20, 20, 20, 90 };
        RgbaColor last_move{ 246, 246, 105, 135 };
        RgbaColor coordinate_on_light{ 181, 136, 99, 255 };
        RgbaColor coordinate_on_dark{ 240, 217, 181, 255 };
        RgbaColor check_center{ 220, 38, 38, 190 };
        RgbaColor check_edge{ 220, 38, 38, 0 };
        RgbaColor border{ 0, 0, 0, 64 };
        RgbaColor shadow{ 0, 0, 0, 46 };
        RgbaColor white_piece{ 245, 245, 245, 255 };
        RgbaColor black_piece{ 35, 35, 35, 255 };
        RgbaColor white_piece_shadow{ 0, 0, 0, 148 };
        RgbaColor black_piece_shadow{ 255, 255, 255, 82 };
        RgbaColor promoted_marker_color{ 255, 204, 0, 255 };
        BoardMetrics board_metrics;
        PieceMetrics piece_metrics;
        BoardMotion motion;
        std::vector<BoardZoomPreset> zoom_presets;
        winrt::hstring default_zoom_preset;
        BoardAsset promoted_marker;
        std::unordered_map<std::wstring, BoardAsset> assets;
    };

    Provider ParseProvider(winrt::Windows::Data::Json::JsonObject const& json);
    std::vector<Provider> ParseProviders(winrt::Windows::Data::Json::JsonArray const& json);
    std::vector<BoardProvider> ParseBoardProviders(
        winrt::Windows::Data::Json::JsonArray const& json);
    BoardPresentation ParseBoardPresentation(winrt::Windows::Data::Json::JsonObject const& json);
    BoardState ParseBoardState(winrt::Windows::Data::Json::JsonObject const& json);
    LiveGame ParseLiveGame(winrt::Windows::Data::Json::JsonObject const& json);
    std::vector<LiveGameSummary> ParseLiveGameSummaries(
        winrt::Windows::Data::Json::JsonArray const& json);
    GameHistoryPage ParseGameHistoryPage(winrt::Windows::Data::Json::JsonObject const& json);
    GameReview ParseGameReview(winrt::Windows::Data::Json::JsonObject const& json);
    LegalMove ParseLegalMove(winrt::Windows::Data::Json::JsonObject const& json);

    winrt::Windows::Data::Json::JsonObject ParseObject(std::string const& utf8);
    std::string ToUtf8(winrt::hstring const& value);
}
