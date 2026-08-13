import Foundation

public struct BoardProviderDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let boardThemes: [BoardThemeDescriptor]
    public let pieceThemes: [PieceThemeDescriptor]
    public let defaultBoardTheme: String
    public let defaultPieceTheme: String

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case boardThemes = "board_themes"
        case pieceThemes = "piece_themes"
        case defaultBoardTheme = "default_board_theme"
        case defaultPieceTheme = "default_piece_theme"
    }
}

public struct PieceThemeDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

public let BOARD_CUSTOMIZATION_STATE_VERSION: UInt32 = 1

public struct BoardCustomizationState: Codable, Equatable, Sendable {
    public let version: UInt32
    public let boardThemes: [CustomBoardTheme]
    public let pieceThemes: [CustomPieceTheme]

    public static let empty = BoardCustomizationState(
        version: BOARD_CUSTOMIZATION_STATE_VERSION,
        boardThemes: [],
        pieceThemes: []
    )

    private enum CodingKeys: String, CodingKey {
        case version
        case boardThemes = "board_themes"
        case pieceThemes = "piece_themes"
    }
}

public struct CustomBoardTheme: Codable, Equatable, Identifiable, Sendable {
    public let provider: String
    public let id: String
    public let displayName: String
    public let baseTheme: String
    public let adjustment: ThemeColorAdjustment
    public let colors: BoardColorOverrides

    public init(
        provider: String,
        id: String,
        displayName: String,
        baseTheme: String,
        adjustment: ThemeColorAdjustment,
        colors: BoardColorOverrides
    ) {
        self.provider = provider
        self.id = id
        self.displayName = displayName
        self.baseTheme = baseTheme
        self.adjustment = adjustment
        self.colors = colors
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case id
        case displayName = "display_name"
        case baseTheme = "base_theme"
        case adjustment
        case colors
    }
}

public struct CustomPieceTheme: Codable, Equatable, Identifiable, Sendable {
    public let provider: String
    public let id: String
    public let displayName: String
    public let baseTheme: String
    public let adjustment: ThemeColorAdjustment
    public let colors: PieceColorOverrides
    public let assets: CustomPieceAssets?

    public init(
        provider: String,
        id: String,
        displayName: String,
        baseTheme: String,
        adjustment: ThemeColorAdjustment,
        colors: PieceColorOverrides,
        assets: CustomPieceAssets?
    ) {
        self.provider = provider
        self.id = id
        self.displayName = displayName
        self.baseTheme = baseTheme
        self.adjustment = adjustment
        self.colors = colors
        self.assets = assets
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case id
        case displayName = "display_name"
        case baseTheme = "base_theme"
        case adjustment
        case colors
        case assets
    }
}

public struct ThemeColorAdjustment: Codable, Equatable, Sendable {
    public let hueDegrees: Int16
    public let saturationPercent: Int8
    public let brightnessPercent: Int8

    public init(hueDegrees: Int16, saturationPercent: Int8, brightnessPercent: Int8) {
        self.hueDegrees = hueDegrees
        self.saturationPercent = saturationPercent
        self.brightnessPercent = brightnessPercent
    }

    public static let identity = ThemeColorAdjustment(
        hueDegrees: 0,
        saturationPercent: 0,
        brightnessPercent: 0
    )

    private enum CodingKeys: String, CodingKey {
        case hueDegrees = "hue_degrees"
        case saturationPercent = "saturation_percent"
        case brightnessPercent = "brightness_percent"
    }
}

public struct BoardColorOverrides: Codable, Equatable, Sendable {
    public let lightSquare: RgbaColor?
    public let darkSquare: RgbaColor?
    public let coordinateOnLight: RgbaColor?
    public let coordinateOnDark: RgbaColor?
    public let lastMove: RgbaColor?
    public let selection: RgbaColor?
    public let legalMove: RgbaColor?
    public let checkCenter: RgbaColor?
    public let checkEdge: RgbaColor?
    public let border: RgbaColor?
    public let shadow: RgbaColor?

    public init(
        lightSquare: RgbaColor? = nil,
        darkSquare: RgbaColor? = nil,
        coordinateOnLight: RgbaColor? = nil,
        coordinateOnDark: RgbaColor? = nil,
        lastMove: RgbaColor? = nil,
        selection: RgbaColor? = nil,
        legalMove: RgbaColor? = nil,
        checkCenter: RgbaColor? = nil,
        checkEdge: RgbaColor? = nil,
        border: RgbaColor? = nil,
        shadow: RgbaColor? = nil
    ) {
        self.lightSquare = lightSquare
        self.darkSquare = darkSquare
        self.coordinateOnLight = coordinateOnLight
        self.coordinateOnDark = coordinateOnDark
        self.lastMove = lastMove
        self.selection = selection
        self.legalMove = legalMove
        self.checkCenter = checkCenter
        self.checkEdge = checkEdge
        self.border = border
        self.shadow = shadow
    }

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
    }
}

