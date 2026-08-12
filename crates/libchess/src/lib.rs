#![forbid(unsafe_code)]

use std::{collections::BTreeMap, sync::Arc};

pub use libchess_core::{
    AccessToken, Account, ChessContext, ErrorKind, LibChessError, PlatformBackend,
    PlatformBackendFactory, PlatformCapability, ProviderDescriptor, ProviderId,
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
        let id = ProviderId::new(provider)?;
        let factory = self.factories.get(&id).ok_or_else(|| {
            LibChessError::unsupported(format!("provider '{provider}' is not installed"))
        })?;
        let backend = factory.create(AccessToken::new(access_token)?)?;
        let account = backend.account().await?;

        self.backend = Some(backend);
        self.account = Some(account.clone());
        Ok(account)
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
            !providers[0]
                .capabilities
                .contains(&PlatformCapability::LiveGames)
        );
    }
}
