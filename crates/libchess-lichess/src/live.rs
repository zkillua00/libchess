use std::time::Duration;

use libchess_core::{
    ErrorKind, GameId, GameStatus, GameVariantId, LibChessError, LiveChatMessage, LiveGame,
    LiveGameAction, LiveGameClock, LiveGameEvent, LiveGameEventSink, LiveGamePlayer,
    LiveGameRequest, LiveGameState, MoveSubmission, PlayerColor,
};
use reqwest::{StatusCode, header};
use serde::Deserialize;

use super::{
    LichessBackend, LichessErrorResponse, canonical_variant_id, map_status, map_transport_error,
    truncate, validate_game_id,
};

const MAX_STREAM_LINE_BYTES: usize = 256 * 1024;

pub(super) async fn watch(
    backend: &LichessBackend,
    request: LiveGameRequest,
    events: LiveGameEventSink,
) -> Result<(), LibChessError> {
    validate_game_id(request.game_id.as_str())?;
    let mut response = backend
        .http
        .get(backend.endpoint(&format!("api/board/game/stream/{}", request.game_id))?)
        .header(header::ACCEPT, "application/x-ndjson")
        .bearer_auth(backend.token.expose())
        .send()
        .await
        .map_err(map_transport_error)?;

    let status = response.status();
    if !status.is_success() {
        return Err(map_status(status));
    }

    let mut context = StreamContext::new(backend, request, events);
    let mut buffer = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(map_transport_error)? {
        buffer.extend_from_slice(&chunk);
        while let Some(newline) = buffer.iter().position(|byte| *byte == b'\n') {
            let mut line = buffer.drain(..=newline).collect::<Vec<_>>();
            line.pop();
            if line.last() == Some(&b'\r') {
                line.pop();
            }
            context.consume(&line)?;
        }
        if buffer.len() > MAX_STREAM_LINE_BYTES {
            return Err(protocol_error("Lichess sent an oversized live-game event"));
        }
    }

    if !buffer.is_empty() {
        context.consume(&buffer)?;
    }
    let game = context
        .game
        .ok_or_else(|| protocol_error("Lichess ended the game stream before gameFull"))?;
    if game.state.status.is_playable() {
        return Err(LibChessError::new(
            ErrorKind::Network,
            "the Lichess live-game stream ended while the game was still active",
            true,
        ));
    }
    Ok(())
}

pub(super) async fn play_move(
    backend: &LichessBackend,
    submission: MoveSubmission,
) -> Result<(), LibChessError> {
    validate_game_id(submission.game_id.as_str())?;
    let mut url = backend.endpoint(&format!(
        "api/board/game/{}/move/{}",
        submission.game_id, submission.move_id
    ))?;
    url.query_pairs_mut().append_pair(
        "offeringDraw",
        if submission.offer_draw {
            "true"
        } else {
            "false"
        },
    );
    post_action(backend, url).await
}

pub(super) async fn perform_action(
    backend: &LichessBackend,
    game_id: GameId,
    action: LiveGameAction,
) -> Result<(), LibChessError> {
    validate_game_id(game_id.as_str())?;
    let suffix = match action {
        LiveGameAction::Abort => "abort",
        LiveGameAction::Resign => "resign",
        LiveGameAction::OfferDraw | LiveGameAction::AcceptDraw => "draw/yes",
        LiveGameAction::DeclineDraw => "draw/no",
        LiveGameAction::OfferTakeback | LiveGameAction::AcceptTakeback => "takeback/yes",
        LiveGameAction::DeclineTakeback => "takeback/no",
        LiveGameAction::ClaimVictory => "claim-victory",
        LiveGameAction::ClaimDraw => "claim-draw",
    };
    let url = backend.endpoint(&format!("api/board/game/{game_id}/{suffix}"))?;
    post_action(backend, url).await
}

