#![forbid(unsafe_code)]

use std::{
    collections::BTreeSet,
    sync::Arc,
    time::{Duration, Instant},
};

use async_trait::async_trait;
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use libchess_core::{
    AccessToken, Account, BackendConnection, BackendIcon, BackendKind, BotGame, BotGameOptions,
    BotGameRequest, BotGameTimeControl, BotOpponent, BotOpponentId, ClockTimeControlOptions,
    ColorPreference, ErrorKind, GameVariant, GameVariantId, LibChessError, OAuthAuthorization,
    OAuthClientConfiguration, OAuthToken, PlatformBackend, PlatformBackendFactory,
    PlatformCapability, PlatformOAuthSession, PlayerColor, ProviderDescriptor, ProviderId,
};
use reqwest::{Client, StatusCode, Url, header};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use zeroize::Zeroizing;

mod history;
mod live;

const DEFAULT_BASE_URL: &str = "https://lichess.org/";
const OAUTH_SESSION_TTL: Duration = Duration::from_secs(10 * 60);
const OAUTH_SCOPES: [&str; 1] = ["board:play"];
const LICHESS_VARIANTS: [(&str, &str, &str, bool, bool); 10] = [
    ("standard", "standard", "Standard", true, false),
    ("chess960", "chess960", "Chess960", true, false),
    ("crazyhouse", "crazyhouse", "Crazyhouse", false, false),
    ("antichess", "antichess", "Antichess", false, false),
    ("atomic", "atomic", "Atomic", false, false),
    ("horde", "horde", "Horde", false, false),
    (
        "king-of-the-hill",
        "kingOfTheHill",
        "King of the Hill",
        false,
        false,
    ),
    ("racing-kings", "racingKings", "Racing Kings", false, false),
    ("three-check", "threeCheck", "Three-check", false, false),
    ("from-position", "fromPosition", "From Position", true, true),
];

pub struct LichessFactory {
    descriptor: ProviderDescriptor,
    base_url: Url,
}

impl Default for LichessFactory {
    fn default() -> Self {
        Self::new(DEFAULT_BASE_URL).expect("the built-in Lichess URL is valid")
    }
}

impl LichessFactory {
    pub fn new(base_url: &str) -> Result<Self, LibChessError> {
        let base_url = Url::parse(base_url).map_err(|error| {
            LibChessError::invalid_input(format!("invalid provider base URL: {error}"))
        })?;

        // Descriptors report the capabilities implemented by this adapter
        // build, not every capability offered by the remote platform.
        let capabilities = BTreeSet::from([
            PlatformCapability::Account,
            PlatformCapability::BotGames,
            PlatformCapability::GameHistory,
            PlatformCapability::GameReview,
            PlatformCapability::LiveGames,
            PlatformCapability::OAuthPkce,
            PlatformCapability::PgnExport,
            PlatformCapability::RealtimeEvents,
        ]);
        let bot_opponents = (1_u8..=8)
            .map(|level| {
                BotOpponent::new(format!("level-{level}"), format!("Stockfish level {level}"))
            })
            .collect::<Result<Vec<_>, _>>()?;
        let variants = LICHESS_VARIANTS
            .iter()
            .map(
                |(id, _, display_name, supports_custom_position, requires_custom_position)| {
                    GameVariant::new(
                        *id,
                        *display_name,
                        *supports_custom_position,
                        *requires_custom_position,
                        false,
                    )
                },
            )
            .collect::<Result<Vec<_>, _>>()?;
        let bot_game_options = BotGameOptions {
            variants,
            colors: BTreeSet::from([
                ColorPreference::White,
                ColorPreference::Random,
                ColorPreference::Black,
            ]),
            clock: Some(ClockTimeControlOptions {
                initial_seconds: [0, 15, 30, 45, 60, 90]
                    .into_iter()
                    .chain((2..=180).map(|minutes| minutes * 60))
                    .collect(),
                increment_seconds: (0..=60).collect(),
                minimum_estimated_duration_seconds: Some(180),
            }),
            correspondence_days: vec![1, 2, 3, 5, 7, 10, 14],
            unlimited: true,
            reply_delay: None,
            default_opponent_id: BotOpponentId::new("level-4")?,
            default_variant_id: GameVariantId::new("standard")?,
            default_time_control: BotGameTimeControl::clock(600, 0),
            default_color: ColorPreference::Random,
        };

        Ok(Self {
            descriptor: ProviderDescriptor {
                id: ProviderId::new("lichess")?,
                kind: BackendKind::Platform,
                display_name: "Lichess".to_owned(),
                subtitle: "Online chess service".to_owned(),
                description: "Play online games and computer opponents using your Lichess account."
                    .to_owned(),
                icon: BackendIcon::Network,
                action_title: "Use Lichess".to_owned(),
                web_url: Some(base_url.to_string()),
                connection: BackendConnection::OAuthPkce {
                    client_id: "org.libchess.macos".to_owned(),
                    redirect_uri: "org.libchess.macos://oauth/lichess".to_owned(),
                    authorization_origin: base_url.origin().ascii_serialization(),
                },
                available: true,
                unavailable_reason: None,
                capabilities,
                bot_opponents,
                bot_game_options: Some(bot_game_options),
            },
            base_url,
        })
    }
}

impl PlatformBackendFactory for LichessFactory {
    fn descriptor(&self) -> &ProviderDescriptor {
        &self.descriptor
    }

    fn create(&self, token: AccessToken) -> Result<Arc<dyn PlatformBackend>, LibChessError> {
        Ok(Arc::new(LichessBackend::new(
            self.descriptor.clone(),
            self.base_url.clone(),
            token,
        )?))
    }

    fn begin_oauth(
        &self,
        configuration: OAuthClientConfiguration,
    ) -> Result<Box<dyn PlatformOAuthSession>, LibChessError> {
        Ok(Box::new(LichessOAuthSession::new(
            self.descriptor.id.clone(),
            self.base_url.clone(),
            configuration,
        )?))
    }
}

struct LichessOAuthSession {
    authorization: OAuthAuthorization,
    base_url: Url,
    client_id: String,
    redirect_uri: Url,
    state: Zeroizing<String>,
    code_verifier: Zeroizing<String>,
    created_at: Instant,
    http: Client,
}

