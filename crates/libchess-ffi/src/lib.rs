#![deny(unsafe_op_in_unsafe_fn)]

use std::{
    ffi::c_void,
    panic::{AssertUnwindSafe, catch_unwind},
    ptr, slice,
    sync::Arc,
    thread::{self, JoinHandle},
};

use libchess::{
    AccessToken, Account, BotGame, BotGameRequest, BotGameTimeControl, Client, ColorPreference,
    GameId, LibChessError, LiveChatMessage, LiveGame, LiveGameAction, LiveGameEvent,
    LiveGameRequest, MoveSubmission, OAuthConnection, PlayerColor, ProviderDescriptor,
};
use serde::{Deserialize, Serialize, Serializer};
use tokio::sync::mpsc;
use zeroize::Zeroize;

const API_VERSION: u32 = 1;

const SEND_OK: i32 = 0;
const SEND_NULL_CLIENT: i32 = 1;
const SEND_NULL_BYTES: i32 = 2;
const SEND_INVALID_JSON: i32 = 3;
const SEND_UNSUPPORTED_VERSION: i32 = 4;
const SEND_WORKER_CLOSED: i32 = 5;
const SEND_PANIC: i32 = 6;

pub type LibChessEventCallback =
    extern "C" fn(context: *mut c_void, event_json: *const u8, event_json_length: usize);

#[repr(C)]
pub struct LibChessClient {
    sender: mpsc::UnboundedSender<WorkerMessage>,
    worker: Option<JoinHandle<()>>,
}

#[derive(Clone)]
struct EventSink {
    callback: LibChessEventCallback,
    // Raw pointers are not Send. Treating the opaque address as an integer
    // keeps the cross-thread contract explicit; native code owns its lifetime.
    context_address: usize,
}

impl EventSink {
    fn emit(&self, request_id: Option<&str>, event: Event) {
        let envelope = EventEnvelope {
            version: API_VERSION,
            request_id,
            event,
        };

        let Ok(mut bytes) = serde_json::to_vec(&envelope) else {
            return;
        };

        (self.callback)(
            self.context_address as *mut c_void,
            bytes.as_ptr(),
            bytes.len(),
        );
        bytes.zeroize();
    }
}

enum WorkerMessage {
    Command(CommandEnvelope),
    Shutdown,
}

#[derive(Deserialize)]
struct CommandEnvelope {
    version: u32,
    #[serde(default)]
    request_id: Option<String>,
    #[serde(flatten)]
    command: Command,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Command {
    BeginOauth {
        provider: String,
        client_id: String,
        redirect_uri: String,
    },
    CancelOauth,
    CompleteOauth {
        callback_url: String,
    },
    Connect {
        provider: String,
        access_token: String,
    },
    CreateBotGame {
        opponent_id: String,
        variant_id: String,
        time_control: BotGameTimeControl,
        color: ColorPreference,
        #[serde(default)]
        initial_fen: Option<String>,
    },
    Disconnect,
    ListProviders,
    PerformGameAction {
        game_id: String,
        action: LiveGameAction,
    },
    PlayMove {
        game_id: String,
        move_id: String,
        #[serde(default)]
        offer_draw: bool,
    },
    RefreshAccount,
    StartLiveGame {
        game_id: String,
        player_color: PlayerColor,
    },
    StopLiveGame,
}

#[derive(Serialize)]
struct EventEnvelope<'a> {
    version: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    request_id: Option<&'a str>,
    #[serde(flatten)]
    event: Event,
}

