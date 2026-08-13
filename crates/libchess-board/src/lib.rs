#![forbid(unsafe_code)]

use libchess_core::{
    BoardAnimationCurve, BoardAnimationRule, BoardAsset, BoardMetrics, BoardMotion, BoardPalette,
    BoardPresentation, BoardProvider, BoardProviderDescriptor, BoardProviderId, BoardStyle,
    BoardThemeDescriptor, BoardThemeId, BoardZoomPreset, BoardZoomPresetId, BoardZoomRules,
    LibChessError, PieceAssets, PieceMetrics, PiecePalette, PieceRole, PieceStyle,
    PieceThemeDescriptor, PieceThemeId, PlayerColor, RgbaColor,
};

const ROLES: [PieceRole; 6] = [
    PieceRole::Pawn,
    PieceRole::Knight,
    PieceRole::Bishop,
    PieceRole::Rook,
    PieceRole::Queen,
    PieceRole::King,
];

const SOLID_GLYPHS: [&str; 6] = ["♟", "♞", "♝", "♜", "♛", "♚"];
const OUTLINE_GLYPHS: [&str; 6] = ["♙", "♘", "♗", "♖", "♕", "♔"];
const NOTATION_GLYPHS: [&str; 6] = ["P", "N", "B", "R", "Q", "K"];
const CC0_SVG: [&str; 6] = [
    include_str!("../assets/cc0-silhouette/pawn.svg"),
    include_str!("../assets/cc0-silhouette/knight.svg"),
    include_str!("../assets/cc0-silhouette/bishop.svg"),
    include_str!("../assets/cc0-silhouette/rook.svg"),
    include_str!("../assets/cc0-silhouette/queen.svg"),
    include_str!("../assets/cc0-silhouette/king.svg"),
];

pub struct BuiltinBoardProvider {
    descriptor: BoardProviderDescriptor,
}

impl BuiltinBoardProvider {
    pub fn new() -> Result<Self, LibChessError> {
        let descriptor = BoardProviderDescriptor {
            id: BoardProviderId::new("libchess")?,
            display_name: "LibChess".to_owned(),
            board_themes: vec![
                board_theme("classic", "Classic")?,
                board_theme("slate", "Slate")?,
                board_theme("walnut", "Walnut")?,
                board_theme("ocean", "Ocean")?,
                board_theme("charcoal", "Charcoal")?,
                board_theme("rosewood", "Rosewood")?,
            ],
            piece_themes: vec![
                piece_theme("system-solid", "System Solid")?,
                piece_theme("system-outline", "System Outline")?,
                piece_theme("cc0-silhouette", "CC0 Silhouette")?,
                piece_theme("notation", "Notation")?,
            ],
            default_board_theme: BoardThemeId::new("classic")?,
            default_piece_theme: PieceThemeId::new("system-solid")?,
        };
        descriptor.validate()?;
        Ok(Self { descriptor })
    }
}

impl Default for BuiltinBoardProvider {
    fn default() -> Self {
        Self::new().expect("the built-in board provider is valid")
    }
}

impl BoardProvider for BuiltinBoardProvider {
    fn descriptor(&self) -> &BoardProviderDescriptor {
        &self.descriptor
    }

    fn presentation(
        &self,
        board_theme: &BoardThemeId,
        piece_theme: &PieceThemeId,
    ) -> Result<BoardPresentation, LibChessError> {
        let board = match board_theme.as_str() {
            "classic" => board_style("Classic", classic_palette()),
            "slate" => board_style("Slate", slate_palette()),
            "walnut" => board_style("Walnut", walnut_palette()),
            "ocean" => board_style("Ocean", ocean_palette()),
            "charcoal" => board_style("Charcoal", charcoal_palette()),
            "rosewood" => board_style("Rosewood", rosewood_palette()),
            _ => {
                return Err(LibChessError::unsupported(format!(
                    "board theme '{board_theme}' is not installed for provider '{}'",
                    self.descriptor.id
                )));
            }
        };
        let pieces = match piece_theme.as_str() {
            "system-solid" => system_solid_pieces(),
            "system-outline" => system_outline_pieces(),
            "cc0-silhouette" => cc0_silhouette_pieces(),
            "notation" => notation_pieces(),
            _ => {
                return Err(LibChessError::unsupported(format!(
                    "piece theme '{piece_theme}' is not installed for provider '{}'",
                    self.descriptor.id
                )));
            }
        };

        let presentation = BoardPresentation {
            provider: BoardProviderId::new("libchess")?,
            board_theme: board_theme.clone(),
            piece_theme: piece_theme.clone(),
            board,
            pieces,
            motion: default_motion(),
            zoom: default_zoom(),
        };
        presentation.validate()?;
        Ok(presentation)
    }
}