impl LichessOAuthSession {
    fn new(
        provider: ProviderId,
        base_url: Url,
        configuration: OAuthClientConfiguration,
    ) -> Result<Self, LibChessError> {
        let redirect_uri = validate_redirect_uri(&configuration.redirect_uri)?;
        let state = Zeroizing::new(random_urlsafe::<32>()?);
        let code_verifier = Zeroizing::new(random_urlsafe::<64>()?);
        let code_challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(code_verifier.as_bytes()));
        let scopes = OAUTH_SCOPES
            .iter()
            .map(|scope| (*scope).to_owned())
            .collect::<Vec<_>>();

        let mut authorization_url = endpoint(&base_url, "oauth")?;
        authorization_url
            .query_pairs_mut()
            .append_pair("response_type", "code")
            .append_pair("client_id", &configuration.client_id)
            .append_pair("redirect_uri", redirect_uri.as_str())
            .append_pair("code_challenge_method", "S256")
            .append_pair("code_challenge", &code_challenge)
            .append_pair("scope", &scopes.join(" "))
            .append_pair("state", &state);

        Ok(Self {
            authorization: OAuthAuthorization {
                provider,
                authorization_url: authorization_url.into(),
                scopes,
            },
            base_url,
            client_id: configuration.client_id,
            redirect_uri,
            state,
            code_verifier,
            created_at: Instant::now(),
            http: build_http_client()?,
        })
    }

    fn validate_callback(&self, callback_url: &str) -> Result<String, LibChessError> {
        if self.created_at.elapsed() > OAUTH_SESSION_TTL {
            return Err(authentication_error(
                "the OAuth authorization request expired; start sign-in again",
            ));
        }

        let callback = Url::parse(callback_url).map_err(|error| {
            LibChessError::invalid_input(format!("invalid OAuth callback URL: {error}"))
        })?;
        if !same_redirect_target(&self.redirect_uri, &callback) {
            return Err(authentication_error(
                "the OAuth callback target did not match the authorization request",
            ));
        }

        let returned_state = unique_query_value(&callback, "state")?
            .ok_or_else(|| authentication_error("the OAuth callback did not include state"))?;
        let state_matches: bool = self
            .state
            .as_bytes()
            .ct_eq(returned_state.as_bytes())
            .into();
        if !state_matches {
            return Err(authentication_error(
                "the OAuth callback state did not match the authorization request",
            ));
        }

        if let Some(error) = unique_query_value(&callback, "error")? {
            let description = unique_query_value(&callback, "error_description")?
                .unwrap_or_else(|| error.clone());
            return Err(authentication_error(format!(
                "Lichess authorization was not completed: {}",
                truncate(&description, 256)
            )));
        }

        let code = unique_query_value(&callback, "code")?
            .ok_or_else(|| authentication_error("the OAuth callback did not include a code"))?;
        validate_authorization_code(&code)?;
        Ok(code)
    }
}

#[async_trait]
impl PlatformOAuthSession for LichessOAuthSession {
    fn authorization(&self) -> &OAuthAuthorization {
        &self.authorization
    }

    async fn exchange(self: Box<Self>, callback_url: &str) -> Result<OAuthToken, LibChessError> {
        let code = self.validate_callback(callback_url)?;
        let request = OAuthTokenRequest {
            grant_type: "authorization_code",
            code: &code,
            code_verifier: &self.code_verifier,
            redirect_uri: self.redirect_uri.as_str(),
            client_id: &self.client_id,
        };
        let response = self
            .http
            .post(endpoint(&self.base_url, "api/token")?)
            .header(header::ACCEPT, "application/json")
            .form(&request)
            .timeout(Duration::from_secs(15))
            .send()
            .await
            .map_err(map_transport_error)?;

        let status = response.status();
        if !status.is_success() {
            if status == StatusCode::BAD_REQUEST {
                let oauth_error = response.json::<OAuthErrorResponse>().await.ok();
                let detail = oauth_error
                    .and_then(|error| error.error_description.or(error.message).or(error.error))
                    .map(|message| truncate(&message, 256));
                let message = detail.map_or_else(
                    || "Lichess rejected the OAuth authorization code".to_owned(),
                    |detail| format!("Lichess rejected the OAuth authorization code: {detail}"),
                );
                return Err(authentication_error(message));
            }
            return Err(map_status(status));
        }

        let token = response
            .json::<OAuthTokenResponse>()
            .await
            .map_err(|error| {
                LibChessError::new(
                    ErrorKind::Provider,
                    format!("Lichess returned an invalid OAuth token response: {error}"),
                    false,
                )
            })?;
        if !token.token_type.eq_ignore_ascii_case("bearer") || token.expires_in == 0 {
            return Err(LibChessError::new(
                ErrorKind::Provider,
                "Lichess returned unsupported OAuth token metadata",
                false,
            ));
        }

        Ok(OAuthToken {
            access_token: AccessToken::new(token.access_token)?,
            expires_in_seconds: token.expires_in,
        })
    }
}

struct LichessBackend {
    descriptor: ProviderDescriptor,
    base_url: Url,
    token: AccessToken,
    http: Client,
}

impl LichessBackend {
    fn new(
        descriptor: ProviderDescriptor,
        base_url: Url,
        token: AccessToken,
    ) -> Result<Self, LibChessError> {
        let http = build_http_client()?;

        Ok(Self {
            descriptor,
            base_url,
            token,
            http,
        })
    }

    fn endpoint(&self, path: &str) -> Result<Url, LibChessError> {
        endpoint(&self.base_url, path)
    }
}

#[async_trait]
impl PlatformBackend for LichessBackend {
    fn descriptor(&self) -> &ProviderDescriptor {
        &self.descriptor
    }

    async fn account(&self) -> Result<Account, LibChessError> {
        let response = self
            .http
            .get(self.endpoint("api/account")?)
            .header(header::ACCEPT, "application/json")
            .bearer_auth(self.token.expose())
            .timeout(Duration::from_secs(15))
            .send()
            .await
            .map_err(map_transport_error)?;

        let status = response.status();
        if !status.is_success() {
            return Err(map_status(status));
        }

        let account: LichessAccount = response.json().await.map_err(|error| {
            LibChessError::new(
                ErrorKind::Provider,
                format!("Lichess returned an invalid account response: {error}"),
                false,
            )
        })?;

        Ok(Account {
            provider: self.descriptor.id.clone(),
            id: account.id,
            username: account.username,
            title: account.title,
        })
    }

