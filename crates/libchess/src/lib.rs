#![forbid(unsafe_code)]

use std::{collections::BTreeMap, sync::Arc};

use libchess_board::{BuiltinBoardProvider, apply_custom_board_theme, apply_custom_piece_theme};
pub use libchess_core::{
    AccessToken, Account, BOARD_CUSTOMIZATION_STATE_VERSION, BoardAnimationCurve,
    BoardAnimationRule, BoardAsset, BoardAssetKind, BoardColorOverrides, BoardCustomizationState,
    BoardMetrics, BoardMotion, BoardPalette, BoardPiece, BoardPieceAsset, BoardPresentation,
    BoardProvider, BoardProviderDescriptor, BoardProviderId, BoardState, BoardStyle,
    BoardThemeDescriptor, BoardThemeId, BoardZoomPreset, BoardZoomPresetId, BoardZoomRules,
    BotGame, BotGameOptions, BotGameRequest, BotGameTimeControl, BotOpponent, BotOpponentId,
    ChessContext, ClockTimeControl, ClockTimeControlOptions, ColorPreference, CustomBoardTheme,
    CustomPieceAsset, CustomPieceAssets, CustomPieceTheme, ErrorKind, GameExport, GameHistoryEntry,
    GameHistoryPage, GameHistoryRequest, GameId, GameMoveEvaluation, GameMoveJudgment,
    GameMoveJudgmentKind, GameOpening, GameReview, GameReviewMove, GameStatus, GameVariant,
    GameVariantId, LegalMove, LibChessError, LiveChatMessage, LiveGame, LiveGameAction,
    LiveGameCatalogEvent, LiveGameCatalogEventSink, LiveGameClock, LiveGameEvent,
    LiveGameEventSink, LiveGamePlayer, LiveGameRequest, LiveGameState, LiveGameSummary,
    MoveSubmission, OAuthAuthorization, OAuthClientConfiguration, OAuthToken, PieceAssets,
    PieceColorOverrides, PieceMetrics, PiecePalette, PieceRole, PieceStyle, PieceThemeDescriptor,
    PieceThemeId, PlatformBackend, PlatformBackendFactory, PlatformCapability,
    PlatformOAuthSession, PlayerColor, PocketPiece, ProviderDescriptor, ProviderId, RgbaColor,
    ThemeColorAdjustment, ensure_engine_allowed,
};
use libchess_lichess::LichessFactory;

pub struct ClientBuilder {
    factories: BTreeMap<ProviderId, Arc<dyn PlatformBackendFactory>>,
    board_providers: BTreeMap<BoardProviderId, Arc<dyn BoardProvider>>,
    default_board_provider: Option<BoardProviderId>,
}

impl ClientBuilder {
    pub fn empty() -> Self {
        Self {
            factories: BTreeMap::new(),
            board_providers: BTreeMap::new(),
            default_board_provider: None,
        }
    }

    pub fn with_builtin_providers() -> Self {
        Self::empty()
            .register(LichessFactory::default())
            .register_board_provider(BuiltinBoardProvider::default())
    }

    pub fn register(mut self, factory: impl PlatformBackendFactory + 'static) -> Self {
        let id = factory.descriptor().id.clone();
        self.factories.insert(id, Arc::new(factory));
        self
    }

    pub fn register_board_provider(mut self, provider: impl BoardProvider + 'static) -> Self {
        let id = provider.descriptor().id.clone();
        if self.default_board_provider.is_none() {
            self.default_board_provider = Some(id.clone());
        }
        self.board_providers.insert(id, Arc::new(provider));
        self
    }

    pub fn build(self) -> Client {
        Client {
            factories: self.factories,
            board_providers: self.board_providers,
            default_board_provider: self.default_board_provider,
            custom_board_themes: BTreeMap::new(),
            custom_piece_themes: BTreeMap::new(),
            backend: None,
            account: None,
            oauth_session: None,
        }
    }
}

impl Default for ClientBuilder {
    fn default() -> Self {
        Self::with_builtin_providers()
    }
}

