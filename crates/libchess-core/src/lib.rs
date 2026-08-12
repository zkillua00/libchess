#![forbid(unsafe_code)]

use std::{collections::BTreeSet, fmt, sync::Arc};

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use zeroize::Zeroize;

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
    Challenges,
    LiveGames,
    Matchmaking,
    #[serde(rename = "oauth_pkce")]
    OAuthPkce,
    PgnExport,
    RealtimeEvents,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ProviderDescriptor {
    pub id: ProviderId,
    pub display_name: String,
    pub capabilities: BTreeSet<PlatformCapability>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct Account {
    pub provider: ProviderId,
    pub id: String,
    pub username: String,
    pub title: Option<String>,
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