async fn post_action(backend: &LichessBackend, url: reqwest::Url) -> Result<(), LibChessError> {
    let response = backend
        .http
        .post(url)
        .header(header::ACCEPT, "application/json")
        .bearer_auth(backend.token.expose())
        .timeout(Duration::from_secs(15))
        .send()
        .await
        .map_err(map_transport_error)?;
    let status = response.status();
    if status.is_success() {
        return Ok(());
    }
    if status == StatusCode::BAD_REQUEST {
        let detail = response
            .json::<LichessErrorResponse>()
            .await
            .ok()
            .and_then(|response| response.error)
            .map(|message| truncate(&message, 256));
        return Err(LibChessError::invalid_input(detail.map_or_else(
            || "Lichess rejected the game action".to_owned(),
            |detail| format!("Lichess rejected the game action: {detail}"),
        )));
    }
    Err(map_status(status))
}

struct StreamContext<'a> {
    backend: &'a LichessBackend,
    request: LiveGameRequest,
    events: LiveGameEventSink,
    game: Option<LiveGame>,
    initial_fen: Option<String>,
}

impl<'a> StreamContext<'a> {
    fn new(
        backend: &'a LichessBackend,
        request: LiveGameRequest,
        events: LiveGameEventSink,
    ) -> Self {
        Self {
            backend,
            request,
            events,
            game: None,
            initial_fen: None,
        }
    }

    fn consume(&mut self, line: &[u8]) -> Result<(), LibChessError> {
        if line.is_empty() {
            return Ok(());
        }
        if line.len() > MAX_STREAM_LINE_BYTES {
            return Err(protocol_error("Lichess sent an oversized live-game event"));
        }
        let event_type = serde_json::from_slice::<EventType>(line)
            .map_err(|error| protocol_error(format!("invalid live-game JSON: {error}")))?;
        match event_type.kind.as_str() {
            "gameFull" => self.consume_full(
                serde_json::from_slice(line)
                    .map_err(|error| protocol_error(format!("invalid gameFull event: {error}")))?,
            ),
            "gameState" => self
                .consume_state(serde_json::from_slice(line).map_err(|error| {
                    protocol_error(format!("invalid gameState event: {error}"))
                })?),
            "chatLine" => self.consume_chat(
                serde_json::from_slice(line)
                    .map_err(|error| protocol_error(format!("invalid chatLine event: {error}")))?,
            ),
            "opponentGone" => {
                self.consume_presence(serde_json::from_slice(line).map_err(|error| {
                    protocol_error(format!("invalid opponentGone event: {error}"))
                })?)
            }
            _ => Ok(()),
        }
    }

    fn consume_full(&mut self, full: GameFull) -> Result<(), LibChessError> {
        if self.game.is_some() {
            return Err(protocol_error("Lichess sent gameFull more than once"));
        }
        validate_game_id(&full.id)?;
        if full.id != self.request.game_id.as_str() {
            return Err(protocol_error(
                "Lichess streamed a different game identifier",
            ));
        }
        let canonical_variant = canonical_variant_id(&full.variant.key)
            .ok_or_else(|| protocol_error("Lichess streamed an unsupported chess variant"))?;
        let variant_id =
            GameVariantId::new(canonical_variant).map_err(|error| protocol_error(error.message))?;
        let initial_fen = full.initial_fen;
        let state = build_state(canonical_variant, &initial_fen, full.state, None)?;
        let game = LiveGame {
            provider: self.backend.descriptor.id.clone(),
            id: self.request.game_id.clone(),
            url: self.backend.endpoint(self.request.game_id.as_str())?.into(),
            player_color: self.request.player_color,
            variant_id,
            variant_name: full.variant.name,
            rated: full.rated,
            speed: full.speed,
            clock: full.clock.map(|clock| LiveGameClock {
                initial_millis: clock.initial,
                increment_millis: clock.increment,
            }),
            days_per_turn: full.days_per_turn,
            white: map_player(full.white)?,
            black: map_player(full.black)?,
            state,
        };
        self.initial_fen = Some(initial_fen);
        (self.events)(LiveGameEvent::GameUpdated {
            game: Box::new(game.clone()),
        });
        self.game = Some(game);
        Ok(())
    }