pub struct Client {
    factories: BTreeMap<ProviderId, Arc<dyn PlatformBackendFactory>>,
    board_providers: BTreeMap<BoardProviderId, Arc<dyn BoardProvider>>,
    default_board_provider: Option<BoardProviderId>,
    custom_board_themes: BTreeMap<(BoardProviderId, BoardThemeId), CustomBoardTheme>,
    custom_piece_themes: BTreeMap<(BoardProviderId, PieceThemeId), CustomPieceTheme>,
    backend: Option<Arc<dyn PlatformBackend>>,
    account: Option<Account>,
    oauth_session: Option<Box<dyn PlatformOAuthSession>>,
}

pub struct OAuthConnection {
    pub account: Account,
    pub access_token: AccessToken,
    pub expires_in_seconds: u64,
}

impl Client {
    pub fn new() -> Self {
        ClientBuilder::default().build()
    }

    pub fn providers(&self) -> Vec<ProviderDescriptor> {
        self.factories
            .values()
            .map(|factory| factory.descriptor().clone())
            .collect()
    }

    pub fn board_providers(&self) -> Vec<BoardProviderDescriptor> {
        self.board_providers
            .values()
            .map(|provider| {
                let mut descriptor = provider.descriptor().clone();
                descriptor.board_themes.extend(
                    self.custom_board_themes
                        .values()
                        .filter(|theme| theme.provider == descriptor.id)
                        .map(|theme| BoardThemeDescriptor {
                            id: theme.id.clone(),
                            display_name: theme.display_name.clone(),
                        }),
                );
                descriptor.piece_themes.extend(
                    self.custom_piece_themes
                        .values()
                        .filter(|theme| theme.provider == descriptor.id)
                        .map(|theme| PieceThemeDescriptor {
                            id: theme.id.clone(),
                            display_name: theme.display_name.clone(),
                        }),
                );
                descriptor
            })
            .collect()
    }

    pub fn board_customization_state(&self) -> BoardCustomizationState {
        BoardCustomizationState {
            version: BOARD_CUSTOMIZATION_STATE_VERSION,
            board_themes: self.custom_board_themes.values().cloned().collect(),
            piece_themes: self.custom_piece_themes.values().cloned().collect(),
        }
    }

    pub fn replace_board_customization_state(
        &mut self,
        state: BoardCustomizationState,
    ) -> Result<(), LibChessError> {
        state.validate()?;
        let mut board_themes = BTreeMap::new();
        let mut piece_themes = BTreeMap::new();

        for theme in state.board_themes {
            self.validate_custom_board_theme(&theme)?;
            board_themes.insert((theme.provider.clone(), theme.id.clone()), theme);
        }
        for theme in state.piece_themes {
            self.validate_custom_piece_theme(&theme)?;
            piece_themes.insert((theme.provider.clone(), theme.id.clone()), theme);
        }
        self.validate_custom_theme_capacity(&board_themes, &piece_themes)?;

        self.custom_board_themes = board_themes;
        self.custom_piece_themes = piece_themes;
        Ok(())
    }

    pub fn register_custom_board_theme(
        &mut self,
        theme: CustomBoardTheme,
    ) -> Result<(), LibChessError> {
        self.validate_custom_board_theme(&theme)?;
        let key = (theme.provider.clone(), theme.id.clone());
        if !self.custom_board_themes.contains_key(&key) {
            let provider = self
                .board_providers
                .get(&theme.provider)
                .expect("custom board theme provider was validated");
            let custom_count = self
                .custom_board_themes
                .keys()
                .filter(|(provider_id, _)| provider_id == &theme.provider)
                .count();
            if provider.descriptor().board_themes.len() + custom_count >= 64 {
                return Err(LibChessError::invalid_input(
                    "a board provider cannot advertise more than 64 board themes",
                ));
            }
        }
        self.custom_board_themes.insert(key, theme);
        Ok(())
    }

    pub fn register_custom_piece_theme(
        &mut self,
        theme: CustomPieceTheme,
    ) -> Result<(), LibChessError> {
        self.validate_custom_piece_theme(&theme)?;
        let key = (theme.provider.clone(), theme.id.clone());
        if !self.custom_piece_themes.contains_key(&key) {
            let provider = self
                .board_providers
                .get(&theme.provider)
                .expect("custom piece theme provider was validated");
            let custom_count = self
                .custom_piece_themes
                .keys()
                .filter(|(provider_id, _)| provider_id == &theme.provider)
                .count();
            if provider.descriptor().piece_themes.len() + custom_count >= 64 {
                return Err(LibChessError::invalid_input(
                    "a board provider cannot advertise more than 64 piece themes",
                ));
            }
        }
        self.custom_piece_themes.insert(key, theme);
        Ok(())
    }