    async fn create_bot_game(&self, request: BotGameRequest) -> Result<BotGame, LibChessError> {
        let opponent = self
            .descriptor
            .bot_opponents
            .iter()
            .find(|opponent| opponent.id == request.opponent_id)
            .cloned()
            .ok_or_else(|| {
                LibChessError::invalid_input(format!(
                    "Lichess does not advertise bot opponent '{}'",
                    request.opponent_id
                ))
            })?;
        let level = opponent
            .id
            .as_str()
            .strip_prefix("level-")
            .and_then(|value| value.parse::<u8>().ok())
            .filter(|level| (1..=8).contains(level))
            .ok_or_else(|| {
                LibChessError::new(
                    ErrorKind::Provider,
                    "the installed Lichess bot catalog is invalid",
                    false,
                )
            })?;
        let options = self.descriptor.bot_game_options.as_ref().ok_or_else(|| {
            LibChessError::new(
                ErrorKind::Provider,
                "the installed Lichess bot-game options are missing",
                false,
            )
        })?;
        if !options.colors.contains(&request.color) {
            return Err(LibChessError::invalid_input(
                "Lichess does not advertise the requested player color",
            ));
        }
        if request.reply_delay_millis.is_some() {
            return Err(LibChessError::invalid_input(
                "Lichess does not advertise a configurable bot reply delay",
            ));
        }
        if !request.initial_moves.is_empty() {
            return Err(LibChessError::invalid_input(
                "Lichess does not advertise preloaded move history",
            ));
        }
        let requested_variant = options
            .variants
            .iter()
            .find(|variant| variant.id == request.variant_id)
            .cloned()
            .ok_or_else(|| {
                LibChessError::invalid_input(format!(
                    "Lichess does not advertise game variant '{}'",
                    request.variant_id
                ))
            })?;
        if requested_variant.requires_custom_position && request.initial_fen.is_none() {
            return Err(LibChessError::invalid_input(format!(
                "{} requires a custom initial position",
                requested_variant.display_name
            )));
        }
        if request.initial_fen.is_some() && !requested_variant.supports_custom_position {
            return Err(LibChessError::invalid_input(format!(
                "{} does not support a custom initial position",
                requested_variant.display_name
            )));
        }
        let provider_variant = provider_variant_key(&request.variant_id).ok_or_else(|| {
            LibChessError::new(
                ErrorKind::Provider,
                "the installed Lichess variant catalog is invalid",
                false,
            )
        })?;

        let (clock_limit, clock_increment, days) = match &request.time_control {
            BotGameTimeControl::Clock {
                initial_seconds,
                increment_seconds,
            } => {
                let clock = options.clock.as_ref().ok_or_else(|| {
                    LibChessError::invalid_input("Lichess does not advertise clock games")
                })?;
                if !clock.supports(*initial_seconds, *increment_seconds) {
                    return Err(LibChessError::invalid_input(
                        "Lichess clock games must use advertised values at blitz speed or slower",
                    ));
                }
                (Some(*initial_seconds), Some(*increment_seconds), None)
            }
            BotGameTimeControl::Correspondence { days_per_move } => {
                if !options.correspondence_days.contains(days_per_move) {
                    return Err(LibChessError::invalid_input(
                        "Lichess does not advertise the requested correspondence interval",
                    ));
                }
                (None, None, Some(*days_per_move))
            }
            BotGameTimeControl::Unlimited => {
                if !options.unlimited {
                    return Err(LibChessError::invalid_input(
                        "Lichess does not advertise unlimited bot games",
                    ));
                }
                (None, None, None)
            }
        };

        // Lichess's challenge response calls the side to move `player`; it is
        // not the authenticated user's color. Resolve random locally so the
        // adapter knows the exact point of view before opening the game stream.
        let (provider_color, player_color) = resolve_color(request.color)?;
        let form = LichessAiChallengeRequest {
            level,
            clock_limit,
            clock_increment,
            days,
            color: provider_color,
            variant: provider_variant,
            fen: request.initial_fen.as_deref(),
        };
        let response = self
            .http
            .post(self.endpoint("api/challenge/ai")?)
            .header(header::ACCEPT, "application/json")
            .bearer_auth(self.token.expose())
            .form(&form)
            .timeout(Duration::from_secs(15))
            .send()
            .await
            .map_err(map_transport_error)?;

        let status = response.status();
        if !status.is_success() {
            if status == StatusCode::BAD_REQUEST {
                let detail = response
                    .json::<LichessErrorResponse>()
                    .await
                    .ok()
                    .and_then(|response| response.error)
                    .map(|message| truncate(&message, 256));
                let message = detail.map_or_else(
                    || "Lichess rejected the bot game settings".to_owned(),
                    |detail| format!("Lichess rejected the bot game settings: {detail}"),
                );
                return Err(LibChessError::invalid_input(message));
            }
            return Err(map_status(status));
        }

        let game = response.json::<LichessAiGame>().await.map_err(|error| {
            LibChessError::new(
                ErrorKind::Provider,
                format!("Lichess returned an invalid bot game response: {error}"),
                false,
            )
        })?;
        validate_game_id(&game.id)?;
        let response_variant_id = canonical_variant_id(&game.variant.key).ok_or_else(|| {
            LibChessError::new(
                ErrorKind::Provider,
                "Lichess returned an unknown bot-game variant",
                false,
            )
        })?;
        let response_variant = options
            .variants
            .iter()
            .find(|variant| variant.id.as_str() == response_variant_id)
            .cloned()
            .ok_or_else(|| {
                LibChessError::new(
                    ErrorKind::Provider,
                    "Lichess returned a variant outside its advertised catalog",
                    false,
                )
            })?;
        let normalized_custom_standard = request.initial_fen.is_some()
            && request.variant_id.as_str() == "standard"
            && response_variant.id.as_str() == "from-position";
        let normalized_initial_position = request.initial_fen.is_some()
            && request.variant_id.as_str() == "from-position"
            && response_variant.id.as_str() == "standard";
        if (response_variant.id != request.variant_id
            && !normalized_custom_standard
            && !normalized_initial_position)
            || game.rated
        {
            return Err(LibChessError::new(
                ErrorKind::Provider,
                "Lichess returned a bot game outside the requested variant or casual mode",
                false,
            ));
        }
        if game.speed.is_empty()
            || game.speed.len() > 64
            || !game
                .speed
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
        {
            return Err(LibChessError::new(
                ErrorKind::Provider,
                "Lichess returned an invalid game speed",
                false,
            ));
        }
        let initial_fen = request.initial_fen.as_deref().unwrap_or("startpos");
        let initial_board =
            libchess_rules::reconstruct(response_variant.id.as_str(), initial_fen, &[]).map_err(
                |error| {
                    LibChessError::new(
                        ErrorKind::Provider,
                        format!("Lichess returned an invalid starting position: {error}"),
                        false,
                    )
                },
            )?;
        let game_url = self.endpoint(&game.id)?;

        Ok(BotGame {
            provider: self.descriptor.id.clone(),
            id: game.id,
            url: game_url.into(),
            player_color,
            opponent,
            variant: response_variant,
            time_control: request.time_control,
            speed: game.speed,
            is_my_turn: initial_board.turn == player_color,
            initial_fen: request.initial_fen,
        })
    }