    fn consume_state(&mut self, state: GameState) -> Result<(), LibChessError> {
        let game = self
            .game
            .as_mut()
            .ok_or_else(|| protocol_error("Lichess sent gameState before gameFull"))?;
        let initial_fen = self
            .initial_fen
            .as_deref()
            .ok_or_else(|| protocol_error("the live game has no initial position"))?;
        let presence = Some((game.state.opponent_gone, game.state.claim_win_in_seconds));
        game.state = build_state(game.variant_id.as_str(), initial_fen, state, presence)?;
        (self.events)(LiveGameEvent::GameUpdated {
            game: Box::new(game.clone()),
        });
        Ok(())
    }

    fn consume_chat(&self, chat: ChatLine) -> Result<(), LibChessError> {
        if chat.username.len() > 128 || chat.text.len() > 10_000 || chat.room.len() > 32 {
            return Err(protocol_error("Lichess sent an oversized chat message"));
        }
        (self.events)(LiveGameEvent::ChatMessage {
            message: LiveChatMessage {
                game_id: self.request.game_id.clone(),
                room: chat.room,
                username: chat.username,
                text: chat.text,
            },
        });
        Ok(())
    }

    fn consume_presence(&mut self, presence: OpponentGone) -> Result<(), LibChessError> {
        let game = self
            .game
            .as_mut()
            .ok_or_else(|| protocol_error("Lichess sent opponentGone before gameFull"))?;
        game.state.opponent_gone = presence.gone;
        game.state.claim_win_in_seconds = presence.claim_win_in_seconds;
        (self.events)(LiveGameEvent::GameUpdated {
            game: Box::new(game.clone()),
        });
        Ok(())
    }
}

fn build_state(
    variant_id: &str,
    initial_fen: &str,
    state: GameState,
    presence: Option<(bool, Option<u32>)>,
) -> Result<LiveGameState, LibChessError> {
    let moves = state
        .moves
        .split_ascii_whitespace()
        .map(str::to_owned)
        .collect::<Vec<_>>();
    let board = libchess_rules::reconstruct(variant_id, initial_fen, &moves)
        .map_err(|error| protocol_error(format!("invalid live-game position: {error}")))?;
    let status = GameStatus::new(state.status).map_err(|error| protocol_error(error.message))?;
    let (opponent_gone, claim_win_in_seconds) = presence.unwrap_or((false, None));
    Ok(LiveGameState {
        board,
        status,
        winner: state.winner,
        white_time_millis: state.white_time,
        black_time_millis: state.black_time,
        white_increment_millis: state.white_increment,
        black_increment_millis: state.black_increment,
        white_draw_offer: state.white_draw,
        black_draw_offer: state.black_draw,
        white_takeback_offer: state.white_takeback,
        black_takeback_offer: state.black_takeback,
        opponent_gone,
        claim_win_in_seconds,
    })
}

fn map_player(player: GamePlayer) -> Result<LiveGamePlayer, LibChessError> {
    if let Some(ai_level) = player.ai_level
        && !(1..=8).contains(&ai_level)
    {
        return Err(protocol_error("Lichess streamed an invalid AI level"));
    }
    let name = player
        .name
        .filter(|name| !name.trim().is_empty())
        .or_else(|| player.ai_level.map(|_| "Lichess AI".to_owned()))
        .or_else(|| player.id.clone())
        .ok_or_else(|| protocol_error("Lichess streamed a player without an identity"))?;
    if name.len() > 128 {
        return Err(protocol_error("Lichess streamed an oversized player name"));
    }

    Ok(LiveGamePlayer {
        id: player.id,
        name,
        title: player.title,
        rating: player.rating,
        provisional: player.provisional,
        ai_level: player.ai_level,
    })
}

