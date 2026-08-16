@testable import LibChessKit
import Foundation
import XCTest

final class LibChessStoreStreamTests: XCTestCase {
    @MainActor
    func testPostSnapshotStreamFailureAllowsAReconnect() throws {
        var commands: [[String: Any]] = []
        let store = LibChessStore(commandSink: { data in
            let command = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            commands.append(command)
        })
        let backend = #"{"id":"responsive-test","kind":"local_engine","display_name":"Responsive Test","subtitle":"Test backend","description":"Exercises stream state.","icon":"processor","action_title":"Use Test Backend","connection":{"type":"local"},"available":true,"capabilities":["account","live_games"]}"#

        store.receive(Data(#"{"version":1,"type":"ready","providers":[\#(backend)]}"#.utf8))
        store.receive(
            Data(
                #"{"version":1,"type":"backend_selection_changed","backend":\#(backend)}"#.utf8
            )
        )
        store.receive(
            Data(
                #"{"version":1,"type":"account_updated","account":{"provider":"responsive-test","id":"player-1","username":"Player One"}}"#.utf8
            )
        )
        store.receive(
            Data(
                #"{"version":1,"type":"live_games_updated","games":[{"provider":"responsive-test","id":"game-1","url":"","player_color":"white","display_name":"Opponent","variant_id":"standard","variant_name":"Standard","rated":false,"speed":"rapid","is_my_turn":true}]}"#.utf8
            )
        )

        store.openLiveGame("game-1")
        let firstStart = try XCTUnwrap(
            commands.first(where: { $0["type"] as? String == "start_live_game" })
        )
        let firstRequestID = try XCTUnwrap(firstStart["request_id"] as? String)
        XCTAssertTrue(store.isLoadingLiveGame("game-1"))

        store.receive(
            Data(
                #"{"version":1,"type":"live_game_updated","live_game":{"provider":"responsive-test","id":"game-1","url":"","player_color":"white","initial_fen":"startpos","variant_id":"standard","variant_name":"Standard","rated":false,"speed":"rapid","white":{"id":"player-1","name":"Player One","provisional":false},"black":{"name":"Opponent","provisional":false},"state":{"board":{"pieces":[],"pockets":[],"turn":"black","ply":1,"moves":["e2e4"],"legal_moves":[],"in_check":false},"status":"started","white_draw_offer":false,"black_draw_offer":false,"white_takeback_offer":false,"black_takeback_offer":false,"opponent_gone":false}},"san_moves":["e4"]}"#.utf8
            )
        )
        XCTAssertFalse(store.isLoadingLiveGame("game-1"))
        XCTAssertTrue(store.isLiveStreamConnected("game-1"))
        let game = try XCTUnwrap(store.liveGame("game-1"))
        XCTAssertEqual(store.displayedMoves(for: game), ["e4"])

        store.receive(
            Data(
                #"{"version":1,"request_id":"\#(firstRequestID)","type":"error","error":{"kind":"provider","message":"stream failed","retryable":true}}"#.utf8
            )
        )
        XCTAssertFalse(store.isLoadingLiveGame("game-1"))
        XCTAssertFalse(store.isLiveStreamConnected("game-1"))

        store.openLiveGame("game-1")
        let starts = commands.filter { $0["type"] as? String == "start_live_game" }
        XCTAssertEqual(starts.count, 2)
        XCTAssertNotEqual(starts[1]["request_id"] as? String, firstRequestID)
        XCTAssertTrue(store.isLoadingLiveGame("game-1"))
    }
}
