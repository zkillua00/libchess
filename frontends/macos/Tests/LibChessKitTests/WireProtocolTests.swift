@testable import LibChessKit
import Foundation
import XCTest

final class WireProtocolTests: XCTestCase {
    func testDecodesOAuthAuthorizationEventWithExplicitWireKeys() throws {
        let data = Data(
            #"{"version":1,"request_id":"oauth-1","type":"oauth_authorization_required","provider":"lichess","authorization_url":"https://lichess.org/oauth?state=opaque","scopes":["board:play"]}"#.utf8
        )

        let event = try JSONDecoder().decode(WireEvent.self, from: data)

        XCTAssertEqual(event.requestID, "oauth-1")
        XCTAssertEqual(event.authorizationURL, "https://lichess.org/oauth?state=opaque")
        XCTAssertEqual(event.scopes, ["board:play"])
    }

    func testDecodesStableOAuthCapabilityName() throws {
        let data = Data(
            #"{"version":1,"type":"ready","providers":[{"id":"lichess","display_name":"Lichess","web_url":"https://lichess.org/","capabilities":["account","bot_games","oauth_pkce","future_capability"],"bot_opponents":[{"id":"level-1","display_name":"Level 1"}],"bot_game_options":{"variants":[{"id":"standard","display_name":"Standard","supports_custom_position":true,"requires_custom_position":false},{"id":"from-position","display_name":"From Position","supports_custom_position":true,"requires_custom_position":true}],"colors":["white","black","random"],"clock":{"initial_seconds":[0,15,30,45,60,90,120,10800],"increment_seconds":[0,1,2,3,60],"minimum_estimated_duration_seconds":180},"correspondence_days":[1,2,3,5,7,10,14],"unlimited":true}}]}"#.utf8
        )

        let event = try JSONDecoder().decode(WireEvent.self, from: data)

        XCTAssertEqual(event.providers?.first?.displayName, "Lichess")
        XCTAssertEqual(event.providers?.first?.webURL, "https://lichess.org/")
        XCTAssertEqual(
            event.providers?.first?.capabilities,
            [.account, .botGames, .oauthPkce, PlatformCapability(rawValue: "future_capability")]
        )
        XCTAssertEqual(event.providers?.first?.botOpponents.first?.id, "level-1")
        XCTAssertEqual(event.providers?.first?.botGameOptions?.variants.count, 2)
        XCTAssertEqual(
            event.providers?.first?.botGameOptions?.variants.last?.requiresCustomPosition,
            true
        )
        XCTAssertEqual(
            event.providers?.first?.botGameOptions?.clock?.initialSeconds,
            [0, 15, 30, 45, 60, 90, 120, 10_800]
        )
        XCTAssertEqual(
            event.providers?.first?.botGameOptions?.clock?.incrementSeconds,
            [0, 1, 2, 3, 60]
        )
        XCTAssertEqual(
            event.providers?.first?.botGameOptions?.correspondenceDays,
            [1, 2, 3, 5, 7, 10, 14]
        )
        XCTAssertEqual(event.providers?.first?.botGameOptions?.unlimited, true)
    }

    func testDecodesOAuthCredentialEventWithExplicitWireKeys() throws {
        let data = Data(
            #"{"version":1,"type":"oauth_credential_issued","provider":"lichess","access_token":"lio_test_only","expires_in_seconds":31536000}"#.utf8
        )

        let event = try JSONDecoder().decode(WireEvent.self, from: data)

        XCTAssertEqual(event.accessToken, "lio_test_only")
        XCTAssertEqual(event.expiresInSeconds, 31_536_000)
    }

    func testEncodesOAuthCommandsWithExplicitWireKeys() throws {
        let begin = BeginOAuthCommand(
            provider: "lichess",
            clientID: "org.libchess.macos",
            redirectURI: "org.libchess.macos://oauth/lichess"
        )
        let complete = CompleteOAuthCommand(
            callbackURL: "org.libchess.macos://oauth/lichess?code=one_time&state=opaque"
        )

        let beginObject = try jsonObject(begin)
        let completeObject = try jsonObject(complete)

        XCTAssertEqual(beginObject["client_id"] as? String, "org.libchess.macos")
        XCTAssertEqual(
            beginObject["redirect_uri"] as? String,
            "org.libchess.macos://oauth/lichess"
        )
        XCTAssertNil(beginObject["clientID"])
        XCTAssertNotNil(beginObject["request_id"])
        XCTAssertEqual(
            completeObject["callback_url"] as? String,
            "org.libchess.macos://oauth/lichess?code=one_time&state=opaque"
        )
    }

