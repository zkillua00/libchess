use std::time::Duration;

use libchess_core::{
    ErrorKind, GameExport, GameHistoryEntry, GameHistoryPage, GameHistoryRequest, GameId,
    GameMoveEvaluation, GameMoveJudgment, GameMoveJudgmentKind, GameOpening, GameReview,
    GameReviewMove, GameStatus, GameVariantId, LibChessError, PlayerColor,
};
use reqwest::header;
use serde::Deserialize;

use super::{
    LichessBackend, canonical_variant_id, map_status, map_transport_error, validate_game_id,
};

const MAX_HISTORY_LINE_BYTES: usize = 256 * 1024;
const MAX_PGN_BYTES: usize = 8 * 1024 * 1024;
const MAX_REVIEW_BYTES: usize = 8 * 1024 * 1024;
const MAX_REVIEW_PLIES: usize = 2_048;

pub(super) async fn list(
    backend: &LichessBackend,
    request: GameHistoryRequest,
) -> Result<GameHistoryPage, LibChessError> {
    let mut url = backend.endpoint("api/games/user")?;
    url.path_segments_mut()
        .map_err(|_| protocol_error("could not construct the game-history endpoint"))?
        .push(&request.account_username);
    let requested_count = usize::from(request.limit) + 1;
    {
        let mut query = url.query_pairs_mut();
        query
            .append_pair("max", &requested_count.to_string())
            .append_pair("moves", "false")
            .append_pair("tags", "false")
            .append_pair("clocks", "false")
            .append_pair("evals", "false")
            .append_pair("opening", "false")
            .append_pair("finished", "true")
            .append_pair("ongoing", "false")
            .append_pair("sort", "dateDesc");
        if let Some(before_millis) = request.before_millis {
            query.append_pair("until", &before_millis.to_string());
        }
    }

    let mut response = backend
        .http
        .get(url)
        .header(header::ACCEPT, "application/x-ndjson")
        .bearer_auth(backend.token.expose())
        .timeout(Duration::from_secs(20))
        .send()
        .await
        .map_err(map_transport_error)?;
    let status = response.status();
    if !status.is_success() {
        return Err(map_status(status));
    }

    let mut games = Vec::with_capacity(requested_count);
    let mut buffer = Vec::new();
    'response: while let Some(chunk) = response.chunk().await.map_err(map_transport_error)? {
        buffer.extend_from_slice(&chunk);
        while let Some(newline) = buffer.iter().position(|byte| *byte == b'\n') {
            let mut line = buffer.drain(..=newline).collect::<Vec<_>>();
            line.pop();
            if line.last() == Some(&b'\r') {
                line.pop();
            }
            consume_line(backend, &request, &line, &mut games)?;
            if games.len() == requested_count {
                break 'response;
            }
        }
        if buffer.len() > MAX_HISTORY_LINE_BYTES {
            return Err(protocol_error(
                "Lichess sent an oversized game-history record",
            ));
        }
    }
    if games.len() < requested_count && !buffer.is_empty() {
        consume_line(backend, &request, &buffer, &mut games)?;
    }

    let has_more = games.len() > usize::from(request.limit);
    games.truncate(usize::from(request.limit));
    let next_before_millis = if has_more {
        games
            .last()
            .and_then(|game| game.created_at_millis.checked_sub(1))
    } else {
        None
    };

    Ok(GameHistoryPage {
        games,
        next_before_millis,
    })
}