    async fn watch_live_game(
        &self,
        request: libchess_core::LiveGameRequest,
        events: libchess_core::LiveGameEventSink,
    ) -> Result<(), LibChessError> {
        live::watch(self, request, events).await
    }

    async fn live_games(&self) -> Result<Vec<libchess_core::LiveGameSummary>, LibChessError> {
        live::list_games(self).await
    }

    async fn game_history(
        &self,
        request: libchess_core::GameHistoryRequest,
    ) -> Result<libchess_core::GameHistoryPage, LibChessError> {
        history::list(self, request).await
    }

    async fn export_game(
        &self,
        game_id: libchess_core::GameId,
    ) -> Result<libchess_core::GameExport, LibChessError> {
        history::export(self, game_id).await
    }

    async fn review_game(
        &self,
        game_id: libchess_core::GameId,
    ) -> Result<libchess_core::GameReview, LibChessError> {
        history::review(self, game_id).await
    }

    async fn watch_live_game_catalog(
        &self,
        events: libchess_core::LiveGameCatalogEventSink,
    ) -> Result<(), LibChessError> {
        live::watch_catalog(self, events).await
    }

    async fn play_move(
        &self,
        submission: libchess_core::MoveSubmission,
    ) -> Result<(), LibChessError> {
        live::play_move(self, submission).await
    }

    async fn perform_game_action(
        &self,
        game_id: libchess_core::GameId,
        action: libchess_core::LiveGameAction,
    ) -> Result<(), LibChessError> {
        live::perform_action(self, game_id, action).await
    }
}

#[derive(Deserialize)]
struct LichessAccount {
    id: String,
    username: String,
    title: Option<String>,
}

#[derive(Serialize)]
struct LichessAiChallengeRequest<'a> {
    level: u8,
    #[serde(rename = "clock.limit")]
    #[serde(skip_serializing_if = "Option::is_none")]
    clock_limit: Option<u32>,
    #[serde(rename = "clock.increment")]
    #[serde(skip_serializing_if = "Option::is_none")]
    clock_increment: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    days: Option<u8>,
    color: ColorPreference,
    variant: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    fen: Option<&'a str>,
}

#[derive(Deserialize)]
struct LichessAiGame {
    id: String,
    variant: LichessVariant,
    speed: String,
    rated: bool,
}

#[derive(Deserialize)]
struct LichessVariant {
    key: String,
}

#[derive(Deserialize)]
struct LichessErrorResponse {
    error: Option<String>,
}

#[derive(Serialize)]
struct OAuthTokenRequest<'a> {
    grant_type: &'static str,
    code: &'a str,
    code_verifier: &'a str,
    redirect_uri: &'a str,
    client_id: &'a str,
}

#[derive(Deserialize)]
struct OAuthTokenResponse {
    token_type: String,
    access_token: String,
    expires_in: u64,
}

#[derive(Deserialize)]
struct OAuthErrorResponse {
    error: Option<String>,
    error_description: Option<String>,
    message: Option<String>,
}

fn build_http_client() -> Result<Client, LibChessError> {
    Client::builder()
        .user_agent(concat!("libchess/", env!("CARGO_PKG_VERSION")))
        .connect_timeout(Duration::from_secs(10))
        .build()
        .map_err(|error| {
            LibChessError::new(
                ErrorKind::Network,
                format!("could not create the HTTP client: {error}"),
                true,
            )
        })
}

fn endpoint(base_url: &Url, path: &str) -> Result<Url, LibChessError> {
    base_url.join(path).map_err(|error| {
        LibChessError::new(
            ErrorKind::Provider,
            format!("could not construct the provider endpoint: {error}"),
            false,
        )
    })
}

fn random_urlsafe<const N: usize>() -> Result<String, LibChessError> {
    let mut bytes = Zeroizing::new([0_u8; N]);
    getrandom::fill(&mut *bytes).map_err(|error| {
        LibChessError::new(
            ErrorKind::Provider,
            format!("could not generate secure OAuth randomness: {error}"),
            true,
        )
    })?;
    Ok(URL_SAFE_NO_PAD.encode(bytes.as_slice()))
}

fn resolve_color(
    preference: ColorPreference,
) -> Result<(ColorPreference, PlayerColor), LibChessError> {
    match preference {
        ColorPreference::White => Ok((ColorPreference::White, PlayerColor::White)),
        ColorPreference::Black => Ok((ColorPreference::Black, PlayerColor::Black)),
        ColorPreference::Random => {
            let mut byte = [0_u8; 1];
            getrandom::fill(&mut byte).map_err(|error| {
                LibChessError::new(
                    ErrorKind::Provider,
                    format!("could not choose a random game color: {error}"),
                    true,
                )
            })?;
            if byte[0] & 1 == 0 {
                Ok((ColorPreference::White, PlayerColor::White))
            } else {
                Ok((ColorPreference::Black, PlayerColor::Black))
            }
        }
    }
}