    pub fn remove_custom_board_theme(
        &mut self,
        provider: &str,
        theme: &str,
    ) -> Result<bool, LibChessError> {
        let key = (BoardProviderId::new(provider)?, BoardThemeId::new(theme)?);
        Ok(self.custom_board_themes.remove(&key).is_some())
    }

    pub fn remove_custom_piece_theme(
        &mut self,
        provider: &str,
        theme: &str,
    ) -> Result<bool, LibChessError> {
        let key = (BoardProviderId::new(provider)?, PieceThemeId::new(theme)?);
        Ok(self.custom_piece_themes.remove(&key).is_some())
    }

    pub fn default_board_presentation(&self) -> Result<BoardPresentation, LibChessError> {
        let provider_id = self.default_board_provider.as_ref().ok_or_else(|| {
            LibChessError::unsupported("no board presentation provider is installed")
        })?;
        let provider = self.board_providers.get(provider_id).ok_or_else(|| {
            LibChessError::unsupported("the default board presentation provider is unavailable")
        })?;
        let descriptor = provider.descriptor();
        self.board_presentation(
            provider_id.as_str(),
            descriptor.default_board_theme.as_str(),
            descriptor.default_piece_theme.as_str(),
        )
    }

    pub fn board_presentation(
        &self,
        provider: &str,
        board_theme: &str,
        piece_theme: &str,
    ) -> Result<BoardPresentation, LibChessError> {
        let provider_id = BoardProviderId::new(provider)?;
        let board_theme_id = BoardThemeId::new(board_theme)?;
        let piece_theme_id = PieceThemeId::new(piece_theme)?;
        let board_provider = self.board_providers.get(&provider_id).ok_or_else(|| {
            LibChessError::unsupported(format!(
                "board presentation provider '{provider}' is not installed"
            ))
        })?;
        let descriptor = board_provider.descriptor();
        descriptor.validate()?;
        let custom_board = self
            .custom_board_themes
            .get(&(provider_id.clone(), board_theme_id.clone()));
        let custom_piece = self
            .custom_piece_themes
            .get(&(provider_id.clone(), piece_theme_id.clone()));
        let resolved_board_theme = custom_board
            .map(|theme| &theme.base_theme)
            .unwrap_or(&board_theme_id);
        let resolved_piece_theme = custom_piece
            .map(|theme| &theme.base_theme)
            .unwrap_or(&piece_theme_id);

        if !descriptor
            .board_themes
            .iter()
            .any(|item| item.id == *resolved_board_theme)
        {
            return Err(LibChessError::unsupported(format!(
                "board theme '{board_theme}' is not installed for provider '{provider}'"
            )));
        }
        if !descriptor
            .piece_themes
            .iter()
            .any(|item| item.id == *resolved_piece_theme)
        {
            return Err(LibChessError::unsupported(format!(
                "piece theme '{piece_theme}' is not installed for provider '{provider}'"
            )));
        }

        let mut presentation =
            board_provider.presentation(resolved_board_theme, resolved_piece_theme)?;
        if let Some(theme) = custom_board {
            apply_custom_board_theme(&mut presentation.board, theme)?;
            presentation.board_theme = board_theme_id.clone();
        }
        if let Some(theme) = custom_piece {
            apply_custom_piece_theme(&mut presentation.pieces, theme)?;
            presentation.piece_theme = piece_theme_id.clone();
        }
        if presentation.provider != provider_id
            || presentation.board_theme != board_theme_id
            || presentation.piece_theme != piece_theme_id
        {
            return Err(LibChessError::invalid_input(
                "a board provider returned a presentation for different provider or theme identifiers",
            ));
        }
        presentation.validate()?;
        Ok(presentation)
    }

