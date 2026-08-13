#![forbid(unsafe_code)]

use libchess_core::{BoardPiece, BoardState, LegalMove, PieceRole, PlayerColor, PocketPiece};
use shakmaty::{
    CastlingMode, Color, Move, Position, Role, Square,
    fen::Fen,
    uci::UciMove,
    variant::{Variant, VariantPosition},
};
use thiserror::Error;

#[derive(Clone, Debug, Error, Eq, PartialEq)]
pub enum RulesError {
    #[error("unsupported chess variant '{0}'")]
    UnsupportedVariant(String),
    #[error("invalid initial position: {0}")]
    InvalidInitialPosition(String),
    #[error("invalid move at ply {ply}: {move_id}")]
    InvalidMove { ply: usize, move_id: String },
}

pub fn reconstruct(
    variant_id: &str,
    initial_fen: &str,
    move_ids: &[String],
) -> Result<BoardState, RulesError> {
    let (variant, castling_mode) = variant_and_castling_mode(variant_id)?;
    let mut position = if initial_fen == "startpos" {
        VariantPosition::new(variant)
    } else {
        let fen = Fen::from_ascii(initial_fen.as_bytes())
            .map_err(|error| RulesError::InvalidInitialPosition(error.to_string()))?;
        VariantPosition::from_setup(variant, fen.into_setup(), castling_mode)
            .map_err(|error| RulesError::InvalidInitialPosition(error.to_string()))?
    };

    let mut last_move = None;
    for (ply, move_id) in move_ids.iter().enumerate() {
        let uci = move_id
            .parse::<UciMove>()
            .map_err(|_| RulesError::InvalidMove {
                ply,
                move_id: move_id.clone(),
            })?;
        let chess_move = uci
            .to_move(&position)
            .map_err(|_| RulesError::InvalidMove {
                ply,
                move_id: move_id.clone(),
            })?;
        last_move = Some(describe_move(&chess_move, move_id.clone()));
        position.play_unchecked(chess_move);
    }

    let pieces = position
        .board()
        .iter()
        .map(|(square, piece)| BoardPiece {
            square: square.to_string(),
            color: player_color(piece.color),
            role: piece_role(piece.role),
            promoted: position.promoted().contains(square),
        })
        .collect();

    let mut pockets = Vec::new();
    if let Some(by_color) = position.pockets() {
        for color in [Color::White, Color::Black] {
            for role in [
                Role::Pawn,
                Role::Knight,
                Role::Bishop,
                Role::Rook,
                Role::Queen,
            ] {
                let count = by_color[color][role];
                if count > 0 {
                    pockets.push(PocketPiece {
                        color: player_color(color),
                        role: piece_role(role),
                        count,
                    });
                }
            }
        }
    }

    let legal_moves = position
        .legal_moves()
        .into_iter()
        .map(|chess_move| {
            let move_id = chess_move.to_uci(position.castles().mode()).to_string();
            describe_move(&chess_move, move_id)
        })
        .collect();

    Ok(BoardState {
        pieces,
        pockets,
        turn: player_color(position.turn()),
        ply: u32::try_from(move_ids.len()).unwrap_or(u32::MAX),
        moves: move_ids.to_vec(),
        last_move,
        legal_moves,
        in_check: position.is_check(),
    })
}

fn variant_and_castling_mode(variant_id: &str) -> Result<(Variant, CastlingMode), RulesError> {
    let value = match variant_id {
        "standard" | "from-position" => (Variant::Chess, CastlingMode::Standard),
        "chess960" => (Variant::Chess, CastlingMode::Chess960),
        "crazyhouse" => (Variant::Crazyhouse, CastlingMode::Standard),
        "antichess" => (Variant::Antichess, CastlingMode::Standard),
        "atomic" => (Variant::Atomic, CastlingMode::Standard),
        "horde" => (Variant::Horde, CastlingMode::Standard),
        "king-of-the-hill" => (Variant::KingOfTheHill, CastlingMode::Standard),
        "racing-kings" => (Variant::RacingKings, CastlingMode::Standard),
        "three-check" => (Variant::ThreeCheck, CastlingMode::Standard),
        _ => return Err(RulesError::UnsupportedVariant(variant_id.to_owned())),
    };
    Ok(value)
}

