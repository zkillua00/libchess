use std::{fmt, sync::Arc};

use serde::{Deserialize, Serialize};

use crate::{GameVariantId, LibChessError, PlayerColor, ProviderId};

#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(transparent)]
pub struct GameId(String);

impl GameId {
    pub fn new(value: impl Into<String>) -> Result<Self, LibChessError> {
        let value = value.into();
        let valid = !value.is_empty()
            && value.len() <= 128
            && value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'));
        if valid {
            Ok(Self(value))
        } else {
            Err(LibChessError::invalid_input(
                "game identifiers must contain only ASCII letters, digits, '-' or '_'",
            ))
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for GameId {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.0)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct LiveGameRequest {
    pub game_id: GameId,
    pub player_color: PlayerColor,
}

impl LiveGameRequest {
    pub fn new(
        game_id: impl Into<String>,
        player_color: PlayerColor,
    ) -> Result<Self, LibChessError> {
        Ok(Self {
            game_id: GameId::new(game_id)?,
            player_color,
        })
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PieceRole {
    Pawn,
    Knight,
    Bishop,
    Rook,
    Queen,
    King,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct BoardPiece {
    pub square: String,
    pub color: PlayerColor,
    pub role: PieceRole,
    pub promoted: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct PocketPiece {
    pub color: PlayerColor,
    pub role: PieceRole,
    pub count: u8,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct LegalMove {
    /// Provider-ready move identifier. UCI is used by the built-in providers.
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
    pub to: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub promotion: Option<PieceRole>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub drop: Option<PieceRole>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct BoardState {
    pub pieces: Vec<BoardPiece>,
    #[serde(default)]
    pub pockets: Vec<PocketPiece>,
    pub turn: PlayerColor,
    pub ply: u32,
    #[serde(default)]
    pub moves: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_move: Option<LegalMove>,
    #[serde(default)]
    pub legal_moves: Vec<LegalMove>,
    pub in_check: bool,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct LiveGamePlayer {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rating: Option<u32>,
    pub provisional: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ai_level: Option<u8>,
}

#[derive(Clone, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(transparent)]
pub struct GameStatus(String);

impl GameStatus {
    pub fn new(value: impl Into<String>) -> Result<Self, LibChessError> {
        let value = value.into();
        let valid = !value.is_empty()
            && value.len() <= 64
            && value
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'));
        if valid {
            Ok(Self(value))
        } else {
            Err(LibChessError::invalid_input(
                "game statuses must be non-empty ASCII identifiers",
            ))
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn is_playable(&self) -> bool {
        matches!(self.0.as_str(), "created" | "started")
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct LiveGameState {
    pub board: BoardState,
    pub status: GameStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub winner: Option<PlayerColor>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub white_time_millis: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub black_time_millis: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub white_increment_millis: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub black_increment_millis: Option<u64>,
    pub white_draw_offer: bool,
    pub black_draw_offer: bool,
    pub white_takeback_offer: bool,
    pub black_takeback_offer: bool,
    pub opponent_gone: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub claim_win_in_seconds: Option<u32>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct LiveGameClock {
    pub initial_millis: u64,
    pub increment_millis: u64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct LiveGame {
    pub provider: ProviderId,
    pub id: GameId,
    pub url: String,
    pub player_color: PlayerColor,
    pub variant_id: GameVariantId,
    pub variant_name: String,
    pub rated: bool,
    pub speed: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub clock: Option<LiveGameClock>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub days_per_turn: Option<u32>,
    pub white: LiveGamePlayer,
    pub black: LiveGamePlayer,
    pub state: LiveGameState,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct LiveChatMessage {
    pub game_id: GameId,
    pub room: String,
    pub username: String,
    pub text: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum LiveGameEvent {
    GameUpdated { game: Box<LiveGame> },
    ChatMessage { message: LiveChatMessage },
}

pub type LiveGameEventSink = Arc<dyn Fn(LiveGameEvent) + Send + Sync + 'static>;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct MoveSubmission {
    pub game_id: GameId,
    pub move_id: String,
    pub offer_draw: bool,
}

impl MoveSubmission {
    pub fn new(
        game_id: impl Into<String>,
        move_id: impl Into<String>,
        offer_draw: bool,
    ) -> Result<Self, LibChessError> {
        let move_id = move_id.into();
        let valid = !move_id.is_empty()
            && move_id.len() <= 16
            && move_id
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'@');
        if !valid {
            return Err(LibChessError::invalid_input(
                "move identifiers must use compact ASCII move notation",
            ));
        }
        Ok(Self {
            game_id: GameId::new(game_id)?,
            move_id,
            offer_draw,
        })
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum LiveGameAction {
    Abort,
    Resign,
    OfferDraw,
    AcceptDraw,
    DeclineDraw,
    OfferTakeback,
    AcceptTakeback,
    DeclineTakeback,
    ClaimVictory,
    ClaimDraw,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_live_game_boundaries() {
        assert!(LiveGameRequest::new("v8BRXYtM", PlayerColor::White).is_ok());
        assert!(LiveGameRequest::new("../game", PlayerColor::Black).is_err());
        assert!(MoveSubmission::new("v8BRXYtM", "e2e4", false).is_ok());
        assert!(MoveSubmission::new("v8BRXYtM", "P@e4", false).is_ok());
        assert!(MoveSubmission::new("v8BRXYtM", "e2/e4", false).is_err());
    }

    #[test]
    fn preserves_future_provider_statuses() {
        let status = GameStatus::new("started").expect("status");
        assert!(status.is_playable());
        let future = GameStatus::new("providerSpecificEnd").expect("future status");
        assert!(!future.is_playable());
    }
}
