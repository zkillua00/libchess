import Foundation

public struct BoardProviderDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let themes: [BoardThemeDescriptor]
    public let defaultTheme: String

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case themes
        case defaultTheme = "default_theme"
    }
}

public struct BoardThemeDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

public struct BoardPresentation: Codable, Equatable, Identifiable, Sendable {
    public let provider: String
    public let theme: String
    public let displayName: String
    public let assets: BoardAssets
    public let palette: BoardPalette
    public let metrics: BoardMetrics
    public let motion: BoardMotion
    public let zoom: BoardZoomRules

    public var id: String { "\(provider)/\(theme)" }

    public func pieceAsset(for role: PieceRole, color: PlayerColor) -> BoardAsset? {
        assets.pieces.first(where: { $0.role == role && $0.color == color })?.asset
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case theme
        case displayName = "display_name"
        case assets
        case palette
        case metrics
        case motion
        case zoom
    }
}

public struct BoardAssets: Codable, Equatable, Sendable {
    public let pieces: [BoardPieceAsset]
    public let promotedMarker: BoardAsset

    private enum CodingKeys: String, CodingKey {
        case pieces
        case promotedMarker = "promoted_marker"
    }
}

public struct BoardPieceAsset: Codable, Equatable, Sendable {
    public let color: PlayerColor
    public let role: PieceRole
    public let asset: BoardAsset
}

public struct BoardAsset: Codable, Equatable, Sendable {
    public let kind: BoardAssetKind
    public let value: String
}

public enum BoardAssetKind: String, Codable, Equatable, Sendable {
    case textGlyph = "text_glyph"
}

public struct RgbaColor: Codable, Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8
}

public struct BoardPalette: Codable, Equatable, Sendable {
    public let lightSquare: RgbaColor
    public let darkSquare: RgbaColor
    public let coordinateOnLight: RgbaColor
    public let coordinateOnDark: RgbaColor
    public let lastMove: RgbaColor
    public let selection: RgbaColor
    public let legalMove: RgbaColor
    public let checkCenter: RgbaColor
    public let checkEdge: RgbaColor
    public let border: RgbaColor
    public let shadow: RgbaColor
    public let whitePiece: RgbaColor
    public let blackPiece: RgbaColor
    public let whitePieceShadow: RgbaColor
    public let blackPieceShadow: RgbaColor
    public let promotedMarker: RgbaColor

    private enum CodingKeys: String, CodingKey {
        case lightSquare = "light_square"
        case darkSquare = "dark_square"
        case coordinateOnLight = "coordinate_on_light"
        case coordinateOnDark = "coordinate_on_dark"
        case lastMove = "last_move"
        case selection
        case legalMove = "legal_move"
        case checkCenter = "check_center"
        case checkEdge = "check_edge"
        case border
        case shadow
        case whitePiece = "white_piece"
        case blackPiece = "black_piece"
        case whitePieceShadow = "white_piece_shadow"
        case blackPieceShadow = "black_piece_shadow"
        case promotedMarker = "promoted_marker"
    }
}

public struct BoardMetrics: Codable, Equatable, Sendable {
    public let maximumExtent: UInt16
    public let cornerRadius: UInt16
    public let borderWidth: UInt16
    public let shadowRadius: UInt16
    public let shadowOffsetY: Int16
    public let pieceScalePercent: UInt8
    public let pieceShadowRadiusTenths: UInt8
    public let pieceShadowOffsetYTenths: Int8
    public let promotedMarkerScalePercent: UInt8
    public let promotedMarkerInset: UInt8
    public let coordinateFontScalePercent: UInt8
    public let coordinateInset: UInt8
    public let destinationDotScalePercent: UInt8
    public let destinationRingInsetPercent: UInt8
    public let destinationRingWidthPercent: UInt8
    public let checkGradientRadiusPercent: UInt8