fn board_theme(id: &str, display_name: &str) -> Result<BoardThemeDescriptor, LibChessError> {
    Ok(BoardThemeDescriptor {
        id: BoardThemeId::new(id)?,
        display_name: display_name.to_owned(),
    })
}

fn piece_theme(id: &str, display_name: &str) -> Result<PieceThemeDescriptor, LibChessError> {
    Ok(PieceThemeDescriptor {
        id: PieceThemeId::new(id)?,
        display_name: display_name.to_owned(),
    })
}

fn board_style(display_name: &str, palette: BoardPalette) -> BoardStyle {
    BoardStyle {
        display_name: display_name.to_owned(),
        palette,
        metrics: BoardMetrics {
            maximum_extent: 900,
            corner_radius: 6,
            border_width: 1,
            shadow_radius: 10,
            shadow_offset_y: 5,
            coordinate_font_scale_percent: 11,
            coordinate_inset: 3,
            destination_dot_scale_percent: 21,
            destination_ring_inset_percent: 5,
            destination_ring_width_percent: 6,
            check_gradient_radius_percent: 53,
        },
    }
}

fn system_solid_pieces() -> PieceStyle {
    text_piece_style(
        "System Solid",
        SOLID_GLYPHS,
        SOLID_GLYPHS,
        standard_piece_palette(),
        PieceMetrics {
            scale_percent: 72,
            shadow_radius_tenths: 7,
            shadow_offset_y_tenths: 5,
            promoted_marker_scale_percent: 13,
            promoted_marker_inset: 3,
        },
    )
}

fn system_outline_pieces() -> PieceStyle {
    text_piece_style(
        "System Outline",
        OUTLINE_GLYPHS,
        SOLID_GLYPHS,
        standard_piece_palette(),
        PieceMetrics {
            scale_percent: 74,
            shadow_radius_tenths: 8,
            shadow_offset_y_tenths: 5,
            promoted_marker_scale_percent: 13,
            promoted_marker_inset: 3,
        },
    )
}

fn notation_pieces() -> PieceStyle {
    text_piece_style(
        "Notation",
        NOTATION_GLYPHS,
        NOTATION_GLYPHS,
        PiecePalette {
            white_piece: rgba(255, 255, 255, 255),
            black_piece: rgba(24, 24, 24, 255),
            white_piece_shadow: rgba(0, 0, 0, 166),
            black_piece_shadow: rgba(255, 255, 255, 92),
            promoted_marker: rgba(255, 204, 0, 255),
        },
        PieceMetrics {
            scale_percent: 55,
            shadow_radius_tenths: 6,
            shadow_offset_y_tenths: 4,
            promoted_marker_scale_percent: 13,
            promoted_marker_inset: 3,
        },
    )
}

fn text_piece_style(
    display_name: &str,
    white: [&str; 6],
    black: [&str; 6],
    palette: PiecePalette,
    metrics: PieceMetrics,
) -> PieceStyle {
    let pieces = [(PlayerColor::White, white), (PlayerColor::Black, black)]
        .into_iter()
        .flat_map(|(color, glyphs)| {
            ROLES
                .into_iter()
                .zip(glyphs)
                .map(move |(role, glyph)| libchess_core::BoardPieceAsset {
                    color,
                    role,
                    asset: BoardAsset::text_glyph(glyph),
                })
        })
        .collect();

    PieceStyle {
        display_name: display_name.to_owned(),
        assets: PieceAssets {
            pieces,
            promoted_marker: BoardAsset::text_glyph("★"),
        },
        palette,
        metrics,
    }
}