public struct PieceColorOverrides: Codable, Equatable, Sendable {
    public let whitePiece: RgbaColor?
    public let blackPiece: RgbaColor?
    public let whitePieceShadow: RgbaColor?
    public let blackPieceShadow: RgbaColor?
    public let promotedMarker: RgbaColor?

    public init(
        whitePiece: RgbaColor? = nil,
        blackPiece: RgbaColor? = nil,
        whitePieceShadow: RgbaColor? = nil,
        blackPieceShadow: RgbaColor? = nil,
        promotedMarker: RgbaColor? = nil
    ) {
        self.whitePiece = whitePiece
        self.blackPiece = blackPiece
        self.whitePieceShadow = whitePieceShadow
        self.blackPieceShadow = blackPieceShadow
        self.promotedMarker = promotedMarker
    }

    private enum CodingKeys: String, CodingKey {
        case whitePiece = "white_piece"
        case blackPiece = "black_piece"
        case whitePieceShadow = "white_piece_shadow"
        case blackPieceShadow = "black_piece_shadow"
        case promotedMarker = "promoted_marker"
    }
}

public struct CustomPieceAssets: Codable, Equatable, Sendable {
    public let pieces: [CustomPieceAsset]
    public let promotedMarker: BoardAsset?

    public init(pieces: [CustomPieceAsset], promotedMarker: BoardAsset? = nil) {
        self.pieces = pieces
        self.promotedMarker = promotedMarker
    }

    private enum CodingKeys: String, CodingKey {
        case pieces
        case promotedMarker = "promoted_marker"
    }
}

public struct CustomPieceAsset: Codable, Equatable, Sendable {
    public let role: PieceRole
    public let asset: BoardAsset

    public init(role: PieceRole, asset: BoardAsset) {
        self.role = role
        self.asset = asset
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
    public let boardTheme: String
    public let pieceTheme: String
    public let board: BoardStyle
    public let pieces: PieceStyle
    public let motion: BoardMotion
    public let zoom: BoardZoomRules

    public var id: String { "\(provider)/\(boardTheme)/\(pieceTheme)" }

    public func pieceAsset(for role: PieceRole, color: PlayerColor) -> BoardAsset? {
        pieces.assets.pieces.first(where: { $0.role == role && $0.color == color })?.asset
    }

    private enum CodingKeys: String, CodingKey {
        case provider
        case boardTheme = "board_theme"
        case pieceTheme = "piece_theme"
        case board
        case pieces
        case motion
        case zoom
    }
}

public struct BoardStyle: Codable, Equatable, Sendable {
    public let displayName: String
    public let palette: BoardPalette
    public let metrics: BoardMetrics

    private enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case palette
        case metrics
    }
}

public struct PieceStyle: Codable, Equatable, Sendable {
    public let displayName: String
    public let assets: PieceAssets
    public let palette: PiecePalette
    public let metrics: PieceMetrics

    private enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case assets
        case palette
        case metrics
    }
}

public struct PieceAssets: Codable, Equatable, Sendable {
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
    public let tintable: Bool

    public init(kind: BoardAssetKind, value: String, tintable: Bool) {
        self.kind = kind
        self.value = value
        self.tintable = tintable
    }
}

public enum BoardAssetKind: String, Codable, Equatable, Sendable {
    case textGlyph = "text_glyph"
    case svg
}

public struct RgbaColor: Codable, Equatable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
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
    }
}

public struct PiecePalette: Codable, Equatable, Sendable {
    public let whitePiece: RgbaColor
    public let blackPiece: RgbaColor
    public let whitePieceShadow: RgbaColor
    public let blackPieceShadow: RgbaColor
    public let promotedMarker: RgbaColor

    private enum CodingKeys: String, CodingKey {
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
        case coordinateFontScalePercent = "coordinate_font_scale_percent"
        case coordinateInset = "coordinate_inset"
        case destinationDotScalePercent = "destination_dot_scale_percent"
        case destinationRingInsetPercent = "destination_ring_inset_percent"
        case destinationRingWidthPercent = "destination_ring_width_percent"
        case checkGradientRadiusPercent = "check_gradient_radius_percent"
    }
}

public struct PieceMetrics: Codable, Equatable, Sendable {
    public let scalePercent: UInt8
    public let shadowRadiusTenths: UInt8
    public let shadowOffsetYTenths: Int8
    public let promotedMarkerScalePercent: UInt8
    public let promotedMarkerInset: UInt8

    private enum CodingKeys: String, CodingKey {
        case scalePercent = "scale_percent"
        case shadowRadiusTenths = "shadow_radius_tenths"
        case shadowOffsetYTenths = "shadow_offset_y_tenths"
        case promotedMarkerScalePercent = "promoted_marker_scale_percent"
        case promotedMarkerInset = "promoted_marker_inset"
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
    public static let boardTheme = "org.libchess.macos.boardTheme"
    public static let pieceTheme = "org.libchess.macos.pieceTheme"
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
            CGFloat(presentation.board.metrics.maximumExtent),
            availableWidth,
            availableHeight
        )
        return fittedExtent * CGFloat(zoom.scalePercent) / 100
    }
}
