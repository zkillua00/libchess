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
        bool available{ false };
        winrt::hstring unavailable_reason;
        std::optional<BotGameOptions> bot_game_options;
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
        std::vector<LegalMove> legal_moves;
        winrt::hstring turn;
        std::uint32_t ply{ 0 };
        bool in_check{ false };
        std::optional<LegalMove> last_move;
    };

    struct LiveGame
    {
        winrt::hstring id;
        winrt::hstring provider;
        winrt::hstring player_color;
        winrt::hstring variant_name;
        winrt::hstring speed;
        winrt::hstring white_name;
        winrt::hstring black_name;
        winrt::hstring status;
        winrt::hstring winner;
        BoardState board;
    };

    struct BoardPresentation
    {
        RgbaColor light_square{ 240, 217, 181, 255 };
        RgbaColor dark_square{ 181, 136, 99, 255 };
        RgbaColor selection{ 246, 246, 105, 190 };
        RgbaColor legal_move{ 20, 20, 20, 90 };
        RgbaColor last_move{ 246, 246, 105, 135 };
        RgbaColor white_piece{ 245, 245, 245, 255 };
        RgbaColor black_piece{ 35, 35, 35, 255 };
        std::unordered_map<std::wstring, BoardAsset> assets;
    };

    Provider ParseProvider(winrt::Windows::Data::Json::JsonObject const& json);
    std::vector<Provider> ParseProviders(winrt::Windows::Data::Json::JsonArray const& json);
    BoardPresentation ParseBoardPresentation(winrt::Windows::Data::Json::JsonObject const& json);
    LiveGame ParseLiveGame(winrt::Windows::Data::Json::JsonObject const& json);
    LegalMove ParseLegalMove(winrt::Windows::Data::Json::JsonObject const& json);

    winrt::Windows::Data::Json::JsonObject ParseObject(std::string const& utf8);
    std::string ToUtf8(winrt::hstring const& value);
}