fn cc0_silhouette_pieces() -> PieceStyle {
    let pieces = [PlayerColor::White, PlayerColor::Black]
        .into_iter()
        .flat_map(|color| {
            ROLES
                .into_iter()
                .zip(CC0_SVG)
                .map(move |(role, svg)| libchess_core::BoardPieceAsset {
                    color,
                    role,
                    asset: BoardAsset::tintable_svg(svg),
                })
        })
        .collect();

    PieceStyle {
        display_name: "CC0 Silhouette".to_owned(),
        assets: PieceAssets {
            pieces,
            promoted_marker: BoardAsset::text_glyph("★"),
        },
        palette: PiecePalette {
            white_piece: rgba(252, 248, 238, 255),
            black_piece: rgba(22, 25, 29, 255),
            white_piece_shadow: rgba(0, 0, 0, 158),
            black_piece_shadow: rgba(255, 255, 255, 74),
            promoted_marker: rgba(255, 190, 74, 255),
        },
        metrics: PieceMetrics {
            scale_percent: 82,
            shadow_radius_tenths: 9,
            shadow_offset_y_tenths: 6,
            promoted_marker_scale_percent: 13,
            promoted_marker_inset: 3,
        },
    }
}

fn standard_piece_palette() -> PiecePalette {
    PiecePalette {
        white_piece: rgba(255, 255, 255, 255),
        black_piece: rgba(23, 23, 20, 255),
        white_piece_shadow: rgba(0, 0, 0, 148),
        black_piece_shadow: rgba(255, 255, 255, 82),
        promoted_marker: rgba(255, 204, 0, 255),
    }
}

fn default_motion() -> BoardMotion {
    BoardMotion {
        board_resize: BoardAnimationRule {
            duration_millis: 260,
            curve: BoardAnimationCurve::Spring,
            extra_bounce_percent: 0,
        },
        piece_move: BoardAnimationRule {
            duration_millis: 180,
            curve: BoardAnimationCurve::Spring,
            extra_bounce_percent: 0,
        },
        selection: BoardAnimationRule {
            duration_millis: 120,
            curve: BoardAnimationCurve::EaseOut,
            extra_bounce_percent: 0,
        },
        piece_appearance_scale_percent: 55,
        fade_piece_appearance: true,
        maximum_animated_ply_distance: 1,
    }
}

fn default_zoom() -> BoardZoomRules {
    BoardZoomRules {
        presets: [
            ("compact", "Compact", 55),
            ("small", "Small", 70),
            ("medium", "Medium", 85),
            ("large", "Large", 95),
            ("maximum", "Maximum", 100),
        ]
        .into_iter()
        .map(|(id, display_name, scale_percent)| BoardZoomPreset {
            id: BoardZoomPresetId::new(id).expect("built-in zoom identifiers are valid"),
            display_name: display_name.to_owned(),
            scale_percent,
        })
        .collect(),
        default_preset: BoardZoomPresetId::new("medium")
            .expect("the built-in default zoom identifier is valid"),
    }
}

const fn rgba(red: u8, green: u8, blue: u8, alpha: u8) -> RgbaColor {
    RgbaColor::new(red, green, blue, alpha)
}

fn palette(
    light: RgbaColor,
    dark: RgbaColor,
    last_move: RgbaColor,
    selection: RgbaColor,
    legal_move: RgbaColor,
) -> BoardPalette {
    BoardPalette {
        light_square: light,
        dark_square: dark,
        coordinate_on_light: dark,
        coordinate_on_dark: light,
        last_move,
        selection,
        legal_move,
        check_center: rgba(255, 59, 48, 199),
        check_edge: rgba(255, 59, 48, 20),
        border: rgba(0, 0, 0, 64),
        shadow: rgba(0, 0, 0, 46),
    }
}