    private enum CodingKeys: String, CodingKey {
        case maximumExtent = "maximum_extent"
        case cornerRadius = "corner_radius"
        case borderWidth = "border_width"
        case shadowRadius = "shadow_radius"
        case shadowOffsetY = "shadow_offset_y"
        case pieceScalePercent = "piece_scale_percent"
        case pieceShadowRadiusTenths = "piece_shadow_radius_tenths"
        case pieceShadowOffsetYTenths = "piece_shadow_offset_y_tenths"
        case promotedMarkerScalePercent = "promoted_marker_scale_percent"
        case promotedMarkerInset = "promoted_marker_inset"
        case coordinateFontScalePercent = "coordinate_font_scale_percent"
        case coordinateInset = "coordinate_inset"
        case destinationDotScalePercent = "destination_dot_scale_percent"
        case destinationRingInsetPercent = "destination_ring_inset_percent"
        case destinationRingWidthPercent = "destination_ring_width_percent"
        case checkGradientRadiusPercent = "check_gradient_radius_percent"
    }
}

public struct BoardMotion: Codable, Equatable, Sendable {
    public let boardResize: BoardAnimationRule
    public let pieceMove: BoardAnimationRule
    public let selection: BoardAnimationRule
    public let pieceAppearanceScalePercent: UInt8
    public let fadePieceAppearance: Bool
    public let maximumAnimatedPlyDistance: UInt8

    private enum CodingKeys: String, CodingKey {
        case boardResize = "board_resize"
        case pieceMove = "piece_move"
        case selection
        case pieceAppearanceScalePercent = "piece_appearance_scale_percent"
        case fadePieceAppearance = "fade_piece_appearance"
        case maximumAnimatedPlyDistance = "maximum_animated_ply_distance"
    }
}

public struct BoardAnimationRule: Codable, Equatable, Sendable {
    public let durationMillis: UInt16
    public let curve: BoardAnimationCurve
    public let extraBouncePercent: UInt8

    private enum CodingKeys: String, CodingKey {
        case durationMillis = "duration_millis"
        case curve
        case extraBouncePercent = "extra_bounce_percent"
    }
}

public enum BoardAnimationCurve: String, Codable, Equatable, Sendable {
    case linear
    case easeOut = "ease_out"
    case spring
}

public struct BoardZoomRules: Codable, Equatable, Sendable {
    public let presets: [BoardZoomPreset]
    public let defaultPreset: String

    public func preset(id: String) -> BoardZoomPreset? {
        presets.first(where: { $0.id == id })
    }

    public var defaultValue: BoardZoomPreset? {
        preset(id: defaultPreset)
    }

    public func adjacent(to preset: BoardZoomPreset, offset: Int) -> BoardZoomPreset {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else {
            return defaultValue ?? preset
        }
        let target = max(0, min(index + offset, presets.count - 1))
        return presets[target]
    }

    private enum CodingKeys: String, CodingKey {
        case presets
        case defaultPreset = "default_preset"
    }
}

public struct BoardZoomPreset: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let scalePercent: UInt8

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case scalePercent = "scale_percent"
    }
}

public enum BoardPreferenceKey {
    public static let zoomPreset = "org.libchess.macos.boardZoom"
    public static let provider = "org.libchess.macos.boardProvider"
    public static let theme = "org.libchess.macos.boardTheme"
}

public enum ChessBoardLayout {
    public static func extent(
        in container: CGSize,
        presentation: BoardPresentation,
        zoom: BoardZoomPreset,
        horizontalChrome: CGFloat = 56,
        verticalChrome: CGFloat
    ) -> CGFloat {
        let availableWidth = max(0, container.width - horizontalChrome)
        let availableHeight = max(0, container.height - verticalChrome)
        let fittedExtent = min(
            CGFloat(presentation.metrics.maximumExtent),
            availableWidth,
            availableHeight
        )
        return fittedExtent * CGFloat(zoom.scalePercent) / 100
    }
}