    fn validate_custom_board_theme(&self, theme: &CustomBoardTheme) -> Result<(), LibChessError> {
        theme.validate()?;
        let provider = self.board_providers.get(&theme.provider).ok_or_else(|| {
            LibChessError::unsupported(format!(
                "board presentation provider '{}' is not installed",
                theme.provider
            ))
        })?;
        let descriptor = provider.descriptor();
        if descriptor
            .board_themes
            .iter()
            .any(|item| item.id == theme.id)
        {
            return Err(LibChessError::invalid_input(
                "custom board themes cannot replace a built-in theme identifier",
            ));
        }
        if !descriptor
            .board_themes
            .iter()
            .any(|item| item.id == theme.base_theme)
        {
            return Err(LibChessError::invalid_input(
                "custom board themes must derive from a built-in theme",
            ));
        }
        Ok(())
    }

    fn validate_custom_piece_theme(&self, theme: &CustomPieceTheme) -> Result<(), LibChessError> {
        theme.validate()?;
        let provider = self.board_providers.get(&theme.provider).ok_or_else(|| {
            LibChessError::unsupported(format!(
                "board presentation provider '{}' is not installed",
                theme.provider
            ))
        })?;
        let descriptor = provider.descriptor();
        if descriptor
            .piece_themes
            .iter()
            .any(|item| item.id == theme.id)
        {
            return Err(LibChessError::invalid_input(
                "custom piece themes cannot replace a built-in theme identifier",
            ));
        }
        if !descriptor
            .piece_themes
            .iter()
            .any(|item| item.id == theme.base_theme)
        {
            return Err(LibChessError::invalid_input(
                "custom piece themes must derive from a built-in theme",
            ));
        }
        Ok(())
    }

    fn validate_custom_theme_capacity(
        &self,
        board_themes: &BTreeMap<(BoardProviderId, BoardThemeId), CustomBoardTheme>,
        piece_themes: &BTreeMap<(BoardProviderId, PieceThemeId), CustomPieceTheme>,
    ) -> Result<(), LibChessError> {
        for provider in self.board_providers.values() {
            let descriptor = provider.descriptor();
            let board_count = board_themes
                .keys()
                .filter(|(provider_id, _)| provider_id == &descriptor.id)
                .count();
            let piece_count = piece_themes
                .keys()
                .filter(|(provider_id, _)| provider_id == &descriptor.id)
                .count();
            if descriptor.board_themes.len() + board_count > 64
                || descriptor.piece_themes.len() + piece_count > 64
            {
                return Err(LibChessError::invalid_input(
                    "a board provider cannot advertise more than 64 themes of either kind",
                ));
            }
        }
        Ok(())
    }

    pub async fn connect(
        &mut self,
        provider: &str,
        access_token: String,
    ) -> Result<Account, LibChessError> {
        self.connect_with_access_token(provider, AccessToken::new(access_token)?)
            .await
    }

    async fn connect_with_access_token(
        &mut self,
        provider: &str,
        access_token: AccessToken,
    ) -> Result<Account, LibChessError> {
        let id = ProviderId::new(provider)?;
        let factory = self.factories.get(&id).ok_or_else(|| {
            LibChessError::unsupported(format!("provider '{provider}' is not installed"))
        })?;
        let backend = factory.create(access_token)?;
        let account = backend.account().await?;

        self.backend = Some(backend);
        self.account = Some(account.clone());
        Ok(account)
    }

    pub fn begin_oauth(
        &mut self,
        provider: &str,
        client_id: String,
        redirect_uri: String,
    ) -> Result<OAuthAuthorization, LibChessError> {
        let id = ProviderId::new(provider)?;
        let factory = self.factories.get(&id).ok_or_else(|| {
            LibChessError::unsupported(format!("provider '{provider}' is not installed"))
        })?;
        let configuration = OAuthClientConfiguration::new(client_id, redirect_uri)?;
        let session = factory.begin_oauth(configuration)?;
        let authorization = session.authorization().clone();
        self.oauth_session = Some(session);
        Ok(authorization)
    }

    pub async fn complete_oauth(
        &mut self,
        callback_url: &str,
    ) -> Result<OAuthConnection, LibChessError> {
        let session = self.oauth_session.take().ok_or_else(|| {
            LibChessError::invalid_input("there is no pending OAuth authorization request")
        })?;
        let provider = session.authorization().provider.clone();
        let OAuthToken {
            access_token,
            expires_in_seconds,
        } = session.exchange(callback_url).await?;
        let token_for_storage = access_token.duplicate();
        let account = self
            .connect_with_access_token(provider.as_str(), access_token)
            .await?;

        Ok(OAuthConnection {
            account,
            access_token: token_for_storage,
            expires_in_seconds,
        })
    }

