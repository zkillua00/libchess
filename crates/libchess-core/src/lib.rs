#![forbid(unsafe_code)]

use std::{collections::BTreeSet, fmt, sync::Arc};

use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use thiserror::Error;

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
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
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
}

impl fmt::Debug for AccessToken {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("AccessToken([REDACTED])")
    }
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

pub trait PlatformBackendFactory: Send + Sync {
    fn descriptor(&self) -> &ProviderDescriptor;

    fn create(&self, token: AccessToken) -> Result<Arc<dyn PlatformBackend>, LibChessError>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn access_tokens_are_redacted() {
        let token = AccessToken::new("lio_secret123").expect("valid token");
        assert_eq!(format!("{token:?}"), "AccessToken([REDACTED])");
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
}
