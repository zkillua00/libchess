@testable import LibChessKit
import XCTest

final class BoardSizingTests: XCTestCase {
    func testProviderZoomPresetsProduceDistinctBoardExtents() throws {
        let presentation = makePresentation()
        let container = CGSize(width: 1_200, height: 900)
        let presets = presentation.zoom.presets

        let extents = presets.map {
            ChessBoardLayout.extent(
                in: container,
                presentation: presentation,
                zoom: $0,
                verticalChrome: 140
            )
        }

        XCTAssertEqual(extents, [532, 646, 760])
        XCTAssertLessThan(extents[0], extents[1])
        XCTAssertLessThan(extents[1], extents[2])
        XCTAssertEqual(presentation.zoom.defaultValue?.id, "medium")
        XCTAssertEqual(
            presentation.zoom.adjacent(to: presets[1], offset: 1).id,
            "large"
        )
    }

    func testBoardExtentUsesProviderMaximumAndAvailableSpace() throws {
        let presentation = makePresentation()
        let large = try XCTUnwrap(presentation.zoom.presets.last)

        XCTAssertEqual(
            ChessBoardLayout.extent(
                in: CGSize(width: 2_000, height: 2_000),
                presentation: presentation,
                zoom: large,
                verticalChrome: 56
            ),
            900
        )
        XCTAssertEqual(
            ChessBoardLayout.extent(
                in: CGSize(width: 40, height: 40),
                presentation: presentation,
                zoom: large,
                verticalChrome: 56
            ),
            0
        )
    }

    func testPresentationOwnsAssetsAndAnimationRules() throws {
        let presentation = makePresentation()

        XCTAssertEqual(
            presentation.pieceAsset(for: .knight, color: .white)?.value,
            "N"
        )
        XCTAssertEqual(presentation.assets.promotedMarker.value, "*")
        XCTAssertEqual(presentation.motion.pieceMove.durationMillis, 180)
        XCTAssertEqual(presentation.motion.pieceMove.curve, .spring)
        XCTAssertEqual(presentation.metrics.pieceScalePercent, 72)
    }

    private func makePresentation() -> BoardPresentation {
        BoardPresentation(
            provider: "test",
            theme: "portable",
            displayName: "Portable",
            assets: BoardAssets(
                pieces: [
                    BoardPieceAsset(
                        color: .white,
                        role: .knight,
                        asset: BoardAsset(kind: .textGlyph, value: "N")
                    ),
                ],
                promotedMarker: BoardAsset(kind: .textGlyph, value: "*")
            ),
            palette: BoardPalette(
                lightSquare: color(220),
                darkSquare: color(100),
                coordinateOnLight: color(100),
                coordinateOnDark: color(220),
                lastMove: color(180),
                selection: color(160),
                legalMove: color(80),
                checkCenter: color(240),
                checkEdge: color(120),
                border: color(50),
                shadow: color(30),
                whitePiece: color(255),
                blackPiece: color(0),
                whitePieceShadow: color(0),
                blackPieceShadow: color(255),
                promotedMarker: color(200)
            ),
            metrics: BoardMetrics(
                maximumExtent: 900,
                cornerRadius: 6,
                borderWidth: 1,
                shadowRadius: 10,
                shadowOffsetY: 5,
                pieceScalePercent: 72,
                pieceShadowRadiusTenths: 7,
                pieceShadowOffsetYTenths: 5,
                promotedMarkerScalePercent: 13,
                promotedMarkerInset: 3,
                coordinateFontScalePercent: 11,
                coordinateInset: 3,
                destinationDotScalePercent: 21,
                destinationRingInsetPercent: 5,
                destinationRingWidthPercent: 6,
                checkGradientRadiusPercent: 53
            ),
            motion: BoardMotion(
                boardResize: animation(260),
                pieceMove: animation(180),
                selection: animation(120),
                pieceAppearanceScalePercent: 55,
                fadePieceAppearance: true,
                maximumAnimatedPlyDistance: 1
            ),
            zoom: BoardZoomRules(
                presets: [
                    BoardZoomPreset(id: "small", displayName: "Small", scalePercent: 70),
                    BoardZoomPreset(id: "medium", displayName: "Medium", scalePercent: 85),
                    BoardZoomPreset(id: "large", displayName: "Large", scalePercent: 100),
                ],
                defaultPreset: "medium"
            )
        )
    }

    private func color(_ component: UInt8) -> RgbaColor {
        RgbaColor(red: component, green: component, blue: component, alpha: 255)
    }

    private func animation(_ duration: UInt16) -> BoardAnimationRule {
        BoardAnimationRule(
            durationMillis: duration,
            curve: .spring,
            extraBouncePercent: 0
        )
    }
}