fn protocol_error(message: impl Into<String>) -> LibChessError {
    LibChessError::new(ErrorKind::Provider, message, false)
}

#[derive(Deserialize)]
struct EventType {
    #[serde(rename = "type")]
    kind: String,
}

#[derive(Deserialize)]
struct GameFull {
    id: String,
    variant: StreamVariant,
    speed: String,
    rated: bool,
    #[serde(default)]
    clock: Option<GameClock>,
    #[serde(default, rename = "daysPerTurn")]
    days_per_turn: Option<u32>,
    white: GamePlayer,
    black: GamePlayer,
    #[serde(rename = "initialFen")]
    initial_fen: String,
    state: GameState,
}

#[derive(Deserialize)]
struct GameClock {
    initial: u64,
    increment: u64,
}

#[derive(Deserialize)]
struct StreamVariant {
    key: String,
    name: String,
}

#[derive(Deserialize)]
struct GamePlayer {
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    rating: Option<u32>,
    #[serde(default)]
    provisional: bool,
    #[serde(default, rename = "aiLevel")]
    ai_level: Option<u8>,
}

#[derive(Deserialize)]
struct GameState {
    #[serde(default)]
    moves: String,
    #[serde(default, rename = "wtime")]
    white_time: Option<u64>,
    #[serde(default, rename = "btime")]
    black_time: Option<u64>,
    #[serde(default, rename = "winc")]
    white_increment: Option<u64>,
    #[serde(default, rename = "binc")]
    black_increment: Option<u64>,
    status: String,
    #[serde(default)]
    winner: Option<PlayerColor>,
    #[serde(default, rename = "wdraw")]
    white_draw: bool,
    #[serde(default, rename = "bdraw")]
    black_draw: bool,
    #[serde(default, rename = "wtakeback")]
    white_takeback: bool,
    #[serde(default, rename = "btakeback")]
    black_takeback: bool,
}

#[derive(Deserialize)]
struct ChatLine {
    room: String,
    username: String,
    text: String,
}

#[derive(Deserialize)]
struct OpponentGone {
    gone: bool,
    #[serde(default, rename = "claimWinInSeconds")]
    claim_win_in_seconds: Option<u32>,
}

#[cfg(test)]
mod tests {
    use std::{
        io::{Read, Write},
        net::{TcpListener, TcpStream},
        sync::{Arc, Mutex, mpsc},
        thread,
    };

    use libchess_core::{
        AccessToken, LiveGameEvent, LiveGameRequest, MoveSubmission, PlatformBackendFactory,
    };

    use super::*;
    use crate::LichessFactory;

