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
            #"{"version":1,"type":"ready","providers":[{"id":"lichess","display_name":"Lichess","web_url":"https://lichess.org/","capabilities":["account","bot_games","oauth_pkce","future_capability"],"bot_opponents":[{"id":"level-1","display_name":"Level 1"}]}]}"#.utf8
        )

        let event = try JSONDecoder().decode(WireEvent.self, from: data)

        XCTAssertEqual(event.providers?.first?.displayName, "Lichess")
        XCTAssertEqual(event.providers?.first?.webURL, "https://lichess.org/")
        XCTAssertEqual(
            event.providers?.first?.capabilities,
            [.account, .botGames, .oauthPkce, PlatformCapability(rawValue: "future_capability")]
        )
        XCTAssertEqual(event.providers?.first?.botOpponents.first?.id, "level-1")
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
            #"{"version":1,"request_id":"bot-1","type":"bot_game_created","game":{"provider":"lichess","id":"v8BRXYtM","url":"https://lichess.org/v8BRXYtM","player_color":"black","opponent":{"id":"level-6","display_name":"Level 6"},"clock":{"initial_seconds":600,"increment_seconds":5}}}"#.utf8
        )

        let event = try JSONDecoder().decode(WireEvent.self, from: data)

        XCTAssertEqual(event.requestID, "bot-1")
        XCTAssertEqual(event.game?.provider, "lichess")
        XCTAssertEqual(event.game?.id, "v8BRXYtM")
        XCTAssertEqual(event.game?.playerColor, .black)
        XCTAssertEqual(event.game?.opponent.id, "level-6")
        XCTAssertEqual(event.game?.opponent.displayName, "Level 6")
        XCTAssertEqual(event.game?.clock.initialSeconds, 600)
        XCTAssertEqual(event.game?.clock.incrementSeconds, 5)
    }

    func testEncodesBotGameCommandWithExplicitWireKeys() throws {
        let command = CreateBotGameCommand(
            opponentID: "level-6",
            initialSeconds: 600,
            incrementSeconds: 5,
            color: .random
        )

        let object = try jsonObject(command)

        XCTAssertEqual(object["type"] as? String, "create_bot_game")
        XCTAssertEqual(object["opponent_id"] as? String, "level-6")
        XCTAssertEqual(object["initial_seconds"] as? Int, 600)
        XCTAssertEqual(object["increment_seconds"] as? Int, 5)
        XCTAssertEqual(object["color"] as? String, "random")
        XCTAssertNil(object["initialSeconds"])
        XCTAssertNotNil(object["request_id"])
    }

    private func jsonObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