#[derive(Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Event {
    AccountUpdated {
        account: Account,
    },
    ConnectionStateChanged {
        state: ConnectionState,
        #[serde(skip_serializing_if = "Option::is_none")]
        provider: Option<String>,
    },
    BotGameCreated {
        game: BotGame,
    },
    Error {
        error: LibChessError,
    },
    GameActionCompleted {
        game_id: String,
        action: LiveGameAction,
    },
    LiveGameChat {
        chat: LiveChatMessage,
    },
    LiveGameStreamEnded {
        game_id: String,
    },
    LiveGameUpdated {
        live_game: Box<LiveGame>,
    },
    MoveSubmitted {
        game_id: String,
        move_id: String,
    },
    OauthAuthorizationRequired {
        provider: String,
        authorization_url: String,
        scopes: Vec<String>,
    },
    OauthCredentialIssued {
        provider: String,
        access_token: SerializableAccessToken,
        expires_in_seconds: u64,
    },
    Providers {
        providers: Vec<ProviderDescriptor>,
    },
    Ready {
        providers: Vec<ProviderDescriptor>,
    },
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
enum ConnectionState {
    Authorizing,
    Connected,
    Connecting,
    Disconnected,
}

struct SerializableAccessToken(AccessToken);

impl Serialize for SerializableAccessToken {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(self.0.expose())
    }
}

