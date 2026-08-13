use std::{collections::HashSet, fmt};

use serde::{Deserialize, Serialize};

use crate::{LibChessError, PieceRole, PlayerColor};

fn valid_stable_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
}

macro_rules! stable_id {
    ($name:ident, $description:literal) => {
        #[derive(Clone, Debug, Deserialize, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
        #[serde(transparent)]
        pub struct $name(String);

        impl $name {
            pub fn new(value: impl Into<String>) -> Result<Self, LibChessError> {
                let value = value.into();
                if valid_stable_id(&value) {
                    Ok(Self(value))
                } else {
                    Err(LibChessError::invalid_input(concat!(
                        $description,
                        " must contain only lowercase ASCII letters, digits, or '-'"
                    )))
                }
            }

            pub fn as_str(&self) -> &str {
                &self.0
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str(&self.0)
            }
        }
    };
}

stable_id!(BoardProviderId, "board provider identifiers");
stable_id!(BoardThemeId, "board theme identifiers");
stable_id!(BoardZoomPresetId, "board zoom preset identifiers");

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct BoardProviderDescriptor {
    pub id: BoardProviderId,
    pub display_name: String,
    pub themes: Vec<BoardThemeDescriptor>,
    pub default_theme: BoardThemeId,
}

impl BoardProviderDescriptor {
    pub fn validate(&self) -> Result<(), LibChessError> {
        validate_display_name(&self.display_name, "board provider")?;
        if self.themes.is_empty() || self.themes.len() > 64 {
            return Err(LibChessError::invalid_input(
                "board providers must advertise between 1 and 64 themes",
            ));
        }

        let mut ids = HashSet::new();
        for theme in &self.themes {
            validate_display_name(&theme.display_name, "board theme")?;
            if !ids.insert(theme.id.clone()) {
                return Err(LibChessError::invalid_input(
                    "board providers cannot advertise duplicate theme identifiers",
                ));
            }
        }
        if !ids.contains(&self.default_theme) {
            return Err(LibChessError::invalid_input(
                "the default board theme must be advertised by its provider",
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct BoardThemeDescriptor {
    pub id: BoardThemeId,
    pub display_name: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct BoardPresentation {
    pub provider: BoardProviderId,
    pub theme: BoardThemeId,
    pub display_name: String,
    pub assets: BoardAssets,
    pub palette: BoardPalette,
    pub metrics: BoardMetrics,
    pub motion: BoardMotion,
    pub zoom: BoardZoomRules,
}

impl BoardPresentation {
    pub fn validate(&self) -> Result<(), LibChessError> {
        validate_display_name(&self.display_name, "board presentation")?;
        self.assets.validate()?;
        self.metrics.validate()?;
        self.motion.validate()?;
        self.zoom.validate()?;
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct BoardAssets {
    pub pieces: Vec<BoardPieceAsset>,
    pub promoted_marker: BoardAsset,
}

impl BoardAssets {
    fn validate(&self) -> Result<(), LibChessError> {
        let expected = [
            PieceRole::Pawn,
            PieceRole::Knight,
            PieceRole::Bishop,
            PieceRole::Rook,
            PieceRole::Queen,
            PieceRole::King,
        ];
        if self.pieces.len() != expected.len() * 2 {
            return Err(LibChessError::invalid_input(
                "board presentations must provide one asset for every color and piece role",
            ));
        }

        let mut pieces = HashSet::new();
        for piece in &self.pieces {
            piece.asset.validate()?;
            if !pieces.insert((piece.color, piece.role)) {
                return Err(LibChessError::invalid_input(
                    "board presentations cannot provide duplicate color and piece-role assets",
                ));
            }
        }
        if [PlayerColor::White, PlayerColor::Black]
            .into_iter()
            .any(|color| {
                expected
                    .iter()
                    .any(|role| !pieces.contains(&(color, *role)))
            })
        {
            return Err(LibChessError::invalid_input(
                "board presentations must provide every color and piece role",
            ));
        }
        self.promoted_marker.validate()
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct BoardPieceAsset {
    pub color: PlayerColor,
    pub role: PieceRole,
    pub asset: BoardAsset,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct BoardAsset {
    pub kind: BoardAssetKind,
    pub value: String,
}

impl BoardAsset {
    pub fn text_glyph(value: impl Into<String>) -> Self {
        Self {
            kind: BoardAssetKind::TextGlyph,
            value: value.into(),
        }
    }

    fn validate(&self) -> Result<(), LibChessError> {
        if self.value.is_empty()
            || self.value.len() > 64
            || self.value.chars().any(char::is_control)
        {
            return Err(LibChessError::invalid_input(
                "board asset values must contain between 1 and 64 non-control bytes",
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BoardAssetKind {
    TextGlyph,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct RgbaColor {
    pub red: u8,
    pub green: u8,
    pub blue: u8,
    pub alpha: u8,
}

impl RgbaColor {
    pub const fn new(red: u8, green: u8, blue: u8, alpha: u8) -> Self {
        Self {
            red,
            green,
            blue,
            alpha,
        }
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct BoardPalette {
    pub light_square: RgbaColor,
    pub dark_square: RgbaColor,
    pub coordinate_on_light: RgbaColor,
    pub coordinate_on_dark: RgbaColor,
    pub last_move: RgbaColor,
    pub selection: RgbaColor,
    pub legal_move: RgbaColor,
    pub check_center: RgbaColor,
    pub check_edge: RgbaColor,
    pub border: RgbaColor,
    pub shadow: RgbaColor,
    pub white_piece: RgbaColor,
    pub black_piece: RgbaColor,
    pub white_piece_shadow: RgbaColor,
    pub black_piece_shadow: RgbaColor,
    pub promoted_marker: RgbaColor,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct BoardMetrics {
    pub maximum_extent: u16,
    pub corner_radius: u16,
    pub border_width: u16,
    pub shadow_radius: u16,
    pub shadow_offset_y: i16,
    pub piece_scale_percent: u8,
    pub piece_shadow_radius_tenths: u8,
    pub piece_shadow_offset_y_tenths: i8,
    pub promoted_marker_scale_percent: u8,
    pub promoted_marker_inset: u8,
    pub coordinate_font_scale_percent: u8,
    pub coordinate_inset: u8,
    pub destination_dot_scale_percent: u8,
    pub destination_ring_inset_percent: u8,
    pub destination_ring_width_percent: u8,
    pub check_gradient_radius_percent: u8,
}

impl BoardMetrics {
    fn validate(&self) -> Result<(), LibChessError> {
        if !(160..=2_000).contains(&self.maximum_extent)
            || self.corner_radius > 64
            || self.border_width > 16
            || self.shadow_radius > 64
            || !(-64..=64).contains(&self.shadow_offset_y)
            || self.piece_shadow_radius_tenths > 100
            || !(-100..=100).contains(&self.piece_shadow_offset_y_tenths)
        {
            return Err(LibChessError::invalid_input(
                "board extent, border, corner, or shadow metrics are outside safe bounds",
            ));
        }

        let percentages = [
            self.piece_scale_percent,
            self.promoted_marker_scale_percent,
            self.coordinate_font_scale_percent,
            self.destination_dot_scale_percent,
            self.destination_ring_inset_percent,
            self.destination_ring_width_percent,
            self.check_gradient_radius_percent,
        ];
        if percentages.iter().any(|value| !(1..=100).contains(value)) {
            return Err(LibChessError::invalid_input(
                "board percentage metrics must be between 1 and 100",
            ));
        }
        if self.promoted_marker_inset > 32 || self.coordinate_inset > 32 {
            return Err(LibChessError::invalid_input(
                "board asset insets must not exceed 32 logical pixels",
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct BoardMotion {
    pub board_resize: BoardAnimationRule,
    pub piece_move: BoardAnimationRule,
    pub selection: BoardAnimationRule,
    pub piece_appearance_scale_percent: u8,
    pub fade_piece_appearance: bool,
    pub maximum_animated_ply_distance: u8,
}

impl BoardMotion {
    fn validate(&self) -> Result<(), LibChessError> {
        self.board_resize.validate()?;
        self.piece_move.validate()?;
        self.selection.validate()?;
        if !(1..=100).contains(&self.piece_appearance_scale_percent)
            || !(1..=64).contains(&self.maximum_animated_ply_distance)
        {
            return Err(LibChessError::invalid_input(
                "board appearance scale or animated ply distance is outside safe bounds",
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct BoardAnimationRule {
    pub duration_millis: u16,
    pub curve: BoardAnimationCurve,
    pub extra_bounce_percent: u8,
}

impl BoardAnimationRule {
    fn validate(self) -> Result<(), LibChessError> {
        if self.duration_millis > 5_000
            || self.extra_bounce_percent > 100
            || (self.curve != BoardAnimationCurve::Spring && self.extra_bounce_percent != 0)
        {
            return Err(LibChessError::invalid_input(
                "board animation duration or curve-specific bounce is outside safe bounds",
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum BoardAnimationCurve {
    Linear,
    EaseOut,
    Spring,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct BoardZoomRules {
    pub presets: Vec<BoardZoomPreset>,
    pub default_preset: BoardZoomPresetId,
}

impl BoardZoomRules {
    fn validate(&self) -> Result<(), LibChessError> {
        if self.presets.is_empty() || self.presets.len() > 16 {
            return Err(LibChessError::invalid_input(
                "board presentations must advertise between 1 and 16 zoom presets",
            ));
        }

        let mut ids = HashSet::new();
        let mut previous_scale = 0;
        for preset in &self.presets {
            validate_display_name(&preset.display_name, "board zoom preset")?;
            if !ids.insert(preset.id.clone()) {
                return Err(LibChessError::invalid_input(
                    "board presentations cannot advertise duplicate zoom preset identifiers",
                ));
            }
            if !(10..=100).contains(&preset.scale_percent) || preset.scale_percent <= previous_scale
            {
                return Err(LibChessError::invalid_input(
                    "board zoom presets must have strictly increasing scales from 10 through 100",
                ));
            }
            previous_scale = preset.scale_percent;
        }
        if !ids.contains(&self.default_preset) {
            return Err(LibChessError::invalid_input(
                "the default board zoom preset must be advertised",
            ));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct BoardZoomPreset {
    pub id: BoardZoomPresetId,
    pub display_name: String,
    pub scale_percent: u8,
}

pub trait BoardProvider: Send + Sync {
    fn descriptor(&self) -> &BoardProviderDescriptor;

    fn presentation(&self, theme: &BoardThemeId) -> Result<BoardPresentation, LibChessError>;
}

fn validate_display_name(value: &str, subject: &str) -> Result<(), LibChessError> {
    if value.is_empty() || value.len() > 128 || value.chars().any(char::is_control) {
        return Err(LibChessError::invalid_input(format!(
            "{subject} display names must contain between 1 and 128 non-control bytes"
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_board_identifiers() {
        assert!(BoardProviderId::new("built-in").is_ok());
        assert!(BoardThemeId::new("midnight-blue").is_ok());
        assert!(BoardZoomPresetId::new("100% ").is_err());
    }
}