fn classic_palette() -> BoardPalette {
    palette(
        rgba(212, 196, 166, 255),
        rgba(107, 133, 89, 255),
        rgba(255, 204, 0, 107),
        rgba(10, 132, 255, 122),
        rgba(0, 0, 0, 84),
    )
}

fn slate_palette() -> BoardPalette {
    palette(
        rgba(204, 213, 224, 255),
        rgba(78, 101, 128, 255),
        rgba(255, 190, 74, 112),
        rgba(100, 210, 255, 132),
        rgba(14, 23, 33, 92),
    )
}

fn walnut_palette() -> BoardPalette {
    palette(
        rgba(225, 196, 153, 255),
        rgba(139, 90, 43, 255),
        rgba(255, 213, 79, 112),
        rgba(64, 156, 255, 128),
        rgba(41, 25, 12, 88),
    )
}

fn ocean_palette() -> BoardPalette {
    palette(
        rgba(190, 218, 224, 255),
        rgba(45, 105, 130, 255),
        rgba(255, 214, 10, 112),
        rgba(90, 200, 250, 134),
        rgba(8, 42, 57, 92),
    )
}

fn charcoal_palette() -> BoardPalette {
    palette(
        rgba(169, 176, 184, 255),
        rgba(61, 70, 82, 255),
        rgba(255, 193, 7, 118),
        rgba(100, 181, 246, 132),
        rgba(8, 12, 17, 96),
    )
}

fn rosewood_palette() -> BoardPalette {
    palette(
        rgba(226, 199, 178, 255),
        rgba(132, 70, 79, 255),
        rgba(255, 204, 0, 110),
        rgba(191, 90, 242, 122),
        rgba(49, 17, 22, 88),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provides_independent_board_and_piece_catalogs() {
        let provider = BuiltinBoardProvider::default();
        let descriptor = provider.descriptor();

        assert_eq!(descriptor.board_themes.len(), 6);
        assert_eq!(descriptor.piece_themes.len(), 4);
        assert_eq!(descriptor.default_board_theme.as_str(), "classic");
        assert_eq!(descriptor.default_piece_theme.as_str(), "system-solid");

        for board in &descriptor.board_themes {
            for pieces in &descriptor.piece_themes {
                let presentation = provider
                    .presentation(&board.id, &pieces.id)
                    .expect("every advertised theme combination is complete");
                assert_eq!(presentation.pieces.assets.pieces.len(), 12);
                assert_eq!(presentation.zoom.presets.len(), 5);
            }
        }
    }

    #[test]
    fn embeds_the_verified_cc0_svg_theme() {
        let provider = BuiltinBoardProvider::default();
        let presentation = provider
            .presentation(
                &BoardThemeId::new("ocean").expect("board theme"),
                &PieceThemeId::new("cc0-silhouette").expect("piece theme"),
            )
            .expect("CC0 presentation");

        assert_eq!(presentation.board.display_name, "Ocean");
        assert_eq!(presentation.pieces.display_name, "CC0 Silhouette");
        assert!(presentation.pieces.assets.pieces.iter().all(|piece| {
            piece.asset.kind == libchess_core::BoardAssetKind::Svg
                && piece.asset.value.starts_with("<svg")
        }));
        assert!(
            serde_json::to_string(&presentation)
                .expect("wire JSON")
                .contains(r#""kind":"svg""#)
        );
    }

    #[test]
    fn rejects_unknown_board_or_piece_themes() {
        let provider = BuiltinBoardProvider::default();
        let missing_board = provider
            .presentation(
                &BoardThemeId::new("missing").expect("board theme"),
                &PieceThemeId::new("system-solid").expect("piece theme"),
            )
            .expect_err("unknown board theme");
        let missing_pieces = provider
            .presentation(
                &BoardThemeId::new("classic").expect("board theme"),
                &PieceThemeId::new("missing").expect("piece theme"),
            )
            .expect_err("unknown piece theme");

        assert_eq!(missing_board.kind, libchess_core::ErrorKind::Unsupported);
        assert_eq!(missing_pieces.kind, libchess_core::ErrorKind::Unsupported);
    }
}
