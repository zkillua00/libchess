#![forbid(unsafe_code)]

use std::{collections::BTreeSet, sync::Arc, time::Duration};

use async_trait::async_trait;
use libchess_core::{
    AccessToken, Account, ErrorKind, LibChessError, PlatformBackend, PlatformBackendFactory,
    PlatformCapability, ProviderDescriptor, ProviderId,
};
use reqwest::{Client, StatusCode, Url, header};
use serde::Deserialize;

const DEFAULT_BASE_URL: &str = "https://lichess.org/";

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
        let capabilities = BTreeSet::from([PlatformCapability::Account]);

        Ok(Self {
            descriptor: ProviderDescriptor {
                id: ProviderId::new("lichess")?,
                display_name: "Lichess".to_owned(),
                capabilities,
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
        let http = Client::builder()
            .user_agent(concat!("libchess/", env!("CARGO_PKG_VERSION")))
            .connect_timeout(Duration::from_secs(10))
            .build()
            .map_err(|error| {
                LibChessError::new(
                    ErrorKind::Network,
                    format!("could not create the HTTP client: {error}"),
                    true,
                )
            })?;

        Ok(Self {
            descriptor,
            base_url,
            token,
            http,
        })
    }

    fn endpoint(&self, path: &str) -> Result<Url, LibChessError> {
        self.base_url.join(path).map_err(|error| {
            LibChessError::new(
                ErrorKind::Provider,
                format!("could not construct the provider endpoint: {error}"),
                false,
            )
        })
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
}

#[derive(Deserialize)]
struct LichessAccount {
    id: String,
    username: String,
    title: Option<String>,
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

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};
    use std::net::TcpListener;
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
            let mut request = [0_u8; 4096];
            let read = stream.read(&mut request).expect("read request");
            let request = String::from_utf8_lossy(&request[..read]);
            assert!(request.starts_with("GET /api/account HTTP/1.1"));
            assert!(request.contains("authorization: Bearer lio_test_token"));
            stream
                .write_all(response.as_bytes())
                .expect("write response");
        });
        format!("http://{address}/")
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
}
