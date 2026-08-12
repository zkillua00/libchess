#![forbid(unsafe_code)]

use std::{collections::BTreeMap, sync::Arc};

pub use libchess_core::{
    AccessToken, Account, ChessContext, ErrorKind, LibChessError, OAuthAuthorization,
    OAuthClientConfiguration, OAuthToken, PlatformBackend, PlatformBackendFactory,
    PlatformCapability, PlatformOAuthSession, ProviderDescriptor, ProviderId,
    ensure_engine_allowed,
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
            !providers[0]
                .capabilities
                .contains(&PlatformCapability::LiveGames)
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
