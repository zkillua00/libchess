#![forbid(unsafe_code)]

use std::{
    collections::BTreeSet,
    sync::Arc,
    time::{Duration, Instant},
};

use async_trait::async_trait;
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use libchess_core::{
    AccessToken, Account, ErrorKind, LibChessError, OAuthAuthorization, OAuthClientConfiguration,
    OAuthToken, PlatformBackend, PlatformBackendFactory, PlatformCapability, PlatformOAuthSession,
    ProviderDescriptor, ProviderId,
};
use reqwest::{Client, StatusCode, Url, header};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use subtle::ConstantTimeEq;
use zeroize::Zeroizing;

const DEFAULT_BASE_URL: &str = "https://lichess.org/";
const OAUTH_SESSION_TTL: Duration = Duration::from_secs(10 * 60);
const OAUTH_SCOPES: [&str; 1] = ["board:play"];

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
        let capabilities =
            BTreeSet::from([PlatformCapability::Account, PlatformCapability::OAuthPkce]);

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
}

#[derive(Deserialize)]
struct LichessAccount {
    id: String,
    username: String,
    title: Option<String>,
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
