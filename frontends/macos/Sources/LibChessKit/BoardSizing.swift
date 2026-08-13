import Foundation

public enum BoardZoomLevel: String, CaseIterable, Identifiable, Sendable {
    case small
    case medium
    case large

    public var id: Self { self }

    public static let preferenceKey = "org.libchess.macos.boardZoom"

    public var label: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    public var larger: Self {
        switch self {
        case .small: .medium
        case .medium, .large: .large
        }
    }

    public var smaller: Self {
        switch self {
        case .small, .medium: .small
        case .large: .medium
        }
    }

    fileprivate var scale: CGFloat {
        switch self {
        case .small: 0.70
        case .medium: 0.85
        case .large: 1
        }
    }
}

public enum ChessBoardLayout {
    public static func extent(
        in container: CGSize,
        zoom: BoardZoomLevel,
        horizontalChrome: CGFloat = 56,
        verticalChrome: CGFloat
    ) -> CGFloat {
        let availableWidth = max(0, container.width - horizontalChrome)
        let availableHeight = max(0, container.height - verticalChrome)
        let fittedExtent = min(900, availableWidth, availableHeight)
        return fittedExtent * zoom.scale
    }
}
