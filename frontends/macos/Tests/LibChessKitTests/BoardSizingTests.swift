@testable import LibChessKit
import XCTest

final class BoardSizingTests: XCTestCase {
    func testEveryZoomLevelProducesADistinctSquareExtent() {
        let container = CGSize(width: 1_200, height: 900)

        let small = ChessBoardLayout.extent(
            in: container,
            zoom: .small,
            verticalChrome: 140
        )
        let medium = ChessBoardLayout.extent(
            in: container,
            zoom: .medium,
            verticalChrome: 140
        )
        let large = ChessBoardLayout.extent(
            in: container,
            zoom: .large,
            verticalChrome: 140
        )

        XCTAssertEqual(small, 532, accuracy: 0.001)
        XCTAssertEqual(medium, 646, accuracy: 0.001)
        XCTAssertEqual(large, 760, accuracy: 0.001)
        XCTAssertLessThan(small, medium)
        XCTAssertLessThan(medium, large)
    }

    func testBoardExtentNeverExceedsAvailableSpaceOrMaximum() {
        XCTAssertEqual(
            ChessBoardLayout.extent(
                in: CGSize(width: 2_000, height: 2_000),
                zoom: .large,
                verticalChrome: 56
            ),
            900
        )
        XCTAssertEqual(
            ChessBoardLayout.extent(
                in: CGSize(width: 40, height: 40),
                zoom: .large,
                verticalChrome: 56
            ),
            0
        )
    }
}