    fn serve_once(content_type: &str, body: String) -> (String, mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind mock server");
        let address = listener.local_addr().expect("mock address");
        let (sender, receiver) = mpsc::channel();
        let content_type = content_type.to_owned();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept request");
            sender
                .send(read_request(&mut stream))
                .expect("capture request");
            let headers = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            stream.write_all(headers.as_bytes()).expect("write headers");
            for chunk in body.as_bytes().chunks(37) {
                stream.write_all(chunk).expect("write response chunk");
            }
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
            if request.windows(4).any(|window| window == b"\r\n\r\n") {
                break;
            }
        }
        String::from_utf8(request).expect("UTF-8 request")
    }

    fn make_backend(base_url: &str) -> Arc<dyn libchess_core::PlatformBackend> {
        LichessFactory::new(base_url)
            .expect("factory")
            .create(AccessToken::new("lio_test_token").expect("token"))
            .expect("backend")
    }

    #[tokio::test]
    async fn streams_full_game_state_chat_and_presence() {
        let body = concat!(
            r#"{"type":"gameFull","id":"v8BRXYtM","variant":{"key":"standard","name":"Standard","short":"Std"},"speed":"rapid","perf":{"name":"Rapid"},"rated":false,"createdAt":1,"clock":{"initial":600000,"increment":0},"white":{"id":"test-user","name":"TestUser","rating":1500},"black":{"aiLevel":4},"initialFen":"startpos","state":{"type":"gameState","moves":"","wtime":600000,"btime":600000,"winc":0,"binc":0,"status":"started"}}"#,
            "\n",
            r#"{"type":"chatLine","room":"player","username":"lichess","text":"Good luck"}"#,
            "\n",
            r#"{"type":"opponentGone","gone":true,"claimWinInSeconds":12}"#,
            "\n",
            r#"{"type":"gameState","moves":"e2e4","wtime":598000,"btime":600000,"winc":0,"binc":0,"status":"resign","winner":"white"}"#,
            "\n"
        )
        .to_owned();
        let (base_url, captured_request) = serve_once("application/x-ndjson", body);
        let backend = make_backend(&base_url);
        let received = Arc::new(Mutex::new(Vec::<LiveGameEvent>::new()));
        let received_for_sink = Arc::clone(&received);
        let sink = Arc::new(move |event| {
            received_for_sink.lock().expect("events lock").push(event);
        });

        backend
            .watch_live_game(
                LiveGameRequest::new("v8BRXYtM", PlayerColor::White).expect("request"),
                sink,
            )
            .await
            .expect("completed stream");

        let request = captured_request.recv().expect("captured request");
        assert!(request.starts_with("GET /api/board/game/stream/v8BRXYtM HTTP/1.1"));
        assert!(request.contains("authorization: Bearer lio_test_token"));
        assert!(request.contains("accept: application/x-ndjson"));

        let events = received.lock().expect("events lock");
        assert_eq!(events.len(), 4);
        let LiveGameEvent::GameUpdated { game: initial } = &events[0] else {
            panic!("initial game event");
        };
        assert_eq!(initial.state.board.pieces.len(), 32);
        assert_eq!(initial.state.board.legal_moves.len(), 20);
        assert_eq!(initial.black.name, "Lichess AI");
        assert_eq!(initial.black.ai_level, Some(4));
        assert_eq!(
            initial.clock.map(|clock| clock.initial_millis),
            Some(600_000)
        );
        let LiveGameEvent::ChatMessage { message } = &events[1] else {
            panic!("chat event");
        };
        assert_eq!(message.text, "Good luck");
        let LiveGameEvent::GameUpdated { game: presence } = &events[2] else {
            panic!("presence event");
        };
        assert!(presence.state.opponent_gone);
        assert_eq!(presence.state.claim_win_in_seconds, Some(12));
        let LiveGameEvent::GameUpdated { game: finished } = &events[3] else {
            panic!("final game event");
        };
        assert_eq!(finished.state.status.as_str(), "resign");
        assert_eq!(finished.state.winner, Some(PlayerColor::White));
        assert!(
            finished
                .state
                .board
                .pieces
                .iter()
                .any(|piece| piece.square == "e4")
        );
    }

    #[tokio::test]
    async fn submits_moves_and_game_actions_to_board_endpoints() {
        let (base_url, captured_move) = serve_once("application/json", "{}".to_owned());
        let backend = make_backend(&base_url);
        backend
            .play_move(MoveSubmission::new("v8BRXYtM", "e2e4", true).expect("move submission"))
            .await
            .expect("move accepted");
        let request = captured_move.recv().expect("captured move");
        assert!(
            request
                .starts_with("POST /api/board/game/v8BRXYtM/move/e2e4?offeringDraw=true HTTP/1.1")
        );

        let (base_url, captured_action) = serve_once("application/json", "{}".to_owned());
        let backend = make_backend(&base_url);
        backend
            .perform_game_action(
                GameId::new("v8BRXYtM").expect("game id"),
                LiveGameAction::Resign,
            )
            .await
            .expect("resign accepted");
        let request = captured_action.recv().expect("captured action");
        assert!(request.starts_with("POST /api/board/game/v8BRXYtM/resign HTTP/1.1"));
    }
}