fn validate_redirect_uri(value: &str) -> Result<Url, LibChessError> {
    let redirect_uri = Url::parse(value)
        .map_err(|error| LibChessError::invalid_input(format!("invalid redirect URI: {error}")))?;
    if redirect_uri.query().is_some() || redirect_uri.fragment().is_some() {
        return Err(LibChessError::invalid_input(
            "the OAuth redirect URI cannot contain a query or fragment",
        ));
    }
    if redirect_uri.host_str().is_none() {
        return Err(LibChessError::invalid_input(
            "the OAuth redirect URI must include a host",
        ));
    }

    match redirect_uri.scheme() {
        "https" => {}
        "http" if redirect_uri.host_str().is_some_and(is_loopback_host) => {}
        "http" => {
            return Err(LibChessError::invalid_input(
                "an HTTP OAuth redirect must use an IP loopback host",
            ));
        }
        "file" | "data" | "javascript" => {
            return Err(LibChessError::invalid_input(
                "the OAuth redirect URI uses a forbidden scheme",
            ));
        }
        _ => {}
    }

    Ok(redirect_uri)
}

fn is_loopback_host(host: &str) -> bool {
    host == "127.0.0.1" || host == "[::1]" || host == "::1"
}

fn same_redirect_target(expected: &Url, callback: &Url) -> bool {
    callback.fragment().is_none()
        && expected.scheme() == callback.scheme()
        && expected.username() == callback.username()
        && expected.password() == callback.password()
        && expected.host_str() == callback.host_str()
        && expected.port_or_known_default() == callback.port_or_known_default()
        && expected.path() == callback.path()
}

fn unique_query_value(url: &Url, name: &str) -> Result<Option<String>, LibChessError> {
    let mut values = url
        .query_pairs()
        .filter(|(key, _)| key == name)
        .map(|(_, value)| value.into_owned());
    let value = values.next();
    if values.next().is_some() {
        return Err(authentication_error(format!(
            "the OAuth callback included duplicate '{name}' parameters"
        )));
    }
    Ok(value)
}

fn validate_authorization_code(code: &str) -> Result<(), LibChessError> {
    let valid = !code.is_empty()
        && code.len() <= 4096
        && code
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_');
    if valid {
        Ok(())
    } else {
        Err(authentication_error(
            "the OAuth callback contained an invalid authorization code",
        ))
    }
}

fn validate_game_id(id: &str) -> Result<(), LibChessError> {
    if id.len() == 8 && id.bytes().all(|byte| byte.is_ascii_alphanumeric()) {
        Ok(())
    } else {
        Err(LibChessError::new(
            ErrorKind::Provider,
            "Lichess returned an invalid game identifier",
            false,
        ))
    }
}

fn authentication_error(message: impl Into<String>) -> LibChessError {
    LibChessError::new(ErrorKind::Authentication, message, false)
}

fn truncate(value: &str, max_chars: usize) -> String {
    value.chars().take(max_chars).collect()
}

fn map_transport_error(error: reqwest::Error) -> LibChessError {
    LibChessError::new(
        ErrorKind::Network,
        format!("could not reach Lichess: {error}"),
        error.is_connect() || error.is_timeout(),
    )
}

fn map_status(status: StatusCode) -> LibChessError {
    match status {
        StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => LibChessError::new(
            ErrorKind::Authentication,
            "Lichess rejected the access token or its scopes",
            false,
        ),
        StatusCode::TOO_MANY_REQUESTS => LibChessError::new(
            ErrorKind::RateLimited,
            "Lichess rate limited the request; wait before trying again",
            true,
        ),
        _ => LibChessError::new(
            ErrorKind::Provider,
            format!("Lichess returned HTTP {status}"),
            status.is_server_error(),
        ),
    }
}

fn provider_variant_key(id: &GameVariantId) -> Option<&'static str> {
    LICHESS_VARIANTS
        .iter()
        .find_map(|(canonical, provider, _, _, _)| (*canonical == id.as_str()).then_some(*provider))
}

