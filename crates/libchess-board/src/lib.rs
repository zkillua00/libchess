#![forbid(unsafe_code)]

use libchess_core::{
    BoardAnimationCurve, BoardAnimationRule, BoardAsset, BoardAssets, BoardMetrics, BoardMotion,
    BoardPalette, BoardPieceAsset, BoardPresentation, BoardProvider, BoardProviderDescriptor,
    BoardProviderId, BoardThemeDescriptor, BoardThemeId, BoardZoomPreset, BoardZoomPresetId,
    BoardZoomRules, LibChessError, PieceRole, PlayerColor, RgbaColor,
};

pub struct BuiltinBoardProvider {
    descriptor: BoardProviderDescriptor,
}

impl BuiltinBoardProvider {
    pub fn new() -> Result<Self, LibChessError> {
        let descriptor = BoardProviderDescriptor {
            id: BoardProviderId::new("libchess")?,
            display_name: "LibChess".to_owned(),
            themes: vec![
                BoardThemeDescriptor {
                    id: BoardThemeId::new("classic")?,
                    display_name: "Classic".to_owned(),
                },
                BoardThemeDescriptor {
                    id: BoardThemeId::new("slate")?,
                    display_name: "Slate".to_owned(),
                },
            ],
            default_theme: BoardThemeId::new("classic")?,
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

    fn presentation(&self, theme: &BoardThemeId) -> Result<BoardPresentation, LibChessError> {
        let presentation = match theme.as_str() {
            "classic" => presentation(theme.clone(), "Classic", classic_palette()),
            "slate" => presentation(theme.clone(), "Slate", slate_palette()),
            _ => {
                return Err(LibChessError::unsupported(format!(
                    "board theme '{theme}' is not installed for provider '{}'",
                    self.descriptor.id
                )));
            }
        }?;
        presentation.validate()?;
        Ok(presentation)
    }
}

fn presentation(
    theme: BoardThemeId,
    display_name: &str,
    palette: BoardPalette,
) -> Result<BoardPresentation, LibChessError> {
    Ok(BoardPresentation {
        provider: BoardProviderId::new("libchess")?,
        theme,
        display_name: display_name.to_owned(),
        assets: BoardAssets {
            pieces: [PlayerColor::White, PlayerColor::Black]
                .into_iter()
                .flat_map(|color| {
                    [
                        (PieceRole::Pawn, "♟"),
                        (PieceRole::Knight, "♞"),
                        (PieceRole::Bishop, "♝"),
                        (PieceRole::Rook, "♜"),
                        (PieceRole::Queen, "♛"),
                        (PieceRole::King, "♚"),
                    ]
                    .into_iter()
                    .map(move |(role, glyph)| BoardPieceAsset {
                        color,
                        role,
                        asset: BoardAsset::text_glyph(glyph),
                    })
                })
                .collect(),
            promoted_marker: BoardAsset::text_glyph("★"),
        },
        palette,
        metrics: BoardMetrics {
            maximum_extent: 900,
            corner_radius: 6,
            border_width: 1,
            shadow_radius: 10,
            shadow_offset_y: 5,
            piece_scale_percent: 72,
            piece_shadow_radius_tenths: 7,
            piece_shadow_offset_y_tenths: 5,
            promoted_marker_scale_percent: 13,
            promoted_marker_inset: 3,
            coordinate_font_scale_percent: 11,
            coordinate_inset: 3,
            destination_dot_scale_percent: 21,
            destination_ring_inset_percent: 5,
            destination_ring_width_percent: 6,
            check_gradient_radius_percent: 53,
        },
        motion: BoardMotion {
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
        },
        zoom: BoardZoomRules {
            presets: vec![
                BoardZoomPreset {
                    id: BoardZoomPresetId::new("small")?,
                    display_name: "Small".to_owned(),
                    scale_percent: 70,
                },
                BoardZoomPreset {
                    id: BoardZoomPresetId::new("medium")?,
                    display_name: "Medium".to_owned(),
                    scale_percent: 85,
                },
                BoardZoomPreset {
                    id: BoardZoomPresetId::new("large")?,
                    display_name: "Large".to_owned(),
                    scale_percent: 100,
                },
            ],
            default_preset: BoardZoomPresetId::new("medium")?,
        },
    })
}

const fn rgba(red: u8, green: u8, blue: u8, alpha: u8) -> RgbaColor {
    RgbaColor::new(red, green, blue, alpha)
}

fn classic_palette() -> BoardPalette {
    BoardPalette {
        light_square: rgba(212, 196, 166, 255),
        dark_square: rgba(107, 133, 89, 255),
        coordinate_on_light: rgba(107, 133, 89, 255),
        coordinate_on_dark: rgba(212, 196, 166, 255),
        last_move: rgba(255, 204, 0, 107),
        selection: rgba(10, 132, 255, 122),
        legal_move: rgba(0, 0, 0, 84),
        check_center: rgba(255, 59, 48, 199),
        check_edge: rgba(255, 59, 48, 20),
        border: rgba(0, 0, 0, 64),
        shadow: rgba(0, 0, 0, 46),
        white_piece: rgba(255, 255, 255, 255),
        black_piece: rgba(23, 23, 20, 255),
        white_piece_shadow: rgba(0, 0, 0, 148),
        black_piece_shadow: rgba(255, 255, 255, 82),
        promoted_marker: rgba(255, 204, 0, 255),
    }
}

fn slate_palette() -> BoardPalette {
    BoardPalette {
        light_square: rgba(204, 213, 224, 255),
        dark_square: rgba(78, 101, 128, 255),
        coordinate_on_light: rgba(78, 101, 128, 255),
        coordinate_on_dark: rgba(204, 213, 224, 255),
        last_move: rgba(255, 190, 74, 112),
        selection: rgba(100, 210, 255, 132),
        legal_move: rgba(14, 23, 33, 92),
        check_center: rgba(255, 69, 58, 204),
        check_edge: rgba(255, 69, 58, 23),
        border: rgba(7, 17, 28, 82),
        shadow: rgba(0, 0, 0, 56),
        white_piece: rgba(250, 252, 255, 255),
        black_piece: rgba(18, 25, 34, 255),
        white_piece_shadow: rgba(3, 13, 24, 153),
        black_piece_shadow: rgba(226, 239, 255, 92),
        promoted_marker: rgba(255, 190, 74, 255),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provides_complete_portable_presentations() {
        let provider = BuiltinBoardProvider::default();
        let descriptor = provider.descriptor();

        assert_eq!(descriptor.themes.len(), 2);
        let classic = provider
            .presentation(&BoardThemeId::new("classic").expect("theme id"))
            .expect("classic presentation");
        let slate = provider
            .presentation(&BoardThemeId::new("slate").expect("theme id"))
            .expect("slate presentation");

        assert_eq!(classic.assets.pieces.len(), 12);
        assert_eq!(classic.zoom.presets.len(), 3);
        assert_ne!(classic.palette.light_square, slate.palette.light_square);
        assert!(
            serde_json::to_string(&classic)
                .expect("wire JSON")
                .contains("text_glyph")
        );
    }

    #[test]
    fn rejects_unknown_themes() {
        let provider = BuiltinBoardProvider::default();
        let error = provider
            .presentation(&BoardThemeId::new("missing").expect("theme id"))
            .expect_err("unknown theme");
        assert_eq!(error.kind, libchess_core::ErrorKind::Unsupported);
    }
}