    pub fn cancel_oauth(&mut self) -> bool {
        self.oauth_session.take().is_some()
    }

    pub async fn refresh_account(&mut self) -> Result<Account, LibChessError> {
        let backend = self
            .backend
            .as_ref()
            .ok_or_else(|| LibChessError::invalid_input("no provider is connected"))?;
        let account = backend.account().await?;
        self.account = Some(account.clone());
        Ok(account)
    }

    pub async fn create_bot_game(&self, request: BotGameRequest) -> Result<BotGame, LibChessError> {
        let backend = self
            .backend
            .as_ref()
            .ok_or_else(|| LibChessError::invalid_input("no provider is connected"))?;
        backend.create_bot_game(request).await
    }

    pub async fn game_history(
        &self,
        limit: u16,
        before_millis: Option<u64>,
    ) -> Result<GameHistoryPage, LibChessError> {
        let account = self
            .account
            .as_ref()
            .ok_or_else(|| LibChessError::invalid_input("no provider is connected"))?;
        let request = GameHistoryRequest::new(
            account.id.clone(),
            account.username.clone(),
            limit,
            before_millis,
        )?;
        self.connected_backend()?.game_history(request).await
    }

    pub async fn export_game(&self, game_id: GameId) -> Result<GameExport, LibChessError> {
        self.connected_backend()?.export_game(game_id).await
    }

    pub async fn review_game(&self, game_id: GameId) -> Result<GameReview, LibChessError> {
        self.connected_backend()?.review_game(game_id).await
    }

    pub fn connected_backend(&self) -> Result<Arc<dyn PlatformBackend>, LibChessError> {
        self.backend
            .clone()
            .ok_or_else(|| LibChessError::invalid_input("no provider is connected"))
    }

    pub async fn play_move(&self, submission: MoveSubmission) -> Result<(), LibChessError> {
        self.connected_backend()?.play_move(submission).await
    }

    pub async fn perform_game_action(
        &self,
        game_id: GameId,
        action: LiveGameAction,
    ) -> Result<(), LibChessError> {
        self.connected_backend()?
            .perform_game_action(game_id, action)
            .await
    }

    pub fn disconnect(&mut self) {
        self.oauth_session = None;
        self.account = None;
        self.backend = None;
    }

    pub fn account(&self) -> Option<&Account> {
        self.account.as_ref()
    }
}

impl Default for Client {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builtin_registry_is_provider_agnostic() {
        let client = Client::new();
        let providers = client.providers();

        assert_eq!(providers.len(), 1);
        assert_eq!(providers[0].id.as_str(), "lichess");
        assert_eq!(providers[0].web_url, "https://lichess.org/");
        assert!(
            providers[0]
                .capabilities
                .contains(&PlatformCapability::Account)
        );
        assert!(
            providers[0]
                .capabilities
                .contains(&PlatformCapability::OAuthPkce)
        );
        assert!(
            providers[0]
                .capabilities
                .contains(&PlatformCapability::BotGames)
        );
        assert_eq!(providers[0].bot_opponents.len(), 8);
        assert_eq!(providers[0].bot_opponents[0].id.as_str(), "level-1");
        let bot_options = providers[0]
            .bot_game_options
            .as_ref()
            .expect("bot-game options");
        assert_eq!(bot_options.variants.len(), 10);
        assert_eq!(bot_options.correspondence_days.len(), 7);
        assert!(bot_options.unlimited);
        assert!(
            providers[0]
                .capabilities
                .contains(&PlatformCapability::LiveGames)
        );
        assert!(
            providers[0]
                .capabilities
                .contains(&PlatformCapability::RealtimeEvents)
        );
        assert!(
            providers[0]
                .capabilities
                .contains(&PlatformCapability::GameHistory)
        );
        assert!(
            providers[0]
                .capabilities
                .contains(&PlatformCapability::PgnExport)
        );