async fn run_worker(mut receiver: mpsc::UnboundedReceiver<WorkerMessage>, sink: EventSink) {
    let mut client = Client::new();
    let mut live_task: Option<tokio::task::JoinHandle<()>> = None;
    sink.emit(
        None,
        Event::Ready {
            providers: client.providers(),
        },
    );

    while let Some(message) = receiver.recv().await {
        match message {
            WorkerMessage::Shutdown => {
                stop_live_task(&mut live_task).await;
                break;
            }
            WorkerMessage::Command(envelope) => {
                let request_id = envelope.request_id.as_deref();
                match envelope.command {
                    Command::BeginOauth {
                        provider,
                        client_id,
                        redirect_uri,
                    } => match client.begin_oauth(&provider, client_id, redirect_uri) {
                        Ok(authorization) => {
                            sink.emit(
                                request_id,
                                Event::ConnectionStateChanged {
                                    state: ConnectionState::Authorizing,
                                    provider: Some(provider),
                                },
                            );
                            sink.emit(
                                request_id,
                                Event::OauthAuthorizationRequired {
                                    provider: authorization.provider.to_string(),
                                    authorization_url: authorization.authorization_url,
                                    scopes: authorization.scopes,
                                },
                            );
                        }
                        Err(error) => {
                            sink.emit(request_id, Event::Error { error });
                            sink.emit(
                                request_id,
                                Event::ConnectionStateChanged {
                                    state: ConnectionState::Disconnected,
                                    provider: None,
                                },
                            );
                        }
                    },
                    Command::CancelOauth => {
                        client.cancel_oauth();
                        sink.emit(
                            request_id,
                            Event::ConnectionStateChanged {
                                state: ConnectionState::Disconnected,
                                provider: None,
                            },
                        );
                    }
                    Command::CompleteOauth { callback_url } => {
                        sink.emit(
                            request_id,
                            Event::ConnectionStateChanged {
                                state: ConnectionState::Connecting,
                                provider: None,
                            },
                        );
                        match client.complete_oauth(&callback_url).await {
                            Ok(OAuthConnection {
                                account,
                                access_token,
                                expires_in_seconds,
                            }) => {
                                let provider = account.provider.to_string();
                                sink.emit(
                                    request_id,
                                    Event::OauthCredentialIssued {
                                        provider: provider.clone(),
                                        access_token: SerializableAccessToken(access_token),
                                        expires_in_seconds,
                                    },
                                );
                                sink.emit(
                                    request_id,
                                    Event::AccountUpdated {
                                        account: account.clone(),
                                    },
                                );
                                sink.emit(
                                    request_id,
                                    Event::ConnectionStateChanged {
                                        state: ConnectionState::Connected,
                                        provider: Some(provider),
                                    },
                                );
                            }
                            Err(error) => {
                                sink.emit(request_id, Event::Error { error });
                                sink.emit(
                                    request_id,
                                    Event::ConnectionStateChanged {
                                        state: ConnectionState::Disconnected,
                                        provider: None,
                                    },
                                );
                            }
                        }
                    }
                    Command::ListProviders => sink.emit(
                        request_id,
                        Event::Providers {
                            providers: client.providers(),
                        },
                    ),
                    Command::Connect {
                        provider,
                        access_token,
                    } => {
                        sink.emit(
                            request_id,
                            Event::ConnectionStateChanged {
                                state: ConnectionState::Connecting,
                                provider: Some(provider.clone()),
                            },
                        );

                        match client.connect(&provider, access_token).await {
                            Ok(account) => {
                                sink.emit(
                                    request_id,
                                    Event::AccountUpdated {
                                        account: account.clone(),
                                    },
                                );
                                sink.emit(
                                    request_id,
                                    Event::ConnectionStateChanged {
                                        state: ConnectionState::Connected,
                                        provider: Some(account.provider.to_string()),
                                    },
                                );
                            }
                            Err(error) => {
                                sink.emit(request_id, Event::Error { error });
                                sink.emit(
                                    request_id,
                                    Event::ConnectionStateChanged {
                                        state: ConnectionState::Disconnected,
                                        provider: None,
                                    },
                                );
                            }
                        }
                    }
                    Command::CreateBotGame {
                        opponent_id,
                        variant_id,
                        time_control,
                        color,
                        initial_fen,
                    } => {
                        let request = BotGameRequest::new(
                            opponent_id,
                            variant_id,
                            time_control,
                            color,
                            initial_fen,
                        );
                        match request {
                            Ok(request) => match client.create_bot_game(request).await {
                                Ok(game) => {
                                    sink.emit(request_id, Event::BotGameCreated { game });
                                }
                                Err(error) => sink.emit(request_id, Event::Error { error }),
                            },
                            Err(error) => sink.emit(request_id, Event::Error { error }),
                        }
                    }
                    Command::StartLiveGame {
                        game_id,
                        player_color,
                    } => {
                        stop_live_task(&mut live_task).await;
                        let request = LiveGameRequest::new(game_id.clone(), player_color);
                        match (request, client.connected_backend()) {
                            (Ok(request), Ok(backend)) => {
                                let event_sink = sink.clone();
                                let stream_sink = sink.clone();
                                let stream_request_id = envelope.request_id.clone();
                                let ended_game_id = game_id;
                                live_task = Some(tokio::spawn(async move {
                                    let events = Arc::new(move |event| match event {
                                        LiveGameEvent::GameUpdated { game } => event_sink
                                            .emit(None, Event::LiveGameUpdated { live_game: game }),
                                        LiveGameEvent::ChatMessage { message } => event_sink
                                            .emit(None, Event::LiveGameChat { chat: message }),
                                    });
                                    match backend.watch_live_game(request, events).await {
                                        Ok(()) => stream_sink.emit(
                                            stream_request_id.as_deref(),
                                            Event::LiveGameStreamEnded {
                                                game_id: ended_game_id,
                                            },
                                        ),
                                        Err(error) => stream_sink.emit(
                                            stream_request_id.as_deref(),
                                            Event::Error { error },
                                        ),
                                    }
                                }));
                            }
                            (Err(error), _) | (_, Err(error)) => {
                                sink.emit(request_id, Event::Error { error });
                            }
                        }
                    }
                    Command::StopLiveGame => {
                        stop_live_task(&mut live_task).await;
                    }
                    Command::PlayMove {
                        game_id,
                        move_id,
                        offer_draw,
                    } => match MoveSubmission::new(&game_id, &move_id, offer_draw) {
                        Ok(submission) => match client.play_move(submission).await {
                            Ok(()) => {
                                sink.emit(request_id, Event::MoveSubmitted { game_id, move_id })
                            }
                            Err(error) => sink.emit(request_id, Event::Error { error }),
                        },
                        Err(error) => sink.emit(request_id, Event::Error { error }),
                    },
                    Command::PerformGameAction { game_id, action } => match GameId::new(&game_id) {
                        Ok(valid_game_id) => {
                            match client.perform_game_action(valid_game_id, action).await {
                                Ok(()) => sink.emit(
                                    request_id,
                                    Event::GameActionCompleted { game_id, action },
                                ),
                                Err(error) => sink.emit(request_id, Event::Error { error }),
                            }
                        }
                        Err(error) => sink.emit(request_id, Event::Error { error }),
                    },
                    Command::RefreshAccount => match client.refresh_account().await {
                        Ok(account) => {
                            sink.emit(request_id, Event::AccountUpdated { account });
                        }
                        Err(error) => sink.emit(request_id, Event::Error { error }),
                    },
                    Command::Disconnect => {
                        stop_live_task(&mut live_task).await;
                        client.disconnect();
                        sink.emit(
                            request_id,
                            Event::ConnectionStateChanged {
                                state: ConnectionState::Disconnected,
                                provider: None,
                            },
                        );
                    }
                }
            }
        }
    }

    stop_live_task(&mut live_task).await;
}