fn describe_move(chess_move: &Move, id: String) -> LegalMove {
    match chess_move {
        Move::Normal {
            from,
            to,
            promotion,
            ..
        } => LegalMove {
            id,
            from: Some(from.to_string()),
            to: to.to_string(),
            promotion: promotion.map(piece_role),
            drop: None,
        },
        Move::EnPassant { from, to } => LegalMove {
            id,
            from: Some(from.to_string()),
            to: to.to_string(),
            promotion: None,
            drop: None,
        },
        Move::Castle { king, rook } => LegalMove {
            id,
            from: Some(king.to_string()),
            to: castle_destination(*king, *rook),
            promotion: None,
            drop: None,
        },
        Move::Put { role, to } => LegalMove {
            id,
            from: None,
            to: to.to_string(),
            promotion: None,
            drop: Some(piece_role(*role)),
        },
    }
}

fn castle_destination(king: Square, rook: Square) -> String {
    let king = king.to_string();
    let rook = rook.to_string();
    let destination_file = if rook.as_bytes()[0] > king.as_bytes()[0] {
        'g'
    } else {
        'c'
    };
    format!("{destination_file}{}", &king[1..])
}

fn player_color(color: Color) -> PlayerColor {
    match color {
        Color::White => PlayerColor::White,
        Color::Black => PlayerColor::Black,
    }
}

fn piece_role(role: Role) -> PieceRole {
    match role {
        Role::Pawn => PieceRole::Pawn,
        Role::Knight => PieceRole::Knight,
        Role::Bishop => PieceRole::Bishop,
        Role::Rook => PieceRole::Rook,
        Role::Queen => PieceRole::Queen,
        Role::King => PieceRole::King,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reconstructs_standard_positions_and_legal_moves() {
        let initial = reconstruct("standard", "startpos", &[]).expect("initial position");
        assert_eq!(initial.pieces.len(), 32);
        assert_eq!(initial.legal_moves.len(), 20);
        assert_eq!(initial.turn, PlayerColor::White);

        let moves = vec!["e2e4".to_owned(), "e7e5".to_owned()];
        let state = reconstruct("standard", "startpos", &moves).expect("played position");
        assert_eq!(state.turn, PlayerColor::White);
        assert_eq!(state.ply, 2);
        assert_eq!(
            state.last_move.as_ref().map(|item| item.id.as_str()),
            Some("e7e5")
        );
        assert!(state.pieces.iter().any(|piece| piece.square == "e5"));
    }

    #[test]
    fn supports_every_advertised_starting_variant() {
        for variant in [
            "standard",
            "chess960",
            "crazyhouse",
            "antichess",
            "atomic",
            "horde",
            "king-of-the-hill",
            "racing-kings",
            "three-check",
            "from-position",
        ] {
            let state = reconstruct(variant, "startpos", &[]).expect(variant);
            assert!(!state.pieces.is_empty(), "{variant}");
            assert!(!state.legal_moves.is_empty(), "{variant}");
        }
    }

    #[test]
    fn rejects_illegal_server_history() {
        let error =
            reconstruct("standard", "startpos", &["e2e5".to_owned()]).expect_err("illegal move");
        assert!(matches!(error, RulesError::InvalidMove { ply: 0, .. }));
    }

    #[test]
    fn exposes_crazyhouse_pockets_and_drop_moves() {
        let fen = "rnbqkbnr/1ppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[P] w KQkq - 0 1";
        let state = reconstruct("crazyhouse", fen, &[]).expect("crazyhouse pocket");

        assert!(state.pockets.iter().any(|piece| {
            piece.color == PlayerColor::White && piece.role == PieceRole::Pawn && piece.count == 1
        }));
        assert!(state.legal_moves.iter().any(|chess_move| {
            chess_move.drop == Some(PieceRole::Pawn) && chess_move.from.is_none()
        }));
    }

    #[test]
    fn describes_castling_and_every_promotion_choice_for_native_input() {
        let castling = reconstruct("standard", "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1", &[])
            .expect("castling position");
        assert!(castling.legal_moves.iter().any(|chess_move| {
            chess_move.id == "e1g1"
                && chess_move.from.as_deref() == Some("e1")
                && chess_move.to == "g1"
        }));

        let promotion = reconstruct("standard", "7k/4P3/8/8/8/8/8/K7 w - - 0 1", &[])
            .expect("promotion position");
        let promotions = promotion
            .legal_moves
            .iter()
            .filter(|chess_move| chess_move.from.as_deref() == Some("e7") && chess_move.to == "e8")
            .count();
        assert_eq!(promotions, 4);
    }
}