    func testDecodesCreatedBotGameEvent() throws {
        let data = Data(
            #"{"version":1,"request_id":"bot-1","type":"bot_game_created","game":{"provider":"lichess","id":"v8BRXYtM","url":"https://lichess.org/v8BRXYtM","player_color":"black","opponent":{"id":"level-6","display_name":"Level 6"},"variant":{"id":"atomic","display_name":"Atomic","supports_custom_position":false,"requires_custom_position":false},"time_control":{"type":"correspondence","days_per_move":7}}}"#.utf8
        )

        let event = try JSONDecoder().decode(WireEvent.self, from: data)

        XCTAssertEqual(event.requestID, "bot-1")
        XCTAssertEqual(event.game?.provider, "lichess")
        XCTAssertEqual(event.game?.id, "v8BRXYtM")
        XCTAssertEqual(event.game?.playerColor, .black)
        XCTAssertEqual(event.game?.opponent.id, "level-6")
        XCTAssertEqual(event.game?.opponent.displayName, "Level 6")
        XCTAssertEqual(event.game?.variant.id, "atomic")
        XCTAssertEqual(event.game?.timeControl, .correspondence(daysPerMove: 7))
        XCTAssertNil(event.game?.initialFEN)
    }

    func testEncodesEveryBotGameTimeControlWithExplicitWireKeys() throws {
        let clock = CreateBotGameCommand(
            opponentID: "level-6",
            variantID: "standard",
            timeControl: .clock(initialSeconds: 600, incrementSeconds: 5),
            color: .random,
            initialFEN: nil
        )
        let correspondence = CreateBotGameCommand(
            opponentID: "level-8",
            variantID: "atomic",
            timeControl: .correspondence(daysPerMove: 7),
            color: .white,
            initialFEN: nil
        )
        let unlimited = CreateBotGameCommand(
            opponentID: "level-2",
            variantID: "from-position",
            timeControl: .unlimited,
            color: .black,
            initialFEN: "8/8/8/8/8/8/4K3/6k1 w - - 0 1"
        )

        let clockObject = try jsonObject(clock)
        let correspondenceObject = try jsonObject(correspondence)
        let unlimitedObject = try jsonObject(unlimited)

        XCTAssertEqual(clockObject["type"] as? String, "create_bot_game")
        XCTAssertEqual(clockObject["opponent_id"] as? String, "level-6")
        XCTAssertEqual(clockObject["variant_id"] as? String, "standard")
        XCTAssertEqual(clockObject["color"] as? String, "random")
        let clockControl = try XCTUnwrap(clockObject["time_control"] as? [String: Any])
        XCTAssertEqual(clockControl["type"] as? String, "clock")
        XCTAssertEqual(clockControl["initial_seconds"] as? Int, 600)
        XCTAssertEqual(clockControl["increment_seconds"] as? Int, 5)
        XCTAssertNil(clockObject["initial_fen"])
        XCTAssertNotNil(clockObject["request_id"])

        let correspondenceControl = try XCTUnwrap(
            correspondenceObject["time_control"] as? [String: Any]
        )
        XCTAssertEqual(correspondenceControl["type"] as? String, "correspondence")
        XCTAssertEqual(correspondenceControl["days_per_move"] as? Int, 7)
        XCTAssertNil(correspondenceControl["initial_seconds"])

        let unlimitedControl = try XCTUnwrap(
            unlimitedObject["time_control"] as? [String: Any]
        )
        XCTAssertEqual(unlimitedControl["type"] as? String, "unlimited")
        XCTAssertEqual(unlimitedObject["variant_id"] as? String, "from-position")
        XCTAssertEqual(
            unlimitedObject["initial_fen"] as? String,
            "8/8/8/8/8/8/4K3/6k1 w - - 0 1"
        )
    }

    private func jsonObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
