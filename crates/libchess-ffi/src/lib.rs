#![deny(unsafe_op_in_unsafe_fn)]

use std::{
    collections::BTreeMap,
    ffi::c_void,
    panic::{AssertUnwindSafe, catch_unwind},
    ptr, slice,
    sync::{Arc, Mutex},
    thread::{self, JoinHandle},
};

use libchess::{
    AccessToken, Account, BoardCustomizationState, BoardPresentation, BoardProviderDescriptor,
    BoardState, BotGame, BotGameRequest, BotGameTimeControl, Client, ColorPreference,
    CustomBoardTheme, CustomPieceTheme, ErrorKind, GameExport, GameHistoryPage, GameHistoryRequest,
    GameId, GameReview, LibChessError, LiveChatMessage, LiveGame, LiveGameAction,
    LiveGameCatalogEvent, LiveGameEvent, LiveGameRequest, LiveGameSummary, MoveSubmission,
    OAuthConnection, PlayerColor, ProviderDescriptor,
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
    Command(Box<CommandEnvelope>),
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
        #[serde(default)]
        provider: Option<String>,
        #[serde(default)]
        client_id: Option<String>,
        #[serde(default)]
        redirect_uri: Option<String>,
    },
    CancelOauth,
    ClearBackendSelection,
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
        #[serde(default)]
        initial_moves: Vec<String>,
        #[serde(default)]
        reply_delay_millis: Option<u32>,
    },
    Disconnect,
    ExportGame {
        game_id: String,
    },
    LoadGameReview {
        game_id: String,
    },
    LoadBoardPresentation {
        provider: String,
        board_theme: String,
        piece_theme: String,
    },
    LoadBoardCustomizationState {
        state: BoardCustomizationState,
    },
    ListBoardProviders,
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
    RefreshGameHistory {
        #[serde(default)]
        before_millis: Option<u64>,
        limit: u16,
    },
    RefreshLiveGames,
    RegisterCustomBoardTheme {
        theme: CustomBoardTheme,
    },
    RegisterCustomPieceTheme {
        theme: CustomPieceTheme,
    },
    RemoveCustomBoardTheme {
        provider: String,
        theme: String,
    },
    RemoveCustomPieceTheme {
        provider: String,
        theme: String,
    },
    ShowGameReviewPosition {
        game_id: String,
        ply: u32,
    },
    SelectBackend {
        backend: String,
    },
    StartLiveGame {
        game_id: String,
        player_color: PlayerColor,
    },
    StopLiveGame {
        game_id: String,
    },
    WatchLiveGames,
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
    BoardPresentationLoaded {
        board_presentation: BoardPresentation,
    },
    BoardProviders {
        board_providers: Vec<BoardProviderDescriptor>,
    },
    BoardCustomizationChanged {
        board_providers: Vec<BoardProviderDescriptor>,
        board_customization: BoardCustomizationState,
    },
    BackendSelectionChanged {
        #[serde(skip_serializing_if = "Option::is_none")]
        backend: Option<Box<ProviderDescriptor>>,
    },
    Error {
        error: LibChessError,
    },
    GameActionCompleted {
        game_id: String,
        action: LiveGameAction,
    },
    GameExported {
        game_export: GameExport,
    },
    GameHistoryUpdated {
        page: GameHistoryPage,
        append: bool,
    },
    GameReviewLoaded {
        review: GameReview,
        board: BoardState,
    },
    GameReviewPositionUpdated {
        game_id: String,
        ply: u32,
        board: BoardState,
    },
    LiveGameChat {
        chat: LiveChatMessage,
    },
    LiveGameStreamEnded {
        game_id: String,
    },
    LiveGameUpdated {
        live_game: Box<LiveGame>,
        san_moves: Vec<String>,
    },
    LiveGamesChanged,
    LiveGamesUpdated {
        games: Vec<LiveGameSummary>,
    },
    MovePredicted {
        game_id: String,
        move_id: String,
        board: BoardState,
        san_moves: Vec<String>,
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
        #[serde(skip_serializing_if = "Option::is_none")]
        selected_backend: Option<Box<ProviderDescriptor>>,
        board_providers: Vec<BoardProviderDescriptor>,
        board_customization: BoardCustomizationState,
        #[serde(skip_serializing_if = "Option::is_none")]
        board_presentation: Option<BoardPresentation>,
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

async fn run_worker(receiver: mpsc::UnboundedReceiver<WorkerMessage>, sink: EventSink) {
    run_worker_with_client(receiver, sink, Client::new()).await;
}

async fn run_worker_with_client(
    mut receiver: mpsc::UnboundedReceiver<WorkerMessage>,
    sink: EventSink,
    mut client: Client,
) {
    let mut live_tasks = BTreeMap::<String, tokio::task::JoinHandle<()>>::new();
    let mut catalog_task: Option<tokio::task::JoinHandle<()>> = None;
    let mut independent_tasks = Vec::<tokio::task::JoinHandle<()>>::new();
    let latest_games = Arc::new(Mutex::new(BTreeMap::<String, LiveGame>::new()));
    let game_reviews = Arc::new(Mutex::new(BTreeMap::<String, GameReview>::new()));
    let default_board_presentation = client.default_board_presentation();
    sink.emit(
        None,
        Event::Ready {
            providers: client.providers(),
            selected_backend: client.selected_backend().cloned().map(Box::new),
            board_providers: client.board_providers(),
            board_customization: client.board_customization_state(),
            board_presentation: default_board_presentation.as_ref().ok().cloned(),
        },
    );
    if let Err(error) = default_board_presentation {
        sink.emit(None, Event::Error { error });
    }

    while let Some(message) = receiver.recv().await {
        independent_tasks.retain(|task| !task.is_finished());
        match message {
            WorkerMessage::Shutdown => {
                stop_independent_tasks(&mut independent_tasks).await;
                stop_all_live_tasks(&mut live_tasks).await;
                stop_task(&mut catalog_task).await;
                break;
            }
            WorkerMessage::Command(envelope) => {
                let request_id = envelope.request_id.as_deref();
                match envelope.command {
                    Command::BeginOauth {
                        provider,
                        client_id,
                        redirect_uri,
                    } => match begin_oauth(&mut client, provider, client_id, redirect_uri) {
                        Ok(authorization) => {
                            let provider = authorization.provider.to_string();
                            sink.emit(
                                request_id,
                                Event::ConnectionStateChanged {
                                    state: ConnectionState::Authorizing,
                                    provider: Some(provider.clone()),
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
                                    provider: selected_backend_id(&client),
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
                                provider: selected_backend_id(&client),
                            },
                        );
                    }
                    Command::ClearBackendSelection => {
                        stop_independent_tasks(&mut independent_tasks).await;
                        stop_all_live_tasks(&mut live_tasks).await;
                        stop_task(&mut catalog_task).await;
                        if let Ok(mut games) = latest_games.lock() {
                            games.clear();
                        }
                        if let Ok(mut reviews) = game_reviews.lock() {
                            reviews.clear();
                        }
                        client.clear_backend_selection();
                        sink.emit(request_id, Event::BackendSelectionChanged { backend: None });
                        sink.emit(
                            request_id,
                            Event::ConnectionStateChanged {
                                state: ConnectionState::Disconnected,
                                provider: None,
                            },
                        );
                    }
                    Command::CompleteOauth { callback_url } => {
                        stop_independent_tasks(&mut independent_tasks).await;
                        sink.emit(
                            request_id,
                            Event::ConnectionStateChanged {
                                state: ConnectionState::Connecting,
                                provider: selected_backend_id(&client),
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
                                        provider: selected_backend_id(&client),
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
                    Command::ListBoardProviders => sink.emit(
                        request_id,
                        Event::BoardProviders {
                            board_providers: client.board_providers(),
                        },
                    ),
                    Command::LoadBoardCustomizationState { state } => {
                        match client.replace_board_customization_state(state) {
                            Ok(()) => sink.emit(
                                request_id,
                                Event::BoardCustomizationChanged {
                                    board_providers: client.board_providers(),
                                    board_customization: client.board_customization_state(),
                                },
                            ),
                            Err(error) => sink.emit(request_id, Event::Error { error }),
                        }
                    }
                    Command::RegisterCustomBoardTheme { theme } => {
                        match client.register_custom_board_theme(theme) {
                            Ok(()) => sink.emit(
                                request_id,
                                Event::BoardCustomizationChanged {
                                    board_providers: client.board_providers(),
                                    board_customization: client.board_customization_state(),
                                },
                            ),
                            Err(error) => sink.emit(request_id, Event::Error { error }),
                        }
                    }
                    Command::RegisterCustomPieceTheme { theme } => {
                        match client.register_custom_piece_theme(theme) {
                            Ok(()) => sink.emit(
                                request_id,
                                Event::BoardCustomizationChanged {
                                    board_providers: client.board_providers(),
                                    board_customization: client.board_customization_state(),
                                },
                            ),
                            Err(error) => sink.emit(request_id, Event::Error { error }),
                        }
                    }
                    Command::RemoveCustomBoardTheme { provider, theme } => {
                        match client.remove_custom_board_theme(&provider, &theme) {
                            Ok(true) => sink.emit(
                                request_id,
                                Event::BoardCustomizationChanged {
                                    board_providers: client.board_providers(),
                                    board_customization: client.board_customization_state(),
                                },
                            ),
                            Ok(false) => sink.emit(
                                request_id,
                                Event::Error {
                                    error: LibChessError::invalid_input(
                                        "the custom board theme does not exist",
                                    ),
                                },
                            ),
                            Err(error) => sink.emit(request_id, Event::Error { error }),
                        }
                    }
                    Command::RemoveCustomPieceTheme { provider, theme } => {
                        match client.remove_custom_piece_theme(&provider, &theme) {
                            Ok(true) => sink.emit(
                                request_id,
                                Event::BoardCustomizationChanged {
                                    board_providers: client.board_providers(),
                                    board_customization: client.board_customization_state(),
                                },
                            ),
                            Ok(false) => sink.emit(
                                request_id,
                                Event::Error {
                                    error: LibChessError::invalid_input(
                                        "the custom piece theme does not exist",
                                    ),
                                },
                            ),
                            Err(error) => sink.emit(request_id, Event::Error { error }),
                        }
                    }
                    Command::LoadBoardPresentation {
                        provider,
                        board_theme,
                        piece_theme,
                    } => match client.board_presentation(&provider, &board_theme, &piece_theme) {
                        Ok(board_presentation) => sink.emit(
                            request_id,
                            Event::BoardPresentationLoaded { board_presentation },
                        ),
                        Err(error) => sink.emit(request_id, Event::Error { error }),
                    },
                    Command::ExportGame { game_id } => {
                        match (GameId::new(game_id), client.connected_backend()) {
                            (Ok(game_id), Ok(backend)) => {
                                let task_sink = sink.clone();
                                let task_request_id = envelope.request_id.clone();
                                independent_tasks.push(tokio::spawn(async move {
                                    match backend.export_game(game_id).await {
                                        Ok(game_export) => task_sink.emit(
                                            task_request_id.as_deref(),
                                            Event::GameExported { game_export },
                                        ),
                                        Err(error) => task_sink.emit(
                                            task_request_id.as_deref(),
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
                    Command::LoadGameReview { game_id } => {
                        match (GameId::new(&game_id), client.connected_backend()) {
                            (Ok(valid_game_id), Ok(backend)) => {
                                let task_sink = sink.clone();
                                let task_request_id = envelope.request_id.clone();
                                let task_reviews = Arc::clone(&game_reviews);
                                independent_tasks.push(tokio::spawn(async move {
                                    match backend.review_game(valid_game_id).await {
                                        Ok(review) => {
                                            match review_position(&review, review.moves.len()) {
                                                Ok(board) => {
                                                    if let Ok(mut reviews) = task_reviews.lock() {
                                                        reviews.insert(game_id, review.clone());
                                                    }
                                                    task_sink.emit(
                                                        task_request_id.as_deref(),
                                                        Event::GameReviewLoaded { review, board },
                                                    );
                                                }
                                                Err(error) => task_sink.emit(
                                                    task_request_id.as_deref(),
                                                    Event::Error { error },
                                                ),
                                            }
                                        }
                                        Err(error) => task_sink.emit(
                                            task_request_id.as_deref(),
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
                    Command::Connect {
                        provider,
                        access_token,
                    } => {
                        stop_independent_tasks(&mut independent_tasks).await;
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
                    Command::SelectBackend { backend } => {
                        stop_independent_tasks(&mut independent_tasks).await;
                        match client.select_backend(&backend).await {
                            Ok(selection) => {
                                stop_all_live_tasks(&mut live_tasks).await;
                                stop_task(&mut catalog_task).await;
                                if let Ok(mut games) = latest_games.lock() {
                                    games.clear();
                                }
                                if let Ok(mut reviews) = game_reviews.lock() {
                                    reviews.clear();
                                }
                                sink.emit(
                                    request_id,
                                    Event::BackendSelectionChanged {
                                        backend: Some(Box::new(selection.backend.clone())),
                                    },
                                );
                                if let Some(account) = selection.account {
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
                                } else {
                                    sink.emit(
                                        request_id,
                                        Event::ConnectionStateChanged {
                                            state: ConnectionState::Disconnected,
                                            provider: Some(selection.backend.id.to_string()),
                                        },
                                    );
                                }
                            }
                            Err(error) => sink.emit(request_id, Event::Error { error }),
                        }
                    }
                    Command::CreateBotGame {
                        opponent_id,
                        variant_id,
                        time_control,
                        color,
                        initial_fen,
                        initial_moves,
                        reply_delay_millis,
                    } => {
                        let request = BotGameRequest::new(
                            opponent_id,
                            variant_id,
                            time_control,
                            color,
                            initial_fen,
                        )
                        .and_then(|request| request.with_initial_moves(initial_moves))
                        .and_then(|request| match reply_delay_millis {
                            Some(value) => request.with_reply_delay_millis(value),
                            None => Ok(request),
                        });
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
                        stop_live_task(&mut live_tasks, &game_id).await;
                        let request = LiveGameRequest::new(game_id.clone(), player_color);
                        match (request, client.connected_backend()) {
                            (Ok(request), Ok(backend)) => {
                                let event_sink = sink.clone();
                                let stream_sink = sink.clone();
                                let stream_request_id = envelope.request_id.clone();
                                let ended_game_id = game_id.clone();
                                let stream_games = Arc::clone(&latest_games);
                                let task = tokio::spawn(async move {
                                    let events = Arc::new(move |event| match event {
                                        LiveGameEvent::GameUpdated { game } => {
                                            let san_moves = live_game_san_moves(&game);
                                            if let Ok(mut games) = stream_games.lock() {
                                                games.insert(game.id.to_string(), (*game).clone());
                                            }
                                            event_sink.emit(
                                                None,
                                                Event::LiveGameUpdated {
                                                    live_game: game,
                                                    san_moves,
                                                },
                                            );
                                        }
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
                                });
                                live_tasks.insert(game_id, task);
                            }
                            (Err(error), _) | (_, Err(error)) => {
                                sink.emit(request_id, Event::Error { error });
                            }
                        }
                    }
                    Command::StopLiveGame { game_id } => {
                        stop_live_task(&mut live_tasks, &game_id).await;
                        if let Ok(mut games) = latest_games.lock() {
                            games.remove(&game_id);
                        }
                    }
                    Command::PlayMove {
                        game_id,
                        move_id,
                        offer_draw,
                    } => match MoveSubmission::new(&game_id, &move_id, offer_draw) {
                        Ok(submission) => match predict_move(&latest_games, &game_id, &move_id) {
                            Ok((board, san_moves)) => {
                                sink.emit(
                                    request_id,
                                    Event::MovePredicted {
                                        game_id: game_id.clone(),
                                        move_id: move_id.clone(),
                                        board,
                                        san_moves,
                                    },
                                );
                                match client.play_move(submission).await {
                                    Ok(()) => sink.emit(
                                        request_id,
                                        Event::MoveSubmitted { game_id, move_id },
                                    ),
                                    Err(error) => sink.emit(request_id, Event::Error { error }),
                                }
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
                    Command::RefreshGameHistory {
                        before_millis,
                        limit,
                    } => {
                        let append = before_millis.is_some();
                        let request = client
                            .account()
                            .ok_or_else(|| LibChessError::invalid_input("no provider is connected"))
                            .and_then(|account| {
                                GameHistoryRequest::new(
                                    account.id.clone(),
                                    account.username.clone(),
                                    limit,
                                    before_millis,
                                )
                            });
                        match (request, client.connected_backend()) {
                            (Ok(request), Ok(backend)) => {
                                let task_sink = sink.clone();
                                let task_request_id = envelope.request_id.clone();
                                independent_tasks.push(tokio::spawn(async move {
                                    match backend.game_history(request).await {
                                        Ok(page) => task_sink.emit(
                                            task_request_id.as_deref(),
                                            Event::GameHistoryUpdated { page, append },
                                        ),
                                        Err(error) => task_sink.emit(
                                            task_request_id.as_deref(),
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
                    Command::RefreshLiveGames => match client.connected_backend() {
                        Ok(backend) => match backend.live_games().await {
                            Ok(games) => sink.emit(request_id, Event::LiveGamesUpdated { games }),
                            Err(error) => sink.emit(request_id, Event::Error { error }),
                        },
                        Err(error) => sink.emit(request_id, Event::Error { error }),
                    },
                    Command::ShowGameReviewPosition { game_id, ply } => {
                        let review = game_reviews
                            .lock()
                            .ok()
                            .and_then(|reviews| reviews.get(&game_id).cloned());
                        match review.as_ref() {
                            Some(review) => match usize::try_from(ply)
                                .ok()
                                .filter(|ply| *ply <= review.moves.len())
                            {
                                Some(position_ply) => match review_position(review, position_ply) {
                                    Ok(board) => sink.emit(
                                        request_id,
                                        Event::GameReviewPositionUpdated {
                                            game_id,
                                            ply,
                                            board,
                                        },
                                    ),
                                    Err(error) => sink.emit(request_id, Event::Error { error }),
                                },
                                None => sink.emit(
                                    request_id,
                                    Event::Error {
                                        error: LibChessError::invalid_input(
                                            "the requested review position is outside the game",
                                        ),
                                    },
                                ),
                            },
                            None => sink.emit(
                                request_id,
                                Event::Error {
                                    error: LibChessError::invalid_input(
                                        "the game review has not loaded yet",
                                    ),
                                },
                            ),
                        }
                    }
                    Command::WatchLiveGames => {
                        stop_task(&mut catalog_task).await;
                        match client.connected_backend() {
                            Ok(backend) => {
                                let event_sink = sink.clone();
                                let stream_sink = sink.clone();
                                let stream_request_id = envelope.request_id.clone();
                                catalog_task = Some(tokio::spawn(async move {
                                    let events = Arc::new(move |event| match event {
                                        LiveGameCatalogEvent::Changed => {
                                            event_sink.emit(None, Event::LiveGamesChanged)
                                        }
                                    });
                                    if let Err(error) =
                                        backend.watch_live_game_catalog(events).await
                                    {
                                        stream_sink.emit(
                                            stream_request_id.as_deref(),
                                            Event::Error { error },
                                        );
                                    }
                                }));
                            }
                            Err(error) => sink.emit(request_id, Event::Error { error }),
                        }
                    }
                    Command::Disconnect => {
                        stop_independent_tasks(&mut independent_tasks).await;
                        stop_all_live_tasks(&mut live_tasks).await;
                        stop_task(&mut catalog_task).await;
                        if let Ok(mut games) = latest_games.lock() {
                            games.clear();
                        }
                        if let Ok(mut reviews) = game_reviews.lock() {
                            reviews.clear();
                        }
                        client.disconnect();
                        sink.emit(
                            request_id,
                            Event::ConnectionStateChanged {
                                state: ConnectionState::Disconnected,
                                provider: selected_backend_id(&client),
                            },
                        );
                    }
                }
            }
        }
    }

    stop_independent_tasks(&mut independent_tasks).await;
    stop_all_live_tasks(&mut live_tasks).await;
    stop_task(&mut catalog_task).await;
}

fn begin_oauth(
    client: &mut Client,
    provider: Option<String>,
    client_id: Option<String>,
    redirect_uri: Option<String>,
) -> Result<libchess::OAuthAuthorization, LibChessError> {
    match (provider, client_id, redirect_uri) {
        (None, None, None) => client.begin_selected_oauth(),
        (Some(provider), Some(client_id), Some(redirect_uri)) => {
            client.begin_oauth(&provider, client_id, redirect_uri)
        }
        _ => Err(LibChessError::invalid_input(
            "OAuth configuration must be omitted or supplied as one complete legacy configuration",
        )),
    }
}

fn selected_backend_id(client: &Client) -> Option<String> {
    client
        .selected_backend()
        .map(|backend| backend.id.to_string())
}

fn review_position(review: &GameReview, ply: usize) -> Result<BoardState, LibChessError> {
    let moves = review
        .moves
        .iter()
        .take(ply)
        .map(|review_move| review_move.move_id.clone())
        .collect::<Vec<_>>();
    let mut board =
        libchess_rules::reconstruct(review.variant_id.as_str(), &review.initial_fen, &moves)
            .map_err(|error| {
                LibChessError::new(
                    ErrorKind::Provider,
                    format!("could not reconstruct the reviewed position: {error}"),
                    false,
                )
            })?;
    board.legal_moves.clear();
    Ok(board)
}

fn live_game_san_moves(game: &LiveGame) -> Vec<String> {
    libchess_rules::san_moves(
        game.variant_id.as_str(),
        &game.initial_fen,
        &game.state.board.moves,
    )
    .unwrap_or_default()
}

fn predict_move(
    latest_games: &Mutex<BTreeMap<String, LiveGame>>,
    game_id: &str,
    move_id: &str,
) -> Result<(BoardState, Vec<String>), LibChessError> {
    let game = latest_games
        .lock()
        .map_err(|_| {
            LibChessError::new(ErrorKind::Provider, "live-game state is unavailable", true)
        })?
        .get(game_id)
        .cloned()
        .ok_or_else(|| LibChessError::invalid_input("the live game has not loaded yet"))?;
    if !game
        .state
        .board
        .legal_moves
        .iter()
        .any(|legal_move| legal_move.id == move_id)
    {
        return Err(LibChessError::invalid_input(
            "the move is not legal in the current position",
        ));
    }
    let mut moves = game.state.board.moves.clone();
    moves.push(move_id.to_owned());
    let board = libchess_rules::reconstruct(game.variant_id.as_str(), &game.initial_fen, &moves)
        .map_err(|error| {
            LibChessError::new(
                ErrorKind::Provider,
                format!("could not predict the legal move: {error}"),
                false,
            )
        })?;
    let san_moves = libchess_rules::san_moves(game.variant_id.as_str(), &game.initial_fen, &moves)
        .map_err(|error| {
            LibChessError::new(
                ErrorKind::Provider,
                format!("could not render the predicted move notation: {error}"),
                false,
            )
        })?;
    Ok((board, san_moves))
}

async fn stop_independent_tasks(tasks: &mut Vec<tokio::task::JoinHandle<()>>) {
    for task in std::mem::take(tasks) {
        task.abort();
        let _ = task.await;
    }
}

async fn stop_live_task(tasks: &mut BTreeMap<String, tokio::task::JoinHandle<()>>, game_id: &str) {
    if let Some(task) = tasks.remove(game_id) {
        task.abort();
        let _ = task.await;
    }
}

async fn stop_all_live_tasks(tasks: &mut BTreeMap<String, tokio::task::JoinHandle<()>>) {
    for (_, task) in std::mem::take(tasks) {
        task.abort();
        let _ = task.await;
    }
}

async fn stop_task(task: &mut Option<tokio::task::JoinHandle<()>>) {
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
        match client
            .sender
            .send(WorkerMessage::Command(Box::new(command)))
        {
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
    use std::{collections::BTreeSet, sync::mpsc as std_mpsc, time::Duration};

    use async_trait::async_trait;
    use libchess::{
        BackendConnection, BackendIcon, BackendKind, ClientBuilder, PlatformBackend,
        PlatformBackendFactory, PlatformCapability, ProviderId,
    };
    use tokio::sync::oneshot;

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

    extern "C" fn discard_event(_: *mut c_void, _: *const u8, _: usize) {}

    struct SlowExportBackend {
        descriptor: ProviderDescriptor,
        export_started: Mutex<Option<std_mpsc::Sender<()>>>,
        export_release: Mutex<Option<oneshot::Receiver<()>>>,
        action_called: Mutex<Option<std_mpsc::Sender<()>>>,
    }

    #[async_trait]
    impl PlatformBackend for SlowExportBackend {
        fn descriptor(&self) -> &ProviderDescriptor {
            &self.descriptor
        }

        async fn account(&self) -> Result<Account, LibChessError> {
            Ok(Account {
                provider: self.descriptor.id.clone(),
                id: "responsive-worker".to_owned(),
                username: "Responsive Worker".to_owned(),
                title: None,
            })
        }

        async fn export_game(&self, _game_id: GameId) -> Result<GameExport, LibChessError> {
            let release = self
                .export_release
                .lock()
                .expect("export release lock")
                .take()
                .expect("export release receiver");
            self.export_started
                .lock()
                .expect("export-started lock")
                .take()
                .expect("export-started sender")
                .send(())
                .expect("signal export start");
            let _ = release.await;
            Err(LibChessError::new(
                ErrorKind::Provider,
                "test export released",
                true,
            ))
        }

        async fn perform_game_action(
            &self,
            _game_id: GameId,
            _action: LiveGameAction,
        ) -> Result<(), LibChessError> {
            self.action_called
                .lock()
                .expect("action-called lock")
                .take()
                .expect("action-called sender")
                .send(())
                .expect("signal game action");
            Ok(())
        }
    }

    struct SlowExportFactory {
        backend: Arc<SlowExportBackend>,
    }

    impl PlatformBackendFactory for SlowExportFactory {
        fn descriptor(&self) -> &ProviderDescriptor {
            self.backend.descriptor()
        }

        fn create(&self, _token: AccessToken) -> Result<Arc<dyn PlatformBackend>, LibChessError> {
            Ok(self.backend.clone())
        }

        fn create_local(&self) -> Result<Arc<dyn PlatformBackend>, LibChessError> {
            Ok(self.backend.clone())
        }
    }

    #[test]
    fn slow_export_does_not_block_an_independent_game_action() {
        let descriptor = ProviderDescriptor {
            id: ProviderId::new("responsive-test").expect("test provider ID"),
            kind: BackendKind::LocalEngine,
            display_name: "Responsive Test".to_owned(),
            subtitle: "Test backend".to_owned(),
            description: "Exercises worker scheduling.".to_owned(),
            icon: BackendIcon::Processor,
            action_title: "Use Test Backend".to_owned(),
            web_url: None,
            connection: BackendConnection::Local,
            available: true,
            unavailable_reason: None,
            capabilities: BTreeSet::from([
                PlatformCapability::Account,
                PlatformCapability::LiveGames,
                PlatformCapability::PgnExport,
            ]),
            bot_opponents: Vec::new(),
            bot_game_options: None,
        };
        let (export_started_sender, export_started_receiver) = std_mpsc::channel();
        let (export_release_sender, export_release_receiver) = oneshot::channel();
        let (action_called_sender, action_called_receiver) = std_mpsc::channel();
        let backend = Arc::new(SlowExportBackend {
            descriptor,
            export_started: Mutex::new(Some(export_started_sender)),
            export_release: Mutex::new(Some(export_release_receiver)),
            action_called: Mutex::new(Some(action_called_sender)),
        });
        let (sender, receiver) = mpsc::unbounded_channel();
        let worker = thread::spawn(move || {
            let runtime = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .expect("test runtime");
            runtime.block_on(async move {
                let mut client = ClientBuilder::empty()
                    .register(SlowExportFactory { backend })
                    .build();
                client
                    .select_backend("responsive-test")
                    .await
                    .expect("select test backend");
                run_worker_with_client(
                    receiver,
                    EventSink {
                        callback: discard_event,
                        context_address: 0,
                    },
                    client,
                )
                .await;
            });
        });

        sender
            .send(WorkerMessage::Command(Box::new(CommandEnvelope {
                version: API_VERSION,
                request_id: Some("slow-export".to_owned()),
                command: Command::ExportGame {
                    game_id: "game-1".to_owned(),
                },
            })))
            .expect("queue slow export");
        export_started_receiver
            .recv_timeout(Duration::from_secs(2))
            .expect("slow export started");

        sender
            .send(WorkerMessage::Command(Box::new(CommandEnvelope {
                version: API_VERSION,
                request_id: Some("urgent-action".to_owned()),
                command: Command::PerformGameAction {
                    game_id: "game-1".to_owned(),
                    action: LiveGameAction::Resign,
                },
            })))
            .expect("queue game action");
        let action_result = action_called_receiver.recv_timeout(Duration::from_secs(2));

        let _ = export_release_sender.send(());
        sender
            .send(WorkerMessage::Shutdown)
            .expect("stop test worker");
        worker.join().expect("test worker joined");

        action_result.expect("game action ran while export remained pending");
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
        assert!(ready.contains(r#""id":"stockfish""#));
        assert!(ready.contains(r#""kind":"local_engine""#));
        assert!(ready.contains(r#""bot_opponents""#));
        assert!(ready.contains(r#""id":"level-1""#));
        assert!(ready.contains(r#""game_review""#));
        assert!(ready.contains(r#""board_providers""#));
        assert!(ready.contains(r#""board_customization":{"version":1"#));
        assert!(ready.contains(r#""default_board_theme":"classic""#));
        assert!(ready.contains(r#""default_piece_theme":"system-solid""#));
        assert!(ready.contains(r#""board_presentation""#));
        assert!(ready.contains(r#""kind":"text_glyph""#));

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

        let board_command = br#"{"version":1,"request_id":"board-1","type":"load_board_presentation","provider":"libchess","board_theme":"ocean","piece_theme":"cc0-silhouette"}"#;
        assert_eq!(
            unsafe { libchess_client_send(client, board_command.as_ptr(), board_command.len()) },
            SEND_OK
        );
        let board_presentation = receiver
            .recv_timeout(Duration::from_secs(2))
            .expect("board presentation event");
        assert!(board_presentation.contains(r#""request_id":"board-1""#));
        assert!(board_presentation.contains(r#""type":"board_presentation_loaded""#));
        assert!(board_presentation.contains(r#""board_theme":"ocean""#));
        assert!(board_presentation.contains(r#""piece_theme":"cc0-silhouette""#));
        assert!(board_presentation.contains(r#""kind":"svg""#));
        assert!(board_presentation.contains(r#""duration_millis":260"#));

        let custom_board = br#"{"version":1,"request_id":"custom-board-1","type":"register_custom_board_theme","theme":{"provider":"libchess","id":"night-board","display_name":"Night Board","base_theme":"slate","adjustment":{"hue_degrees":18,"saturation_percent":12,"brightness_percent":-20},"colors":{"light_square":{"red":160,"green":170,"blue":180,"alpha":255},"dark_square":{"red":35,"green":45,"blue":60,"alpha":255}}}}"#;
        assert_eq!(
            unsafe { libchess_client_send(client, custom_board.as_ptr(), custom_board.len()) },
            SEND_OK
        );
        let custom_board_event = receiver
            .recv_timeout(Duration::from_secs(2))
            .expect("custom board event");
        assert!(custom_board_event.contains(r#""type":"board_customization_changed""#));
        assert!(custom_board_event.contains(r#""id":"night-board""#));

        let custom_pieces = br#"{"version":1,"request_id":"custom-pieces-1","type":"register_custom_piece_theme","theme":{"provider":"libchess","id":"blue-pieces","display_name":"Blue Pieces","base_theme":"system-solid","adjustment":{"hue_degrees":0,"saturation_percent":0,"brightness_percent":0},"colors":{"black_piece":{"red":20,"green":60,"blue":180,"alpha":255}},"assets":null}}"#;
        assert_eq!(
            unsafe { libchess_client_send(client, custom_pieces.as_ptr(), custom_pieces.len()) },
            SEND_OK
        );
        let custom_piece_event = receiver
            .recv_timeout(Duration::from_secs(2))
            .expect("custom piece event");
        assert!(custom_piece_event.contains(r#""id":"blue-pieces""#));

        let custom_presentation = br#"{"version":1,"request_id":"custom-presentation-1","type":"load_board_presentation","provider":"libchess","board_theme":"night-board","piece_theme":"blue-pieces"}"#;
        assert_eq!(
            unsafe {
                libchess_client_send(
                    client,
                    custom_presentation.as_ptr(),
                    custom_presentation.len(),
                )
            },
            SEND_OK
        );
        let custom_presentation_event = receiver
            .recv_timeout(Duration::from_secs(2))
            .expect("custom presentation event");
        assert!(custom_presentation_event.contains(r#""board_theme":"night-board""#));
        assert!(custom_presentation_event.contains(r#""piece_theme":"blue-pieces""#));
        assert!(custom_presentation_event.contains(r#""display_name":"Night Board""#));
        assert!(custom_presentation_event.contains(r#""display_name":"Blue Pieces""#));

        // SAFETY: This is the only destroy and no sends run concurrently.
        unsafe { libchess_client_destroy(client) };
        drop(sender);
    }

    #[test]
    fn selects_and_plays_through_the_local_engine_protocol() {
        let (sender, receiver) = std_mpsc::channel::<String>();
        let sender = Box::new(sender);
        let context = (&*sender as *const std_mpsc::Sender<String>)
            .cast_mut()
            .cast();
        // SAFETY: The boxed sender outlives the client and callback.
        let client = unsafe { libchess_client_create(Some(collect_event), context) };
        assert!(!client.is_null());

        let ready = receiver
            .recv_timeout(Duration::from_secs(3))
            .expect("ready event");
        let ready: serde_json::Value = serde_json::from_str(&ready).expect("ready JSON");
        let stockfish_available = ready["providers"]
            .as_array()
            .and_then(|providers| {
                providers
                    .iter()
                    .find(|provider| provider["id"] == "stockfish")
            })
            .and_then(|provider| provider["available"].as_bool())
            .unwrap_or(false);
        if !stockfish_available {
            // SAFETY: This is the only destroy and no sends run concurrently.
            unsafe { libchess_client_destroy(client) };
            drop(sender);
            return;
        }

        let select = br#"{"version":1,"request_id":"select-local","type":"select_backend","backend":"stockfish"}"#;
        assert_eq!(
            unsafe { libchess_client_send(client, select.as_ptr(), select.len()) },
            SEND_OK
        );
        let selected = receiver
            .recv_timeout(Duration::from_secs(3))
            .expect("selection event");
        assert!(selected.contains(r#""type":"backend_selection_changed""#));
        assert!(selected.contains(r#""id":"stockfish""#));
        let account = receiver
            .recv_timeout(Duration::from_secs(3))
            .expect("local account event");
        assert!(account.contains(r#""type":"account_updated""#));
        let connected = receiver
            .recv_timeout(Duration::from_secs(3))
            .expect("local connection event");
        assert!(connected.contains(r#""state":"connected""#));

        let create = br#"{"version":1,"request_id":"create-local","type":"create_bot_game","opponent_id":"skill-0","variant_id":"standard","time_control":{"type":"unlimited"},"color":"white","reply_delay_millis":0}"#;
        assert_eq!(
            unsafe { libchess_client_send(client, create.as_ptr(), create.len()) },
            SEND_OK
        );
        let created = receiver
            .recv_timeout(Duration::from_secs(5))
            .expect("local game event");
        let created: serde_json::Value = serde_json::from_str(&created).expect("game JSON");
        assert_eq!(created["type"], "bot_game_created");
        assert_eq!(created["game"]["url"], "");
        assert_eq!(created["game"]["speed"], "unlimited");
        let game_id = created["game"]["id"]
            .as_str()
            .expect("local game id")
            .to_owned();

        let start = serde_json::to_vec(&serde_json::json!({
            "version": 1,
            "request_id": "start-local",
            "type": "start_live_game",
            "game_id": game_id,
            "player_color": "white"
        }))
        .expect("start command");
        assert_eq!(
            unsafe { libchess_client_send(client, start.as_ptr(), start.len()) },
            SEND_OK
        );
        let initial = receiver
            .recv_timeout(Duration::from_secs(3))
            .expect("initial local snapshot");
        assert!(initial.contains(r#""type":"live_game_updated""#));

        let play = serde_json::to_vec(&serde_json::json!({
            "version": 1,
            "request_id": "move-local",
            "type": "play_move",
            "game_id": game_id,
            "move_id": "e2e4"
        }))
        .expect("move command");
        assert_eq!(
            unsafe { libchess_client_send(client, play.as_ptr(), play.len()) },
            SEND_OK
        );
        let mut predicted = false;
        let mut authoritative_reply = false;
        let mut submitted = false;
        for _ in 0..6 {
            let event = receiver
                .recv_timeout(Duration::from_secs(5))
                .expect("local move event");
            let event: serde_json::Value = serde_json::from_str(&event).expect("move event JSON");
            match event["type"].as_str() {
                Some("move_predicted") => predicted = true,
                Some("move_submitted") => submitted = true,
                Some("live_game_updated") => {
                    authoritative_reply = event["live_game"]["state"]["board"]["moves"]
                        .as_array()
                        .is_some_and(|moves| moves.len() == 2);
                }
                Some("error") => panic!("local move failed: {event}"),
                _ => {}
            }
            if predicted && authoritative_reply && submitted {
                break;
            }
        }
        assert!(predicted);
        assert!(authoritative_reply);
        assert!(submitted);

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

        let history =
            br#"{"version":1,"request_id":"history-1","type":"refresh_game_history","limit":20}"#;
        assert_eq!(
            unsafe { libchess_client_send(client, history.as_ptr(), history.len()) },
            SEND_OK
        );
        let error = receiver
            .recv_timeout(Duration::from_secs(2))
            .expect("history connection error");
        assert!(error.contains(r#""request_id":"history-1""#));
        assert!(error.contains("no provider is connected"));

        let invalid_export =
            br#"{"version":1,"request_id":"export-1","type":"export_game","game_id":"../game"}"#;
        assert_eq!(
            unsafe { libchess_client_send(client, invalid_export.as_ptr(), invalid_export.len()) },
            SEND_OK
        );
        let error = receiver
            .recv_timeout(Duration::from_secs(2))
            .expect("export validation error");
        assert!(error.contains(r#""request_id":"export-1""#));
        assert!(error.contains("game identifiers"));

        let invalid_review =
            br#"{"version":1,"request_id":"review-1","type":"load_game_review","game_id":"../game"}"#;
        assert_eq!(
            unsafe { libchess_client_send(client, invalid_review.as_ptr(), invalid_review.len()) },
            SEND_OK
        );
        let error = receiver
            .recv_timeout(Duration::from_secs(2))
            .expect("review validation error");
        assert!(error.contains(r#""request_id":"review-1""#));
        assert!(error.contains("game identifiers"));

        // SAFETY: This is the only destroy and no sends run concurrently.
        unsafe { libchess_client_destroy(client) };
        drop(sender);
    }

    #[test]
    fn predicts_a_legal_move_from_the_authoritative_snapshot() {
        let game: LiveGame = serde_json::from_value(serde_json::json!({
            "provider": "lichess",
            "id": "v8BRXYtM",
            "url": "https://lichess.org/v8BRXYtM",
            "player_color": "white",
            "initial_fen": "startpos",
            "variant_id": "standard",
            "variant_name": "Standard",
            "rated": false,
            "speed": "rapid",
            "white": {"name": "TestUser", "provisional": false},
            "black": {"name": "Stockfish level 4", "provisional": false, "ai_level": 4},
            "state": {
                "board": {
                    "pieces": [],
                    "pockets": [],
                    "turn": "white",
                    "ply": 0,
                    "moves": [],
                    "legal_moves": [{"id": "e2e4", "from": "e2", "to": "e4"}],
                    "in_check": false
                },
                "status": "started",
                "white_draw_offer": false,
                "black_draw_offer": false,
                "white_takeback_offer": false,
                "black_takeback_offer": false,
                "opponent_gone": false
            }
        }))
        .expect("live game fixture");
        let games = Mutex::new(BTreeMap::from([(game.id.to_string(), game)]));

        let (predicted, san_moves) =
            predict_move(&games, "v8BRXYtM", "e2e4").expect("legal prediction");

        assert_eq!(predicted.moves, ["e2e4"]);
        assert_eq!(san_moves, ["e4"]);
        assert_eq!(predicted.turn, PlayerColor::Black);
        assert_eq!(predicted.ply, 1);
        assert!(predicted.pieces.iter().any(|piece| piece.square == "e4"));
        assert!(!predicted.pieces.iter().any(|piece| piece.square == "e2"));

        let event = serde_json::to_value(EventEnvelope {
            version: API_VERSION,
            request_id: Some("move-1"),
            event: Event::MovePredicted {
                game_id: "v8BRXYtM".to_owned(),
                move_id: "e2e4".to_owned(),
                board: predicted,
                san_moves,
            },
        })
        .expect("predicted move event");
        assert_eq!(event["san_moves"], serde_json::json!(["e4"]));

        let error = predict_move(&games, "v8BRXYtM", "e2e5")
            .expect_err("an illegal move must not be predicted");
        assert_eq!(error.kind, ErrorKind::InvalidInput);
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