fn canonical_variant_id(provider_key: &str) -> Option<&'static str> {
    LICHESS_VARIANTS
        .iter()
        .find_map(|(canonical, provider, _, _, _)| {
            (*provider == provider_key).then_some(*canonical)
        })
}

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::sync::mpsc;
    use std::thread;

    use super::*;

    fn mock_response(status: &str, body: &str) -> String {
        format!(
            "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        )
    }

    fn serve_once(response: String) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock server");
        let address = listener.local_addr().expect("mock address");
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept request");
            let request = read_request(&mut stream);
            assert!(request.starts_with("GET /api/account HTTP/1.1"));
            assert!(request.contains("authorization: Bearer lio_test_token"));
            stream
                .write_all(response.as_bytes())
                .expect("write response");
        });
        format!("http://{address}/")
    }

    fn serve_token_once(response: String) -> (String, mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock server");
        let address = listener.local_addr().expect("mock address");
        let (sender, receiver) = mpsc::channel();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept request");
            let request = read_request(&mut stream);
            sender.send(request).expect("send captured request");
            stream
                .write_all(response.as_bytes())
                .expect("write response");
        });
        (format!("http://{address}/"), receiver)
    }

    fn read_request(stream: &mut TcpStream) -> String {
        let mut request = Vec::new();
        let mut buffer = [0_u8; 1024];
        loop {
            let read = stream.read(&mut buffer).expect("read request");
            if read == 0 {
                break;
            }
            request.extend_from_slice(&buffer[..read]);

            let Some(header_end) = request.windows(4).position(|window| window == b"\r\n\r\n")
            else {
                continue;
            };
            let headers = String::from_utf8_lossy(&request[..header_end]);
            let content_length = headers
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().ok())
                        .flatten()
                })
                .unwrap_or(0);
            if request.len() >= header_end + 4 + content_length {
                break;
            }
        }
        String::from_utf8(request).expect("UTF-8 HTTP request")
    }

    fn oauth_configuration() -> OAuthClientConfiguration {
        OAuthClientConfiguration::new("org.libchess.macos", "org.libchess.macos://oauth/lichess")
            .expect("OAuth configuration")
    }

    #[tokio::test]
    async fn maps_a_lichess_account_into_the_domain() {
        let body = r#"{"id":"test-user","username":"TestUser","title":"GM"}"#;
        let base_url = serve_once(mock_response("200 OK", body));
        let factory = LichessFactory::new(&base_url).expect("factory");
        let backend = factory
            .create(AccessToken::new("lio_test_token").expect("token"))
            .expect("backend");

        let account = backend.account().await.expect("account");

        assert_eq!(account.provider.as_str(), "lichess");
        assert_eq!(account.username, "TestUser");
        assert_eq!(account.title.as_deref(), Some("GM"));
    }

    #[tokio::test]
    async fn maps_authentication_failures_without_exposing_the_token() {
        let base_url = serve_once(mock_response("401 Unauthorized", "{}"));
        let factory = LichessFactory::new(&base_url).expect("factory");
        let backend = factory
            .create(AccessToken::new("lio_test_token").expect("token"))
            .expect("backend");

        let error = backend.account().await.expect_err("authentication failure");

        assert_eq!(error.kind, ErrorKind::Authentication);
        assert!(!error.to_string().contains("lio_test_token"));
    }

    #[tokio::test]
    async fn creates_a_standard_bot_game_and_normalizes_the_result() {
        let body = r#"{
            "id":"v8BRXYtM",
            "variant":{"key":"standard","name":"Standard","short":"Std"},
            "speed":"rapid",
            "rated":false,
            "source":"ai",
            "status":{"id":20,"name":"started"},
            "player":"black"
        }"#;
        let (base_url, captured_request) = serve_token_once(mock_response("201 Created", body));
        let factory = LichessFactory::new(&base_url).expect("factory");
        let backend = factory
            .create(AccessToken::new("lio_test_token").expect("token"))
            .expect("backend");
        let request = BotGameRequest::new(
            "level-6",
            "standard",
            BotGameTimeControl::clock(600, 5),
            ColorPreference::Random,
            None,
        )
        .expect("bot game request");

        let game = backend
            .create_bot_game(request)
            .await
            .expect("created bot game");

        assert_eq!(game.provider.as_str(), "lichess");
        assert_eq!(game.id, "v8BRXYtM");
        assert_eq!(game.url, format!("{base_url}v8BRXYtM"));
        assert_eq!(game.opponent.id.as_str(), "level-6");
        assert_eq!(game.opponent.display_name, "Stockfish level 6");
        assert_eq!(game.variant.id.as_str(), "standard");
        assert_eq!(game.time_control, BotGameTimeControl::clock(600, 5));
        assert_eq!(game.initial_fen, None);

        let request = captured_request.recv().expect("captured bot game request");
        assert!(request.starts_with("POST /api/challenge/ai HTTP/1.1"));
        assert!(request.contains("authorization: Bearer lio_test_token"));
        let body = request.split_once("\r\n\r\n").expect("request body").1;
        let form = Url::parse(&format!("http://localhost/?{body}")).expect("form body");
        assert_eq!(
            unique_query_value(&form, "level").expect("level"),
            Some("6".to_owned())
        );
        assert_eq!(
            unique_query_value(&form, "clock.limit").expect("clock limit"),
            Some("600".to_owned())
        );
        assert_eq!(
            unique_query_value(&form, "clock.increment").expect("clock increment"),
            Some("5".to_owned())
        );
        let resolved_color = unique_query_value(&form, "color")
            .expect("color")
            .expect("resolved color");
        assert!(matches!(resolved_color.as_str(), "white" | "black"));
        assert_eq!(
            game.player_color,
            if resolved_color == "white" {
                PlayerColor::White
            } else {
                PlayerColor::Black
            }
        );
        assert_eq!(
            unique_query_value(&form, "variant").expect("variant"),
            Some("standard".to_owned())
        );
        assert!(unique_query_value(&form, "days").unwrap().is_none());
        assert!(unique_query_value(&form, "fen").unwrap().is_none());
    }

    #[tokio::test]
    async fn creates_a_correspondence_variant_without_clock_fields() {
        let body = r#"{
            "id":"v8BRXYtM",
            "variant":{"key":"atomic","name":"Atomic","short":"Atomic"},
            "speed":"correspondence",
            "rated":false,
            "player":"black"
        }"#;
        let (base_url, captured_request) = serve_token_once(mock_response("201 Created", body));
        let factory = LichessFactory::new(&base_url).expect("factory");
        let backend = factory
            .create(AccessToken::new("lio_test_token").expect("token"))
            .expect("backend");
        let request = BotGameRequest::new(
            "level-8",
            "atomic",
            BotGameTimeControl::correspondence(7),
            ColorPreference::White,
            None,
        )
        .expect("bot game request");

        let game = backend
            .create_bot_game(request)
            .await
            .expect("created correspondence game");

        assert_eq!(game.variant.id.as_str(), "atomic");
        assert_eq!(game.player_color, PlayerColor::White);
        assert_eq!(
            game.time_control,
            BotGameTimeControl::Correspondence { days_per_move: 7 }
        );

        let request = captured_request.recv().expect("captured bot game request");
        let body = request.split_once("\r\n\r\n").expect("request body").1;
        let form = Url::parse(&format!("http://localhost/?{body}")).expect("form body");
        assert_eq!(
            unique_query_value(&form, "days").expect("days"),
            Some("7".to_owned())
        );
        assert_eq!(
            unique_query_value(&form, "variant").expect("variant"),
            Some("atomic".to_owned())
        );
        assert_eq!(
            unique_query_value(&form, "color").expect("color"),
            Some("white".to_owned())
        );
        assert!(unique_query_value(&form, "clock.limit").unwrap().is_none());
        assert!(
            unique_query_value(&form, "clock.increment")
                .unwrap()
                .is_none()
        );
    }

    #[tokio::test]
    async fn creates_an_unlimited_game_from_a_custom_position() {
        let body = r#"{
            "id":"v8BRXYtM",
            "variant":{"key":"fromPosition","name":"From Position","short":"From Pos."},
            "speed":"correspondence",
            "rated":false,
            "player":"white"
        }"#;
        let (base_url, captured_request) = serve_token_once(mock_response("201 Created", body));
        let factory = LichessFactory::new(&base_url).expect("factory");
        let backend = factory
            .create(AccessToken::new("lio_test_token").expect("token"))
            .expect("backend");
        let fen = "8/8/8/8/8/8/4K3/6k1 w - - 0 1";
        let request = BotGameRequest::new(
            "level-2",
            "from-position",
            BotGameTimeControl::Unlimited,
            ColorPreference::Black,
            Some(fen.to_owned()),
        )
        .expect("bot game request");

        let game = backend
            .create_bot_game(request)
            .await
            .expect("created unlimited custom-position game");

        assert_eq!(game.variant.id.as_str(), "from-position");
        assert_eq!(game.player_color, PlayerColor::Black);
        assert_eq!(game.time_control, BotGameTimeControl::Unlimited);
        assert_eq!(game.initial_fen.as_deref(), Some(fen));

        let request = captured_request.recv().expect("captured bot game request");
        let body = request.split_once("\r\n\r\n").expect("request body").1;
        let form = Url::parse(&format!("http://localhost/?{body}")).expect("form body");
        assert_eq!(
            unique_query_value(&form, "variant").expect("variant"),
            Some("fromPosition".to_owned())
        );
        assert_eq!(
            unique_query_value(&form, "fen").expect("fen"),
            Some(fen.to_owned())
        );
        assert_eq!(
            unique_query_value(&form, "color").expect("color"),
            Some("black".to_owned())
        );
        assert!(unique_query_value(&form, "clock.limit").unwrap().is_none());
        assert!(
            unique_query_value(&form, "clock.increment")
                .unwrap()
                .is_none()
        );
        assert!(unique_query_value(&form, "days").unwrap().is_none());
    }

    #[tokio::test]
    async fn accepts_lichess_normalizing_an_initial_custom_position_to_standard() {
        let body = r#"{
            "id":"v8BRXYtM",
            "variant":{"key":"standard","name":"Standard","short":"Std"},
            "speed":"correspondence",
            "rated":false,
            "player":"white"
        }"#;
        let (base_url, _captured_request) = serve_token_once(mock_response("201 Created", body));
        let factory = LichessFactory::new(&base_url).expect("factory");
        let backend = factory
            .create(AccessToken::new("lio_test_token").expect("token"))
            .expect("backend");
        let initial_fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
        let request = BotGameRequest::new(
            "level-2",
            "from-position",
            BotGameTimeControl::Unlimited,
            ColorPreference::White,
            Some(initial_fen.to_owned()),
        )
        .expect("bot game request");

        let game = backend
            .create_bot_game(request)
            .await
            .expect("normalized standard game");

        assert_eq!(game.variant.id.as_str(), "standard");
        assert_eq!(game.initial_fen.as_deref(), Some(initial_fen));
    }

    #[tokio::test]
    async fn rejects_unadvertised_or_too_fast_clocks_without_network_access() {
        let factory = LichessFactory::new("http://127.0.0.1:1/").expect("factory");
        let backend = factory
            .create(AccessToken::new("lio_test_token").expect("token"))
            .expect("backend");
        let request = BotGameRequest::new(
            "level-4",
            "standard",
            BotGameTimeControl::clock(60, 0),
            ColorPreference::White,
            None,
        )
        .expect("otherwise valid request");

        let error = backend
            .create_bot_game(request)
            .await
            .expect_err("bullet game should be rejected");

        assert_eq!(error.kind, ErrorKind::InvalidInput);
        assert!(error.message.contains("blitz speed or slower"));

        let unadvertised = BotGameRequest::new(
            "level-4",
            "standard",
            BotGameTimeControl::clock(75, 5),
            ColorPreference::White,
            None,
        )
        .expect("provider-neutral request");
        let error = backend
            .create_bot_game(unadvertised)
            .await
            .expect_err("Lichess does not accept arbitrary initial seconds");

        assert_eq!(error.kind, ErrorKind::InvalidInput);
        assert!(error.message.contains("advertised values"));

        let delayed = BotGameRequest::new(
            "level-4",
            "standard",
            BotGameTimeControl::clock(600, 0),
            ColorPreference::White,
            None,
        )
        .and_then(|request| request.with_reply_delay_millis(500))
        .expect("provider-neutral delayed request");
        let error = backend
            .create_bot_game(delayed)
            .await
            .expect_err("Lichess does not advertise a reply-delay option");

        assert_eq!(error.kind, ErrorKind::InvalidInput);
        assert!(error.message.contains("reply delay"));
    }

    #[tokio::test]
    async fn rejects_a_bot_that_the_provider_did_not_advertise() {
        let factory = LichessFactory::new("http://127.0.0.1:1/").expect("factory");
        let backend = factory
            .create(AccessToken::new("lio_test_token").expect("token"))
            .expect("backend");
        let request = BotGameRequest::new(
            "mittens",
            "standard",
            BotGameTimeControl::clock(300, 0),
            ColorPreference::Random,
            None,
        )
        .expect("provider-neutral bot request");

        let error = backend
            .create_bot_game(request)
            .await
            .expect_err("unknown Lichess bot should be rejected");

        assert_eq!(error.kind, ErrorKind::InvalidInput);
        assert!(error.message.contains("does not advertise bot opponent"));
    }

    #[tokio::test]
    async fn rejects_unadvertised_correspondence_and_position_combinations() {
        let factory = LichessFactory::new("http://127.0.0.1:1/").expect("factory");
        let backend = factory
            .create(AccessToken::new("lio_test_token").expect("token"))
            .expect("backend");
        let invalid_days = BotGameRequest::new(
            "level-4",
            "standard",
            BotGameTimeControl::correspondence(4),
            ColorPreference::Random,
            None,
        )
        .expect("provider-neutral request");
        let missing_fen = BotGameRequest::new(
            "level-4",
            "from-position",
            BotGameTimeControl::Unlimited,
            ColorPreference::Random,
            None,
        )
        .expect("provider-neutral request");
        let unsupported_fen = BotGameRequest::new(
            "level-4",
            "atomic",
            BotGameTimeControl::Unlimited,
            ColorPreference::Random,
            Some("8/8/8/8/8/8/4K3/6k1 w - - 0 1".to_owned()),
        )
        .expect("provider-neutral request");
        let preloaded_history = BotGameRequest::new(
            "level-4",
            "standard",
            BotGameTimeControl::Unlimited,
            ColorPreference::Random,
            Some("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1".to_owned()),
        )
        .and_then(|request| request.with_initial_moves(vec!["e2e4".to_owned()]))
        .expect("provider-neutral request");

        for request in [
            invalid_days,
            missing_fen,
            unsupported_fen,
            preloaded_history,
        ] {
            let error = backend
                .create_bot_game(request)
                .await
                .expect_err("unsupported option combination");
            assert_eq!(error.kind, ErrorKind::InvalidInput);
        }
    }

    #[test]
    fn advertises_every_lichess_ai_challenge_option() {
        let factory = LichessFactory::default();
        let descriptor = factory.descriptor();
        let options = descriptor
            .bot_game_options
            .as_ref()
            .expect("bot-game options");
        assert!(
            options
                .variants
                .iter()
                .all(|variant| !variant.supports_move_history)
        );

        assert_eq!(descriptor.bot_opponents.len(), 8);
        assert_eq!(options.variants.len(), 10);
        assert_eq!(options.correspondence_days, [1, 2, 3, 5, 7, 10, 14]);
        assert!(options.unlimited);
        assert_eq!(options.colors.len(), 3);
        let clock = options.clock.as_ref().expect("clock options");
        assert_eq!(clock.initial_seconds.len(), 185);
        assert_eq!(&clock.initial_seconds[..6], &[0, 15, 30, 45, 60, 90]);
        assert_eq!(clock.initial_seconds[6], 120);
        assert_eq!(clock.initial_seconds.last(), Some(&10_800));
        assert!(!clock.initial_seconds.contains(&75));
        assert_eq!(clock.increment_seconds, (0..=60).collect::<Vec<_>>());
        assert_eq!(clock.minimum_estimated_duration_seconds, Some(180));
        for (canonical, provider, _, _, _) in LICHESS_VARIANTS {
            let id = GameVariantId::new(canonical).expect("canonical variant ID");
            assert_eq!(provider_variant_key(&id), Some(provider));
            assert_eq!(canonical_variant_id(provider), Some(canonical));
        }
    }

    #[test]
    fn creates_an_s256_authorization_request_without_leaking_the_verifier() {
        let factory = LichessFactory::default();
        let session = factory
            .begin_oauth(oauth_configuration())
            .expect("OAuth session");
        let authorization = session.authorization();
        let url = Url::parse(&authorization.authorization_url).expect("authorization URL");

        assert_eq!(authorization.scopes, ["board:play"]);
        assert_eq!(
            unique_query_value(&url, "response_type").expect("response type"),
            Some("code".to_owned())
        );
        assert_eq!(
            unique_query_value(&url, "code_challenge_method").expect("challenge method"),
            Some("S256".to_owned())
        );
        assert_eq!(
            unique_query_value(&url, "scope").expect("scope"),
            Some("board:play".to_owned())
        );
        assert!(unique_query_value(&url, "code_verifier").unwrap().is_none());
        assert_eq!(
            unique_query_value(&url, "state")
                .expect("state")
                .expect("state value")
                .len(),
            43
        );
    }

    #[tokio::test]
    async fn validates_the_callback_and_exchanges_the_code() {
        let token_body =
            r#"{"token_type":"Bearer","access_token":"lio_oauth_token","expires_in":31536000}"#;
        let (base_url, captured_request) = serve_token_once(mock_response("200 OK", token_body));
        let factory = LichessFactory::new(&base_url).expect("factory");
        let session = factory
            .begin_oauth(oauth_configuration())
            .expect("OAuth session");
        let authorization_url =
            Url::parse(&session.authorization().authorization_url).expect("authorization URL");
        let state = unique_query_value(&authorization_url, "state")
            .expect("state")
            .expect("state value");
        let expected_challenge = unique_query_value(&authorization_url, "code_challenge")
            .expect("challenge")
            .expect("challenge value");
        let mut callback = Url::parse("org.libchess.macos://oauth/lichess").expect("callback");
        callback
            .query_pairs_mut()
            .append_pair("code", "oauth_code_123")
            .append_pair("state", &state);

        let token = session
            .exchange(callback.as_str())
            .await
            .expect("OAuth token");

        assert_eq!(token.access_token.expose(), "lio_oauth_token");
        assert_eq!(token.expires_in_seconds, 31_536_000);

        let request = captured_request.recv().expect("captured token request");
        assert!(request.starts_with("POST /api/token HTTP/1.1"));
        let body = request.split_once("\r\n\r\n").expect("request body").1;
        let form = Url::parse(&format!("http://localhost/?{body}")).expect("form body");
        let verifier = unique_query_value(&form, "code_verifier")
            .expect("verifier")
            .expect("verifier value");
        let actual_challenge = URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()));
        assert_eq!(actual_challenge, expected_challenge);
        assert_eq!(
            unique_query_value(&form, "grant_type").expect("grant type"),
            Some("authorization_code".to_owned())
        );
        assert_eq!(
            unique_query_value(&form, "code").expect("code"),
            Some("oauth_code_123".to_owned())
        );
    }

    #[tokio::test]
    async fn rejects_a_callback_with_the_wrong_state_before_network_access() {
        let factory = LichessFactory::new("http://127.0.0.1:1/").expect("factory");
        let session = factory
            .begin_oauth(oauth_configuration())
            .expect("OAuth session");
        let callback = "org.libchess.macos://oauth/lichess?code=oauth_code_123&state=wrong_state";

        let Err(error) = session.exchange(callback).await else {
            panic!("callback with mismatched state was accepted");
        };

        assert_eq!(error.kind, ErrorKind::Authentication);
        assert!(error.message.contains("state did not match"));
    }

    #[tokio::test]
    async fn maps_a_denied_authorization_without_exchanging_a_code() {
        let factory = LichessFactory::new("http://127.0.0.1:1/").expect("factory");
        let session = factory
            .begin_oauth(oauth_configuration())
            .expect("OAuth session");
        let authorization_url =
            Url::parse(&session.authorization().authorization_url).expect("authorization URL");
        let state = unique_query_value(&authorization_url, "state")
            .expect("state")
            .expect("state value");
        let mut callback = Url::parse("org.libchess.macos://oauth/lichess").expect("callback");
        callback
            .query_pairs_mut()
            .append_pair("error", "access_denied")
            .append_pair("error_description", "The user cancelled")
            .append_pair("state", &state);

        let Err(error) = session.exchange(callback.as_str()).await else {
            panic!("denied authorization returned a token");
        };

        assert_eq!(error.kind, ErrorKind::Authentication);
        assert!(error.message.contains("The user cancelled"));
    }
}
