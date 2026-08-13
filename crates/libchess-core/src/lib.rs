#![forbid(unsafe_code)]

use std::{collections::BTreeSet, fmt, sync::Arc};

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use zeroize::Zeroize;

mod live;

pub use live::*;

/// Stable identifier used by configuration and the frontend protocol.
#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(transparent)]
pub struct ProviderId(String);

impl ProviderId {
    pub fn new(value: impl Into<String>) -> Result<Self, LibChessError> {
        let value = value.into();
        let valid = !value.is_empty()
            && value.len() <= 64
            && value
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-');

        if valid {
            Ok(Self(value))
        } else {
            Err(LibChessError::invalid_input(
                "provider identifiers must contain only lowercase ASCII letters, digits, or '-'",
            ))
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for ProviderId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PlatformCapability {
    Account,
    BotGames,
    Challenges,
    GameHistory,
    GameReview,
    LiveGames,
    Matchmaking,
    #[serde(rename = "oauth_pkce")]
    OAuthPkce,
    PgnExport,
    RealtimeEvents,
}

#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(transparent)]
pub struct BotOpponentId(String);

impl BotOpponentId {
    pub fn new(value: impl Into<String>) -> Result<Self, LibChessError> {
        let value = value.into();
        let valid = !value.is_empty()
            && value.len() <= 64
            && value
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-');
        if valid {
            Ok(Self(value))
        } else {
            Err(LibChessError::invalid_input(
                "bot opponent identifiers must contain only lowercase ASCII letters, digits, or '-'",
            ))
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for BotOpponentId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct BotOpponent {
    pub id: BotOpponentId,
    pub display_name: String,
}

impl BotOpponent {
    pub fn new(
        id: impl Into<String>,
        display_name: impl Into<String>,
    ) -> Result<Self, LibChessError> {
        let display_name = display_name.into();
        if display_name.is_empty() || display_name.len() > 128 {
            return Err(LibChessError::invalid_input(
                "the bot opponent display name must contain between 1 and 128 bytes",
            ));
        }

        Ok(Self {
            id: BotOpponentId::new(id)?,
            display_name,
        })
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ProviderDescriptor {
    pub id: ProviderId,
    pub display_name: String,
    pub web_url: String,
    pub capabilities: BTreeSet<PlatformCapability>,
    #[serde(default)]
    pub bot_opponents: Vec<BotOpponent>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bot_game_options: Option<BotGameOptions>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Account {
    pub provider: ProviderId,
    pub id: String,
    pub username: String,
    pub title: Option<String>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ColorPreference {
    White,
    Black,
    Random,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PlayerColor {
    White,
    Black,
}

#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(transparent)]
pub struct GameVariantId(String);

impl GameVariantId {
    pub fn new(value: impl Into<String>) -> Result<Self, LibChessError> {
        let value = value.into();
        let valid = !value.is_empty()
            && value.len() <= 64
            && value
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-');
        if valid {
            Ok(Self(value))
        } else {
            Err(LibChessError::invalid_input(
                "game variant identifiers must contain only lowercase ASCII letters, digits, or '-'",
            ))
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for GameVariantId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct GameVariant {
    pub id: GameVariantId,
    pub display_name: String,
    pub supports_custom_position: bool,
    pub requires_custom_position: bool,
}

impl GameVariant {
    pub fn new(
        id: impl Into<String>,
        display_name: impl Into<String>,
        supports_custom_position: bool,
        requires_custom_position: bool,
    ) -> Result<Self, LibChessError> {
        let display_name = display_name.into();
        if display_name.is_empty() || display_name.len() > 128 {
            return Err(LibChessError::invalid_input(
                "the game variant display name must contain between 1 and 128 bytes",
            ));
        }
        if requires_custom_position && !supports_custom_position {
            return Err(LibChessError::invalid_input(
                "a game variant cannot require an unsupported custom position",
            ));
        }

        Ok(Self {
            id: GameVariantId::new(id)?,
            display_name,
            supports_custom_position,
            requires_custom_position,
        })
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ClockTimeControl {
    pub initial_seconds: u32,
    pub increment_seconds: u32,
}

impl ClockTimeControl {
    pub fn new(initial_seconds: u32, increment_seconds: u32) -> Self {
        Self {
            initial_seconds,
            increment_seconds,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum BotGameTimeControl {
    Clock {
        initial_seconds: u32,
        increment_seconds: u32,
    },
    Correspondence {
        days_per_move: u8,
    },
    Unlimited,
}

impl BotGameTimeControl {
    pub fn clock(initial_seconds: u32, increment_seconds: u32) -> Self {
        Self::Clock {
            initial_seconds,
            increment_seconds,
        }
    }

    pub fn correspondence(days_per_move: u8) -> Self {
        Self::Correspondence { days_per_move }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ClockTimeControlOptions {
    pub initial_seconds: Vec<u32>,
    pub increment_seconds: Vec<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub minimum_estimated_duration_seconds: Option<u32>,
}

impl ClockTimeControlOptions {
    pub fn supports(&self, initial_seconds: u32, increment_seconds: u32) -> bool {
        let advertised = self.initial_seconds.contains(&initial_seconds)
            && self.increment_seconds.contains(&increment_seconds);
        let estimated_duration =
            initial_seconds.saturating_add(increment_seconds.saturating_mul(40));
        advertised
            && self
                .minimum_estimated_duration_seconds
                .is_none_or(|minimum| estimated_duration >= minimum)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct BotGameOptions {
    pub variants: Vec<GameVariant>,
    pub colors: BTreeSet<ColorPreference>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub clock: Option<ClockTimeControlOptions>,
    #[serde(default)]
    pub correspondence_days: Vec<u8>,
    pub unlimited: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct BotGameRequest {
    pub opponent_id: BotOpponentId,
    pub variant_id: GameVariantId,
    pub time_control: BotGameTimeControl,
    pub color: ColorPreference,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub initial_fen: Option<String>,
}

impl BotGameRequest {
    pub fn new(
        opponent_id: impl Into<String>,
        variant_id: impl Into<String>,
        time_control: BotGameTimeControl,
        color: ColorPreference,
        initial_fen: Option<String>,
    ) -> Result<Self, LibChessError> {
        let initial_fen = initial_fen
            .map(|fen| fen.trim().to_owned())
            .filter(|fen| !fen.is_empty());
        if let Some(fen) = &initial_fen
            && (fen.len() > 1024
                || !fen
                    .bytes()
                    .all(|byte| byte == b' ' || byte.is_ascii_graphic()))
        {
            return Err(LibChessError::invalid_input(
                "the initial FEN must be a single ASCII line no longer than 1024 bytes",
            ));
        }

        Ok(Self {
            opponent_id: BotOpponentId::new(opponent_id)?,
            variant_id: GameVariantId::new(variant_id)?,
            time_control,
            color,
            initial_fen,
        })
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct BotGame {
    pub provider: ProviderId,
    pub id: String,
    pub url: String,
    pub player_color: PlayerColor,
    pub opponent: BotOpponent,
    pub variant: GameVariant,
    pub time_control: BotGameTimeControl,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub initial_fen: Option<String>,
}

/// Deliberately redacts its value from logs and panic messages.
pub struct AccessToken(String);

impl AccessToken {
    pub fn new(value: impl Into<String>) -> Result<Self, LibChessError> {
        let value = value.into();
        if value.is_empty() {
            return Err(LibChessError::invalid_input("the access token is empty"));
        }
        if value.len() > 4096 {
            return Err(LibChessError::invalid_input(
                "the access token is unexpectedly long",
            ));
        }
        if !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"-._~+/=".contains(&byte))
        {
            return Err(LibChessError::invalid_input(
                "the access token contains unsupported characters",
            ));
        }
        Ok(Self(value))
    }

    pub fn expose(&self) -> &str {
        &self.0
    }

    pub fn duplicate(&self) -> Self {
        Self(self.0.clone())
    }
}

impl fmt::Debug for AccessToken {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("AccessToken([REDACTED])")
    }
}

impl Drop for AccessToken {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct OAuthClientConfiguration {
    pub client_id: String,
    pub redirect_uri: String,
}

impl OAuthClientConfiguration {
    pub fn new(
        client_id: impl Into<String>,
        redirect_uri: impl Into<String>,
    ) -> Result<Self, LibChessError> {
        let client_id = client_id.into();
        let redirect_uri = redirect_uri.into();

        if client_id.is_empty() || client_id.len() > 128 {
            return Err(LibChessError::invalid_input(
                "the OAuth client identifier must contain between 1 and 128 bytes",
            ));
        }
        if client_id.chars().any(char::is_whitespace) {
            return Err(LibChessError::invalid_input(
                "the OAuth client identifier cannot contain whitespace",
            ));
        }
        if redirect_uri.is_empty() || redirect_uri.len() > 2048 {
            return Err(LibChessError::invalid_input(
                "the OAuth redirect URI must contain between 1 and 2048 bytes",
            ));
        }

        Ok(Self {
            client_id,
            redirect_uri,
        })
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct OAuthAuthorization {
    pub provider: ProviderId,
    pub authorization_url: String,
    pub scopes: Vec<String>,
}

pub struct OAuthToken {
    pub access_token: AccessToken,
    pub expires_in_seconds: u64,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorKind {
    Authentication,
    InvalidInput,
    Network,
    Provider,
    RateLimited,
    Unsupported,
}

#[derive(Clone, Debug, Deserialize, Error, Eq, PartialEq, Serialize)]
#[error("{message}")]
pub struct LibChessError {
    pub kind: ErrorKind,
    pub message: String,
    pub retryable: bool,
}

impl LibChessError {
    pub fn new(kind: ErrorKind, message: impl Into<String>, retryable: bool) -> Self {
        Self {
            kind,
            message: message.into(),
            retryable,
        }
    }

    pub fn invalid_input(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::InvalidInput, message, false)
    }

    pub fn unsupported(message: impl Into<String>) -> Self {
        Self::new(ErrorKind::Unsupported, message, false)
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ChessContext {
    Analysis,
    LocalComputerGame,
    LiveOnlineCasual,
    LiveOnlineRated,
    PostGameReview,
}

pub fn ensure_engine_allowed(context: ChessContext) -> Result<(), LibChessError> {
    match context {
        ChessContext::LiveOnlineCasual | ChessContext::LiveOnlineRated => Err(
            LibChessError::unsupported("engine use is disabled during every live online game"),
        ),
        ChessContext::Analysis | ChessContext::LocalComputerGame | ChessContext::PostGameReview => {
            Ok(())
        }
    }
}

#[async_trait]
pub trait PlatformBackend: Send + Sync {
    fn descriptor(&self) -> &ProviderDescriptor;

    async fn account(&self) -> Result<Account, LibChessError>;

    async fn create_bot_game(&self, _request: BotGameRequest) -> Result<BotGame, LibChessError> {
        Err(LibChessError::unsupported(format!(
            "provider '{}' does not support bot games",
            self.descriptor().id
        )))
    }

    async fn watch_live_game(
        &self,
        _request: LiveGameRequest,
        _events: LiveGameEventSink,
    ) -> Result<(), LibChessError> {
        Err(LibChessError::unsupported(format!(
            "provider '{}' does not support live games",
            self.descriptor().id
        )))
    }

    async fn live_games(&self) -> Result<Vec<LiveGameSummary>, LibChessError> {
        Err(LibChessError::unsupported(format!(
            "provider '{}' does not expose ongoing games",
            self.descriptor().id
        )))
    }

    async fn game_history(
        &self,
        _request: GameHistoryRequest,
    ) -> Result<GameHistoryPage, LibChessError> {
        Err(LibChessError::unsupported(format!(
            "provider '{}' does not expose game history",
            self.descriptor().id
        )))
    }

    async fn export_game(&self, _game_id: GameId) -> Result<GameExport, LibChessError> {
        Err(LibChessError::unsupported(format!(
            "provider '{}' does not support PGN export",
            self.descriptor().id
        )))
    }

    async fn review_game(&self, _game_id: GameId) -> Result<GameReview, LibChessError> {
        Err(LibChessError::unsupported(format!(
            "provider '{}' does not support game review",
            self.descriptor().id
        )))
    }

    async fn watch_live_game_catalog(
        &self,
        _events: LiveGameCatalogEventSink,
    ) -> Result<(), LibChessError> {
        Err(LibChessError::unsupported(format!(
            "provider '{}' does not expose realtime game events",
            self.descriptor().id
        )))
    }

    async fn play_move(&self, _submission: MoveSubmission) -> Result<(), LibChessError> {
        Err(LibChessError::unsupported(format!(
            "provider '{}' does not support live moves",
            self.descriptor().id
        )))
    }

    async fn perform_game_action(
        &self,
        _game_id: GameId,
        _action: LiveGameAction,
    ) -> Result<(), LibChessError> {
        Err(LibChessError::unsupported(format!(
            "provider '{}' does not support live game actions",
            self.descriptor().id
        )))
    }
}

#[async_trait]
pub trait PlatformOAuthSession: Send {
    fn authorization(&self) -> &OAuthAuthorization;

    async fn exchange(self: Box<Self>, callback_url: &str) -> Result<OAuthToken, LibChessError>;
}

pub trait PlatformBackendFactory: Send + Sync {
    fn descriptor(&self) -> &ProviderDescriptor;

    fn create(&self, token: AccessToken) -> Result<Arc<dyn PlatformBackend>, LibChessError>;

    fn begin_oauth(
        &self,
        _configuration: OAuthClientConfiguration,
    ) -> Result<Box<dyn PlatformOAuthSession>, LibChessError> {
        Err(LibChessError::unsupported(format!(
            "provider '{}' does not support OAuth PKCE",
            self.descriptor().id
        )))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn access_tokens_are_redacted() {
        let token = AccessToken::new("lio_secret123").expect("valid token");
        assert_eq!(format!("{token:?}"), "AccessToken([REDACTED])");
        assert!(AccessToken::new("opaque-._~+/=").is_ok());
        assert!(AccessToken::new("unsafe\ntoken").is_err());
    }

    #[test]
    fn oauth_configuration_rejects_ambiguous_values() {
        assert!(OAuthClientConfiguration::new("libchess", "org.libchess://oauth").is_ok());
        assert!(OAuthClientConfiguration::new("", "org.libchess://oauth").is_err());
        assert!(OAuthClientConfiguration::new("lib chess", "org.libchess://oauth").is_err());
        assert!(OAuthClientConfiguration::new("libchess", "").is_err());
    }

    #[test]
    fn engine_is_never_allowed_during_online_play() {
        assert!(ensure_engine_allowed(ChessContext::LiveOnlineCasual).is_err());
        assert!(ensure_engine_allowed(ChessContext::LiveOnlineRated).is_err());
        assert!(ensure_engine_allowed(ChessContext::PostGameReview).is_ok());
    }

    #[test]
    fn bot_game_requests_validate_identifiers_and_custom_positions() {
        assert!(
            BotGameRequest::new(
                "level-1",
                "standard",
                BotGameTimeControl::clock(180, 0),
                ColorPreference::White,
                None,
            )
            .is_ok()
        );
        assert!(
            BotGameRequest::new(
                "Level 1",
                "standard",
                BotGameTimeControl::Unlimited,
                ColorPreference::Black,
                None,
            )
            .is_err()
        );
        assert!(
            BotGameRequest::new(
                "level-4",
                "Chess960",
                BotGameTimeControl::correspondence(3),
                ColorPreference::Random,
                None,
            )
            .is_err()
        );
        assert!(
            BotGameRequest::new(
                "level-4",
                "from-position",
                BotGameTimeControl::Unlimited,
                ColorPreference::Random,
                Some("8/8/8/8/8/8/8/K6k w - - 0 1\ninvalid".to_owned()),
            )
            .is_err()
        );
    }

    #[test]
    fn clock_options_support_exact_ranges_and_speed_floors() {
        let options = ClockTimeControlOptions {
            initial_seconds: vec![0, 15, 30, 45, 60, 90, 120, 180, 300, 10_800],
            increment_seconds: (0..=60).collect(),
            minimum_estimated_duration_seconds: Some(180),
        };

        assert!(options.supports(180, 0));
        assert!(options.supports(0, 5));
        assert!(!options.supports(0, 4));
        assert!(!options.supports(75, 5));
        assert!(!options.supports(10_801, 0));
        assert!(!options.supports(300, 61));
    }

    #[test]
    fn provider_ids_are_safe_protocol_keys() {
        assert!(ProviderId::new("chess-com").is_ok());
        assert!(ProviderId::new("Chess.com").is_err());
        assert!(ProviderId::new("").is_err());
    }

    #[test]
    fn oauth_capability_has_a_stable_wire_name() {
        assert_eq!(
            serde_json::to_string(&PlatformCapability::OAuthPkce).expect("serialize capability"),
            r#""oauth_pkce""#
        );
    }
}