        let board_providers = client.board_providers();
        assert_eq!(board_providers.len(), 1);
        assert_eq!(board_providers[0].id.as_str(), "libchess");
        assert_eq!(board_providers[0].board_themes.len(), 6);
        assert_eq!(board_providers[0].piece_themes.len(), 4);
        let presentation = client
            .default_board_presentation()
            .expect("default board presentation");
        assert_eq!(presentation.board_theme.as_str(), "classic");
        assert_eq!(presentation.piece_theme.as_str(), "system-solid");
        assert_eq!(presentation.pieces.assets.pieces.len(), 12);
    }

    #[test]
    fn starts_and_cancels_provider_owned_oauth() {
        let mut client = Client::new();

        let authorization = client
            .begin_oauth(
                "lichess",
                "org.libchess.macos".to_owned(),
                "org.libchess.macos://oauth/lichess".to_owned(),
            )
            .expect("OAuth authorization");

        assert_eq!(authorization.provider.as_str(), "lichess");
        assert_eq!(authorization.scopes, ["board:play"]);
        assert!(
            authorization
                .authorization_url
                .starts_with("https://lichess.org/oauth?")
        );
        assert!(client.cancel_oauth());
        assert!(!client.cancel_oauth());
    }

    #[test]
    fn registers_independent_custom_board_and_piece_themes() {
        let mut client = Client::new();
        client
            .register_custom_board_theme(CustomBoardTheme {
                provider: BoardProviderId::new("libchess").expect("provider id"),
                id: BoardThemeId::new("my-board").expect("board id"),
                display_name: "My Board".to_owned(),
                base_theme: BoardThemeId::new("classic").expect("base id"),
                adjustment: ThemeColorAdjustment {
                    hue_degrees: 30,
                    saturation_percent: 10,
                    brightness_percent: -5,
                },
                colors: BoardColorOverrides {
                    light_square: Some(RgbaColor::new(240, 220, 190, 255)),
                    dark_square: Some(RgbaColor::new(80, 100, 120, 255)),
                    ..BoardColorOverrides::default()
                },
            })
            .expect("register board theme");
        client
            .register_custom_piece_theme(CustomPieceTheme {
                provider: BoardProviderId::new("libchess").expect("provider id"),
                id: PieceThemeId::new("blue-pieces").expect("piece id"),
                display_name: "Blue Pieces".to_owned(),
                base_theme: PieceThemeId::new("system-solid").expect("base id"),
                adjustment: ThemeColorAdjustment::default(),
                colors: PieceColorOverrides {
                    black_piece: Some(RgbaColor::new(20, 45, 120, 255)),
                    ..PieceColorOverrides::default()
                },
                assets: None,
            })
            .expect("register piece theme");

        let catalog = client.board_providers();
        assert!(
            catalog[0]
                .board_themes
                .iter()
                .any(|theme| theme.id.as_str() == "my-board")
        );
        assert!(
            catalog[0]
                .piece_themes
                .iter()
                .any(|theme| theme.id.as_str() == "blue-pieces")
        );

        let presentation = client
            .board_presentation("libchess", "my-board", "blue-pieces")
            .expect("custom presentation");
        assert_eq!(presentation.board.display_name, "My Board");
        assert_eq!(presentation.pieces.display_name, "Blue Pieces");
        assert_ne!(
            presentation.board.palette.light_square,
            RgbaColor::new(212, 196, 166, 255)
        );
        assert_eq!(presentation.board.palette.light_square.alpha, 255);
        assert_eq!(
            presentation.pieces.palette.black_piece,
            RgbaColor::new(20, 45, 120, 255)
        );

        let snapshot = client.board_customization_state();
        let mut restored = Client::new();
        restored
            .replace_board_customization_state(snapshot)
            .expect("restore customization");
        assert!(
            restored
                .board_presentation("libchess", "my-board", "blue-pieces")
                .is_ok()
        );
    }

    #[test]
    fn rejects_custom_themes_that_shadow_builtins() {
        let mut client = Client::new();
        let result = client.register_custom_board_theme(CustomBoardTheme {
            provider: BoardProviderId::new("libchess").expect("provider id"),
            id: BoardThemeId::new("classic").expect("board id"),
            display_name: "Replacement".to_owned(),
            base_theme: BoardThemeId::new("classic").expect("base id"),
            adjustment: ThemeColorAdjustment::default(),
            colors: BoardColorOverrides::default(),
        });

        assert!(result.is_err());
    }
}