pub(super) async fn export(
    backend: &LichessBackend,
    game_id: GameId,
) -> Result<GameExport, LibChessError> {
    validate_game_id(game_id.as_str())?;
    let mut url = backend.endpoint(&format!("game/export/{game_id}"))?;
    url.query_pairs_mut()
        .append_pair("clocks", "true")
        .append_pair("evals", "true")
        .append_pair("opening", "true")
        .append_pair("literate", "true");
    let mut response = backend
        .http
        .get(url)
        .header(header::ACCEPT, "application/x-chess-pgn")
        .bearer_auth(backend.token.expose())
        .timeout(Duration::from_secs(20))
        .send()
        .await
        .map_err(map_transport_error)?;
    let status = response.status();
    if !status.is_success() {
        return Err(map_status(status));
    }
    if response
        .content_length()
        .is_some_and(|length| length > MAX_PGN_BYTES as u64)
    {
        return Err(protocol_error("Lichess returned an oversized PGN export"));
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(map_transport_error)? {
        if bytes.len().saturating_add(chunk.len()) > MAX_PGN_BYTES {
            return Err(protocol_error("Lichess returned an oversized PGN export"));
        }
        bytes.extend_from_slice(&chunk);
    }
    if bytes.is_empty() {
        return Err(protocol_error(
            "Lichess returned an invalid PGN export size",
        ));
    }
    let pgn = String::from_utf8(bytes)
        .map_err(|_| protocol_error("Lichess returned a non-UTF-8 PGN export"))?;
    if pgn.contains('\0') || !pgn.contains("[Event ") {
        return Err(protocol_error("Lichess returned invalid PGN content"));
    }

    Ok(GameExport {
        provider: backend.descriptor.id.clone(),
        suggested_filename: format!("lichess-{game_id}.pgn"),
        game_id,
        pgn,
    })
}

pub(super) async fn review(
    backend: &LichessBackend,
    game_id: GameId,
) -> Result<GameReview, LibChessError> {
    validate_game_id(game_id.as_str())?;
    let mut url = backend.endpoint(&format!("game/export/{game_id}"))?;
    url.query_pairs_mut()
        .append_pair("moves", "true")
        .append_pair("tags", "false")
        .append_pair("clocks", "true")
        .append_pair("evals", "true")
        .append_pair("accuracy", "true")
        .append_pair("opening", "true")
        .append_pair("division", "true");
    let mut response = backend
        .http
        .get(url)
        .header(header::ACCEPT, "application/json")
        .bearer_auth(backend.token.expose())
        .timeout(Duration::from_secs(20))
        .send()
        .await
        .map_err(map_transport_error)?;
    let status = response.status();
    if !status.is_success() {
        return Err(map_status(status));
    }
    if response
        .content_length()
        .is_some_and(|length| length > MAX_REVIEW_BYTES as u64)
    {
        return Err(protocol_error("an oversized game review"));
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(map_transport_error)? {
        if bytes.len().saturating_add(chunk.len()) > MAX_REVIEW_BYTES {
            return Err(protocol_error("an oversized game review"));
        }
        bytes.extend_from_slice(&chunk);
    }
    let response = serde_json::from_slice::<LichessReviewGame>(&bytes)
        .map_err(|error| protocol_error(format!("an invalid game review: {error}")))?;
    map_review(backend, game_id, response)
}

fn map_review(
    backend: &LichessBackend,
    game_id: GameId,
    review: LichessReviewGame,
) -> Result<GameReview, LibChessError> {
    if review.id != game_id.as_str() {
        return Err(protocol_error("a review for the wrong game"));
    }
    let variant_id = canonical_variant_id(&review.variant)
        .ok_or_else(|| protocol_error("a review for an unsupported chess variant"))?;
    let initial_fen = review.initial_fen.unwrap_or_else(|| "startpos".to_owned());
    if initial_fen.is_empty()
        || initial_fen.len() > 4_096
        || !initial_fen
            .chars()
            .all(|character| character.is_ascii_graphic() || character == ' ')
    {
        return Err(protocol_error("an invalid review starting position"));
    }
    let sans = review
        .moves
        .split_ascii_whitespace()
        .map(str::to_owned)
        .collect::<Vec<_>>();
    if sans.len() > MAX_REVIEW_PLIES || sans.iter().any(|san| san.len() > 32) {
        return Err(protocol_error("an invalid review move list"));
    }
    if review.clocks.len() > sans.len() || review.analysis.len() > sans.len() {
        return Err(protocol_error("misaligned review annotations"));
    }
    let move_ids = libchess_rules::normalize_san_moves(variant_id, &initial_fen, &sans)
        .map_err(|error| protocol_error(format!("an invalid review move list: {error}")))?;
    let moves = sans
        .into_iter()
        .zip(move_ids)
        .enumerate()
        .map(|(index, (san, move_id))| {
            let ply = u32::try_from(index + 1)
                .map_err(|_| protocol_error("an invalid review ply count"))?;
            let clock_millis = review
                .clocks
                .get(index)
                .map(|centiseconds| {
                    centiseconds
                        .checked_mul(10)
                        .ok_or_else(|| protocol_error("an invalid review clock value"))
                })
                .transpose()?;
            let evaluation = review
                .analysis
                .get(index)
                .cloned()
                .flatten()
                .map(map_evaluation)
                .transpose()?;
            Ok(GameReviewMove {
                ply,
                san,
                move_id,
                clock_millis,
                evaluation,
            })
        })
        .collect::<Result<Vec<_>, LibChessError>>()?;
    let opening = review.opening.map(map_opening).transpose()?;

    Ok(GameReview {
        provider: backend.descriptor.id.clone(),
        game_id,
        variant_id: GameVariantId::new(variant_id)?,
        initial_fen,
        opening,
        moves,
    })
}

fn map_opening(opening: LichessOpening) -> Result<GameOpening, LibChessError> {
    if opening.eco.is_empty()
        || opening.eco.len() > 16
        || opening.name.trim().is_empty()
        || opening.name.len() > 256
        || opening.name.chars().any(char::is_control)
    {
        return Err(protocol_error("invalid review opening metadata"));
    }
    Ok(GameOpening {
        eco: opening.eco,
        name: opening.name,
        ply: opening.ply,
    })
}

fn map_evaluation(evaluation: LichessMoveAnalysis) -> Result<GameMoveEvaluation, LibChessError> {
    if evaluation.eval.is_some() == evaluation.mate.is_some() {
        return Err(protocol_error(
            "a review evaluation without exactly one score",
        ));
    }
    let best_move = evaluation
        .best
        .map(|best| {
            let valid = (4..=16).contains(&best.len())
                && best
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'@');
            valid
                .then_some(best)
                .ok_or_else(|| protocol_error("an invalid review best move"))
        })
        .transpose()?;
    let variation = evaluation
        .variation
        .map(|variation| {
            let variation = variation.trim().to_owned();
            let valid = !variation.is_empty()
                && variation.len() <= 4_096
                && !variation.chars().any(char::is_control);
            valid
                .then_some(variation)
                .ok_or_else(|| protocol_error("an invalid review variation"))
        })
        .transpose()?;
    let judgment = evaluation
        .judgment
        .map(|judgment| {
            let kind = match judgment.name.as_str() {
                "Inaccuracy" => GameMoveJudgmentKind::Inaccuracy,
                "Mistake" => GameMoveJudgmentKind::Mistake,
                "Blunder" => GameMoveJudgmentKind::Blunder,
                _ => return Err(protocol_error("an unknown review judgment")),
            };
            let comment = judgment.comment.trim().to_owned();
            if comment.is_empty() || comment.len() > 2_048 || comment.chars().any(char::is_control)
            {
                return Err(protocol_error("an invalid review judgment"));
            }
            Ok(GameMoveJudgment { kind, comment })
        })
        .transpose()?;
    Ok(GameMoveEvaluation {
        centipawns: evaluation.eval,
        mate: evaluation.mate,
        best_move,
        variation,
        judgment,
    })
}

fn consume_line(
    backend: &LichessBackend,
    request: &GameHistoryRequest,
    line: &[u8],
    games: &mut Vec<GameHistoryEntry>,
) -> Result<(), LibChessError> {
    if line.is_empty() {
        return Ok(());
    }
    if line.len() > MAX_HISTORY_LINE_BYTES {
        return Err(protocol_error(
            "Lichess sent an oversized game-history record",
        ));
    }
    let game = serde_json::from_slice::<LichessHistoryGame>(line)
        .map_err(|error| protocol_error(format!("invalid game-history record: {error}")))?;
    games.push(map_game(backend, request, game)?);
    Ok(())
}

fn map_game(
    backend: &LichessBackend,
    request: &GameHistoryRequest,
    game: LichessHistoryGame,
) -> Result<GameHistoryEntry, LibChessError> {
    validate_game_id(&game.id)?;
    if game.speed.is_empty() || game.speed.len() > 64 || game.speed.chars().any(char::is_control) {
        return Err(protocol_error("Lichess returned an invalid game speed"));
    }
    let canonical_variant = canonical_variant_id(&game.variant)
        .ok_or_else(|| protocol_error("Lichess returned an unsupported chess variant"))?;
    let variant = backend
        .descriptor
        .bot_game_options
        .as_ref()
        .and_then(|options| {
            options
                .variants
                .iter()
                .find(|variant| variant.id.as_str() == canonical_variant)
        })
        .ok_or_else(|| protocol_error("Lichess returned a variant outside its catalog"))?;

    let (player_color, opponent) = if player_matches(&game.players.white, &request.account_id) {
        (PlayerColor::White, game.players.black)
    } else if player_matches(&game.players.black, &request.account_id) {
        (PlayerColor::Black, game.players.white)
    } else {
        return Err(protocol_error(
            "Lichess returned a history game that does not contain the connected account",
        ));
    };
    if opponent
        .ai_level
        .is_some_and(|level| !(1..=8).contains(&level))
    {
        return Err(protocol_error("Lichess returned an invalid AI level"));
    }
    let opponent_name = opponent
        .user
        .as_ref()
        .map(|user| user.name.trim().to_owned())
        .filter(|name| !name.is_empty())
        .or_else(|| {
            opponent
                .ai_level
                .map(|level| format!("Stockfish level {level}"))
        })
        .unwrap_or_else(|| "Anonymous".to_owned());
    if opponent_name.len() > 128 || opponent_name.chars().any(char::is_control) {
        return Err(protocol_error("Lichess returned an invalid opponent name"));
    }
    let opponent_title = opponent.user.as_ref().and_then(|user| user.title.clone());
    if opponent_title.as_ref().is_some_and(|title| {
        title.is_empty() || title.len() > 32 || title.chars().any(char::is_control)
    }) {
        return Err(protocol_error("Lichess returned an invalid opponent title"));
    }
    if game.last_move_at < game.created_at {
        return Err(protocol_error("Lichess returned invalid game timestamps"));
    }
    let status = GameStatus::new(game.status)
        .map_err(|_| protocol_error("Lichess returned an invalid game status"))?;
    let game_id = GameId::new(game.id.clone())?;
    let url = backend.endpoint(&game.id)?.to_string();
    let color_path = match player_color {
        PlayerColor::White => "white",
        PlayerColor::Black => "black",
    };
    let analysis_url = backend
        .endpoint(&format!("{}/{color_path}/analysis", game.id))?
        .to_string();

    Ok(GameHistoryEntry {
        provider: backend.descriptor.id.clone(),
        id: game_id,
        url,
        analysis_url,
        player_color,
        opponent_name,
        opponent_title,
        opponent_rating: opponent.rating,
        opponent_ai_level: opponent.ai_level,
        variant_id: GameVariantId::new(canonical_variant)?,
        variant_name: variant.display_name.clone(),
        rated: game.rated,
        speed: game.speed,
        status,
        winner: game.winner,
        created_at_millis: game.created_at,
        last_move_at_millis: game.last_move_at,
    })
}

fn player_matches(player: &LichessHistoryPlayer, account_id: &str) -> bool {
    player
        .user
        .as_ref()
        .is_some_and(|user| user.id.eq_ignore_ascii_case(account_id))
}

fn protocol_error(message: impl Into<String>) -> LibChessError {
    LibChessError::new(
        ErrorKind::Provider,
        format!("Lichess returned {message}", message = message.into()),
        false,
    )
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LichessHistoryGame {
    id: String,
    rated: bool,
    variant: String,
    speed: String,
    created_at: u64,
    last_move_at: u64,
    status: String,
    players: LichessHistoryPlayers,
    winner: Option<PlayerColor>,
}

#[derive(Deserialize)]
struct LichessHistoryPlayers {
    white: LichessHistoryPlayer,
    black: LichessHistoryPlayer,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LichessHistoryPlayer {
    user: Option<LichessHistoryUser>,
    rating: Option<u32>,
    ai_level: Option<u8>,
}

#[derive(Deserialize)]
struct LichessHistoryUser {
    id: String,
    name: String,
    title: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LichessReviewGame {
    id: String,
    variant: String,
    #[serde(default)]
    initial_fen: Option<String>,
    #[serde(default)]
    moves: String,
    #[serde(default)]
    clocks: Vec<u64>,
    #[serde(default)]
    analysis: Vec<Option<LichessMoveAnalysis>>,
    opening: Option<LichessOpening>,
}

#[derive(Clone, Deserialize)]
struct LichessMoveAnalysis {
    eval: Option<i32>,
    mate: Option<i32>,
    best: Option<String>,
    variation: Option<String>,
    judgment: Option<LichessJudgment>,
}

#[derive(Clone, Deserialize)]
struct LichessJudgment {
    name: String,
    comment: String,
}

#[derive(Deserialize)]
struct LichessOpening {
    eco: String,
    name: String,
    ply: u32,
}

#[cfg(test)]
mod tests {
    use std::{
        io::{Read, Write},
        net::{TcpListener, TcpStream},
        sync::{Arc, mpsc},
        thread,
    };

    use libchess_core::{
        AccessToken, GameHistoryRequest, GameId, PlatformBackend, PlatformBackendFactory,
        PlayerColor,
    };

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
            for chunk in body.as_bytes().chunks(41) {
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

    fn make_backend(base_url: &str) -> Arc<dyn PlatformBackend> {
        LichessFactory::new(base_url)
            .expect("factory")
            .create(AccessToken::new("lio_test_token").expect("token"))
            .expect("backend")
    }

    #[tokio::test]
    async fn lists_newest_finished_games_with_an_exact_cursor_and_analysis_url() {
        let body = [
            r#"{"id":"AbCd1234","rated":false,"variant":"standard","speed":"rapid","createdAt":3000,"lastMoveAt":3900,"status":"mate","players":{"white":{"user":{"id":"test-user","name":"TestUser"},"rating":1600},"black":{"aiLevel":4,"rating":1800}},"winner":"white"}"#,
            r#"{"id":"EfGh5678","rated":true,"variant":"threeCheck","speed":"blitz","createdAt":2000,"lastMoveAt":2900,"status":"resign","players":{"white":{"user":{"id":"opponent","name":"Opponent","title":"GM"},"rating":2100},"black":{"user":{"id":"test-user","name":"TestUser"},"rating":1605}},"winner":"white"}"#,
            r#"{"id":"IjKl9012","rated":false,"variant":"atomic","speed":"rapid","createdAt":1000,"lastMoveAt":1900,"status":"draw","players":{"white":{"user":{"id":"test-user","name":"TestUser"}},"black":{"user":{"id":"other","name":"Other"}}}}"#,
        ]
        .join("\n");
        let (base_url, captured_request) = serve_once("application/x-ndjson", body);
        let backend = make_backend(&base_url);
        let request = GameHistoryRequest::new("test-user", "TestUser", 2, Some(4_000))
            .expect("history request");

        let page = backend.game_history(request).await.expect("history page");

        let request = captured_request.recv().expect("captured request");
        assert!(request.starts_with("GET /api/games/user/TestUser?"));
        assert!(request.contains("max=3"));
        assert!(request.contains("until=4000"));
        assert!(request.contains("finished=true"));
        assert!(request.contains("ongoing=false"));
        assert!(request.contains("accept: application/x-ndjson"));
        assert!(request.contains("authorization: Bearer lio_test_token"));
        assert_eq!(page.games.len(), 2);
        assert_eq!(page.next_before_millis, Some(1_999));
        assert_eq!(page.games[0].opponent_name, "Stockfish level 4");
        assert_eq!(page.games[0].opponent_ai_level, Some(4));
        assert_eq!(page.games[0].player_color, PlayerColor::White);
        assert_eq!(
            page.games[0].analysis_url,
            format!("{base_url}AbCd1234/white/analysis")
        );
        assert_eq!(page.games[1].opponent_title.as_deref(), Some("GM"));
        assert_eq!(page.games[1].variant_id.as_str(), "three-check");
        assert_eq!(page.games[1].player_color, PlayerColor::Black);
    }

    #[tokio::test]
    async fn exports_annotated_pgn_without_exposing_the_credential() {
        let body = concat!(
            "[Event \"Casual rapid game\"]\n",
            "[Site \"https://lichess.org/AbCd1234\"]\n\n",
            "1. e4 { [%clk 0:10:00] } e5 *\n"
        )
        .to_owned();
        let (base_url, captured_request) = serve_once("application/x-chess-pgn", body.clone());
        let backend = make_backend(&base_url);

        let export = backend
            .export_game(GameId::new("AbCd1234").expect("game ID"))
            .await
            .expect("PGN export");

        let request = captured_request.recv().expect("captured request");
        assert!(request.starts_with("GET /game/export/AbCd1234?"));
        assert!(request.contains("clocks=true"));
        assert!(request.contains("evals=true"));
        assert!(request.contains("opening=true"));
        assert!(request.contains("literate=true"));
        assert!(request.contains("accept: application/x-chess-pgn"));
        assert_eq!(export.suggested_filename, "lichess-AbCd1234.pgn");
        assert_eq!(export.pgn, body);
        assert!(!export.pgn.contains("lio_test_token"));
    }

    #[tokio::test]
    async fn returns_normalized_native_review_data() {
        let body = r#"{"id":"AbCd1234","variant":"standard","moves":"e4 e5 Nf3","clocks":[60000,59900,59800],"opening":{"eco":"C20","name":"King's Pawn Game","ply":2},"analysis":[{"eval":18},{"eval":24},{"eval":-72,"best":"g1f3","variation":"Nf3 Nc6","judgment":{"name":"Inaccuracy","comment":"Inaccuracy. Nf3 was best."}}]}"#.to_owned();
        let (base_url, captured_request) = serve_once("application/json", body);
        let backend = make_backend(&base_url);

        let review = backend
            .review_game(GameId::new("AbCd1234").expect("game ID"))
            .await
            .expect("game review");

        let request = captured_request.recv().expect("captured request");
        assert!(request.starts_with("GET /game/export/AbCd1234?"));
        assert!(request.contains("moves=true"));
        assert!(request.contains("evals=true"));
        assert!(request.contains("accuracy=true"));
        assert!(request.contains("accept: application/json"));
        assert_eq!(review.initial_fen, "startpos");
        assert_eq!(review.moves.len(), 3);
        assert_eq!(review.moves[0].move_id, "e2e4");
        assert_eq!(review.moves[1].move_id, "e7e5");
        assert_eq!(review.moves[2].move_id, "g1f3");
        assert_eq!(review.moves[0].clock_millis, Some(600_000));
        assert_eq!(
            review.moves[2]
                .evaluation
                .as_ref()
                .and_then(|evaluation| evaluation.judgment.as_ref())
                .map(|judgment| judgment.kind),
            Some(libchess_core::GameMoveJudgmentKind::Inaccuracy)
        );
        assert_eq!(
            review.opening.as_ref().map(|opening| opening.name.as_str()),
            Some("King's Pawn Game")
        );
    }
}
