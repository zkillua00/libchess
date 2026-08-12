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
            #"{"version":1,"type":"ready","providers":[{"id":"lichess","display_name":"Lichess","capabilities":["account","oauth_pkce","future_capability"]}]}"#.utf8
        )

        let event = try JSONDecoder().decode(WireEvent.self, from: data)

        XCTAssertEqual(event.providers?.first?.displayName, "Lichess")
        XCTAssertEqual(
            event.providers?.first?.capabilities,
            [.account, .oauthPkce, PlatformCapability(rawValue: "future_capability")]
        )
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

    private func jsonObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