async fn stop_live_task(task: &mut Option<tokio::task::JoinHandle<()>>) {
    if let Some(task) = task.take() {
        task.abort();
        let _ = task.await;
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn libchess_api_version() -> u32 {
    API_VERSION
}

#[unsafe(no_mangle)]
/// Creates a client whose callback receives events on a dedicated worker.
///
/// # Safety
///
/// `context` must remain valid for every callback until
/// [`libchess_client_destroy`] returns. The callback must not unwind across the
/// C ABI boundary.
pub unsafe extern "C" fn libchess_client_create(
    callback: Option<LibChessEventCallback>,
    context: *mut c_void,
) -> *mut LibChessClient {
    let Some(callback) = callback else {
        return ptr::null_mut();
    };

    catch_unwind(AssertUnwindSafe(|| {
        let (sender, receiver) = mpsc::unbounded_channel();
        let sink = EventSink {
            callback,
            context_address: context as usize,
        };
        let worker = thread::Builder::new()
            .name("libchess-worker".to_owned())
            .spawn(move || {
                let runtime = tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build();
                if let Ok(runtime) = runtime {
                    runtime.block_on(run_worker(receiver, sink));
                }
            });

        match worker {
            Ok(worker) => Box::into_raw(Box::new(LibChessClient {
                sender,
                worker: Some(worker),
            })),
            Err(_) => ptr::null_mut(),
        }
    }))
    .unwrap_or(ptr::null_mut())
}

#[unsafe(no_mangle)]
/// Queues one versioned JSON command for the client worker.
///
/// # Safety
///
/// `client` must be a live handle returned by [`libchess_client_create`].
/// `command_json` must point to `command_json_length` readable bytes for this
/// call. Destruction must not happen concurrently.
pub unsafe extern "C" fn libchess_client_send(
    client: *mut LibChessClient,
    command_json: *const u8,
    command_json_length: usize,
) -> i32 {
    catch_unwind(AssertUnwindSafe(|| {
        if client.is_null() {
            return SEND_NULL_CLIENT;
        }
        if command_json.is_null() {
            return SEND_NULL_BYTES;
        }

        // SAFETY: The caller promises that `command_json` points to
        // `command_json_length` readable bytes for the duration of this call.
        let bytes = unsafe { slice::from_raw_parts(command_json, command_json_length) };
        let command: CommandEnvelope = match serde_json::from_slice(bytes) {
            Ok(command) => command,
            Err(_) => return SEND_INVALID_JSON,
        };
        if command.version != API_VERSION {
            return SEND_UNSUPPORTED_VERSION;
        }

        // SAFETY: The non-null handle was returned by `libchess_client_create`.
        // The ABI contract forbids concurrent destruction of this handle.
        let client = unsafe { &*client };
        match client.sender.send(WorkerMessage::Command(command)) {
            Ok(()) => SEND_OK,
            Err(_) => SEND_WORKER_CLOSED,
        }
    }))
    .unwrap_or(SEND_PANIC)
}

#[unsafe(no_mangle)]
/// Stops the worker and destroys a client handle.
///
/// # Safety
///
/// `client` must be null or a live handle returned by
/// [`libchess_client_create`], and it must be destroyed exactly once. This
/// function must not run from the event callback or concurrently with send.
pub unsafe extern "C" fn libchess_client_destroy(client: *mut LibChessClient) {
    if client.is_null() {
        return;
    }

    let _ = catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: The handle came from `libchess_client_create`, and the ABI
        // requires exactly one destroy call with no concurrent send calls.
        let mut client = unsafe { Box::from_raw(client) };
        let _ = client.sender.send(WorkerMessage::Shutdown);
        if let Some(worker) = client.worker.take() {
            let _ = worker.join();
        }
    }));
}

