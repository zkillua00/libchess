#![forbid(unsafe_code)]

use std::{collections::BTreeMap, sync::Arc};

pub use libchess_core::{
    AccessToken, Account, BoardPiece, BoardState, BotGame, BotGameOptions, BotGameRequest,
    BotGameTimeControl, BotOpponent, BotOpponentId, ChessContext, ClockTimeControl,
    ClockTimeControlOptions, ColorPreference, ErrorKind, GameExport, GameHistoryEntry,
    GameHistoryPage, GameHistoryRequest, GameId, GameStatus, GameVariant, GameVariantId, LegalMove,
    LibChessError, LiveChatMessage, LiveGame, LiveGameAction, LiveGameCatalogEvent,
    LiveGameCatalogEventSink, LiveGameClock, LiveGameEvent, LiveGameEventSink, LiveGamePlayer,
    LiveGameRequest, LiveGameState, LiveGameSummary, MoveSubmission, OAuthAuthorization,
    OAuthClientConfiguration, OAuthToken, PieceRole, PlatformBackend, PlatformBackendFactory,
    PlatformCapability, PlatformOAuthSession, PlayerColor, PocketPiece, ProviderDescriptor,
    ProviderId, ensure_engine_allowed,
};
use libchess_lichess::LichessFactory;

pub struct ClientBuilder {
    factories: BTreeMap<ProviderId, Arc<dyn PlatformBackendFactory>>,
}

impl ClientBuilder {
    pub fn empty() -> Self {
        Self {
            factories: BTreeMap::new(),
        }
    }

    pub fn with_builtin_providers() -> Self {
        Self::empty().register(LichessFactory::default())
    }

    pub fn register(mut self, factory: impl PlatformBackendFactory + 'static) -> Self {
        let id = factory.descriptor().id.clone();
        self.factories.insert(id, Arc::new(factory));
        self
    }

    pub fn build(self) -> Client {
        Client {
            factories: self.factories,
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
}