#[cfg(test)]
mod tests {
    use std::{sync::mpsc as std_mpsc, time::Duration};

    use super::*;

    extern "C" fn collect_event(context: *mut c_void, bytes: *const u8, length: usize) {
        // SAFETY: The test owns this sender until after the client is destroyed,
        // and the callback bytes are valid for the duration of the callback.
        let sender = unsafe { &*(context as *const std_mpsc::Sender<String>) };
        let bytes = unsafe { slice::from_raw_parts(bytes, length) };
        sender
            .send(String::from_utf8(bytes.to_vec()).expect("UTF-8 event"))
            .expect("collect event");
    }

    #[test]
    fn exposes_a_versioned_command_event_protocol() {
        let (sender, receiver) = std_mpsc::channel::<String>();
        let sender = Box::new(sender);
        let context = (&*sender as *const std_mpsc::Sender<String>)
            .cast_mut()
            .cast();
        // SAFETY: The boxed sender outlives the client and callback.
        let client = unsafe { libchess_client_create(Some(collect_event), context) };
        assert!(!client.is_null());

        let ready = receiver
            .recv_timeout(Duration::from_secs(2))
            .expect("ready event");
        assert!(ready.contains(r#""type":"ready""#));
        assert!(ready.contains(r#""id":"lichess""#));
        assert!(ready.contains(r#""bot_opponents""#));
        assert!(ready.contains(r#""id":"level-1""#));

        let command = br#"{"version":1,"request_id":"providers-1","type":"list_providers"}"#;
        assert_eq!(
            unsafe { libchess_client_send(client, command.as_ptr(), command.len()) },
            SEND_OK
        );

        let providers = receiver
            .recv_timeout(Duration::from_secs(2))
            .expect("providers event");
        assert!(providers.contains(r#""request_id":"providers-1""#));
        assert!(providers.contains(r#""type":"providers""#));

        // SAFETY: This is the only destroy and no sends run concurrently.
        unsafe { libchess_client_destroy(client) };
        drop(sender);
    }

    #[test]
    fn rejects_malformed_commands_without_starting_work() {
        let (sender, _receiver) = std_mpsc::channel::<String>();
        let sender = Box::new(sender);
        let context = (&*sender as *const std_mpsc::Sender<String>)
            .cast_mut()
            .cast();
        // SAFETY: The boxed sender outlives the client and callback.
        let client = unsafe { libchess_client_create(Some(collect_event), context) };
        let malformed = b"not-json";

        assert_eq!(
            unsafe { libchess_client_send(client, malformed.as_ptr(), malformed.len()) },
            SEND_INVALID_JSON
        );

        // SAFETY: This is the only destroy and no sends run concurrently.
        unsafe { libchess_client_destroy(client) };
        drop(sender);
    }

    #[test]
    fn validates_bot_game_commands_before_calling_a_provider() {
        let (sender, receiver) = std_mpsc::channel::<String>();
        let sender = Box::new(sender);
        let context = (&*sender as *const std_mpsc::Sender<String>)
            .cast_mut()
            .cast();
        // SAFETY: The boxed sender outlives the client and callback.
        let client = unsafe { libchess_client_create(Some(collect_event), context) };
        receiver
            .recv_timeout(Duration::from_secs(2))
            .expect("ready event");
        let command = br#"{"version":1,"request_id":"bot-1","type":"create_bot_game","opponent_id":"Level 1","variant_id":"standard","time_control":{"type":"clock","initial_seconds":600,"increment_seconds":0},"color":"random"}"#;

        assert_eq!(
            unsafe { libchess_client_send(client, command.as_ptr(), command.len()) },
            SEND_OK
        );

        let error = receiver
            .recv_timeout(Duration::from_secs(2))
            .expect("validation error event");
        assert!(error.contains(r#""request_id":"bot-1""#));
        assert!(error.contains(r#""type":"error""#));
        assert!(error.contains(r#""kind":"invalid_input""#));
        assert!(error.contains("bot opponent identifiers"));

        // SAFETY: This is the only destroy and no sends run concurrently.
        unsafe { libchess_client_destroy(client) };
        drop(sender);
    }

    #[test]
    fn accepts_live_game_commands_and_validates_their_boundaries() {
        let (sender, receiver) = std_mpsc::channel::<String>();
        let sender = Box::new(sender);
        let context = (&*sender as *const std_mpsc::Sender<String>)
            .cast_mut()
            .cast();
        // SAFETY: The boxed sender outlives the client and callback.
        let client = unsafe { libchess_client_create(Some(collect_event), context) };
        receiver
            .recv_timeout(Duration::from_secs(2))
            .expect("ready event");

        let start = br#"{"version":1,"request_id":"live-1","type":"start_live_game","game_id":"v8BRXYtM","player_color":"white"}"#;
        assert_eq!(
            unsafe { libchess_client_send(client, start.as_ptr(), start.len()) },
            SEND_OK
        );
        let error = receiver
            .recv_timeout(Duration::from_secs(2))
            .expect("connection boundary error");
        assert!(error.contains(r#""request_id":"live-1""#));
        assert!(error.contains("no provider is connected"));

        let invalid_move = br#"{"version":1,"request_id":"move-1","type":"play_move","game_id":"v8BRXYtM","move_id":"e2/e4"}"#;
        assert_eq!(
            unsafe { libchess_client_send(client, invalid_move.as_ptr(), invalid_move.len()) },
            SEND_OK
        );
        let error = receiver
            .recv_timeout(Duration::from_secs(2))
            .expect("move validation error");
        assert!(error.contains(r#""request_id":"move-1""#));
        assert!(error.contains("compact ASCII move notation"));

        // SAFETY: This is the only destroy and no sends run concurrently.
        unsafe { libchess_client_destroy(client) };
        drop(sender);
    }

    #[test]
    fn emits_a_browser_authorization_request_for_oauth() {
        let (sender, receiver) = std_mpsc::channel::<String>();
        let sender = Box::new(sender);
        let context = (&*sender as *const std_mpsc::Sender<String>)
            .cast_mut()
            .cast();
        // SAFETY: The boxed sender outlives the client and callback.
        let client = unsafe { libchess_client_create(Some(collect_event), context) };
        receiver
            .recv_timeout(Duration::from_secs(2))
            .expect("ready event");
        let command = br#"{"version":1,"request_id":"oauth-1","type":"begin_oauth","provider":"lichess","client_id":"org.libchess.macos","redirect_uri":"org.libchess.macos://oauth/lichess"}"#;

        assert_eq!(
            unsafe { libchess_client_send(client, command.as_ptr(), command.len()) },
            SEND_OK
        );

        let state = receiver
            .recv_timeout(Duration::from_secs(2))
            .expect("authorization state event");
        assert!(state.contains(r#""state":"authorizing""#));
        let authorization = receiver
            .recv_timeout(Duration::from_secs(2))
            .expect("authorization URL event");
        let event: serde_json::Value =
            serde_json::from_str(&authorization).expect("authorization event JSON");
        assert_eq!(event["type"], "oauth_authorization_required");
        assert_eq!(event["provider"], "lichess");
        assert_eq!(event["scopes"], serde_json::json!(["board:play"]));
        let url = event["authorization_url"]
            .as_str()
            .expect("authorization URL");
        assert!(url.starts_with("https://lichess.org/oauth?"));
        assert!(url.contains("code_challenge_method=S256"));
        assert!(!url.contains("code_verifier"));

        // SAFETY: This is the only destroy and no sends run concurrently.
        unsafe { libchess_client_destroy(client) };
        drop(sender);
    }
}
