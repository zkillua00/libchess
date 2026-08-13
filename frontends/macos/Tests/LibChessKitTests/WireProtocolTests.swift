@testable import LibChessKit
import AppKit
import Foundation
import XCTest

final class WireProtocolTests: XCTestCase {
    func testBlackBoardPerspectiveRotatesRanksAndMirrorsFiles() {
        let white = BoardPerspective.squares(for: .white)
        let black = BoardPerspective.squares(for: .black)

        XCTAssertEqual(Array(white.prefix(8)), ["a8", "b8", "c8", "d8", "e8", "f8", "g8", "h8"])
        XCTAssertEqual(Array(white.suffix(8)), ["a1", "b1", "c1", "d1", "e1", "f1", "g1", "h1"])
        XCTAssertEqual(Array(black.prefix(8)), ["h1", "g1", "f1", "e1", "d1", "c1", "b1", "a1"])
        XCTAssertEqual(Array(black.suffix(8)), ["h8", "g8", "f8", "e8", "d8", "c8", "b8", "a8"])
    }

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

    func testDecodesLiveGameSnapshotWithBoardAndLegalMoves() throws {
        let data = Data(
            #"{"version":1,"type":"live_game_updated","live_game":{"provider":"lichess","id":"v8BRXYtM","url":"https://lichess.org/v8BRXYtM","player_color":"white","initial_fen":"startpos","variant_id":"standard","variant_name":"Standard","rated":false,"speed":"rapid","clock":{"initial_millis":600000,"increment_millis":0},"white":{"id":"test-user","name":"TestUser","rating":1500,"provisional":false},"black":{"name":"Stockfish level 4","provisional":false,"ai_level":4},"state":{"board":{"pieces":[{"square":"e1","color":"white","role":"king","promoted":false},{"square":"e8","color":"black","role":"king","promoted":false},{"square":"e2","color":"white","role":"pawn","promoted":false}],"pockets":[],"turn":"white","ply":0,"moves":[],"legal_moves":[{"id":"e2e4","from":"e2","to":"e4"}],"in_check":false},"status":"started","white_time_millis":600000,"black_time_millis":600000,"white_increment_millis":0,"black_increment_millis":0,"white_draw_offer":false,"black_draw_offer":false,"white_takeback_offer":false,"black_takeback_offer":false,"opponent_gone":false}}}"#.utf8
        )

        let event = try JSONDecoder().decode(WireEvent.self, from: data)
        let game = try XCTUnwrap(event.liveGame)

        XCTAssertEqual(game.id, "v8BRXYtM")
        XCTAssertEqual(game.playerColor, .white)
        XCTAssertEqual(game.black.aiLevel, 4)
        XCTAssertEqual(game.clock?.initialMillis, 600_000)
        XCTAssertEqual(game.state.board.pieces.count, 3)
        XCTAssertEqual(game.state.board.legalMoves.first?.id, "e2e4")
        XCTAssertEqual(game.state.board.legalMoves.first?.from, "e2")
        XCTAssertEqual(game.state.board.legalMoves.first?.to, "e4")
        XCTAssertTrue(game.state.isPlayable)
    }

    func testDecodesTheOngoingGameCatalogWithProviderNames() throws {
        let data = Data(
            #"{"version":1,"type":"live_games_updated","games":[{"provider":"lichess","id":"rCRw1AuO","url":"https://lichess.org/rCRw1AuO","player_color":"black","display_name":"Philippe","variant_id":"standard","variant_name":"Standard","rated":true,"speed":"correspondence","is_my_turn":true},{"provider":"lichess","id":"v8BRXYtM","url":"https://lichess.org/v8BRXYtM","player_color":"white","display_name":"Stockfish level 4","variant_id":"atomic","variant_name":"Atomic","rated":false,"speed":"rapid","is_my_turn":false}]}"#.utf8
        )

        let event = try JSONDecoder().decode(WireEvent.self, from: data)
        let games = try XCTUnwrap(event.games)

        XCTAssertEqual(games.map(\.displayName), ["Philippe", "Stockfish level 4"])
        XCTAssertEqual(games.first?.playerColor, .black)
        XCTAssertEqual(games.first?.variantID, "standard")
        XCTAssertEqual(games.first?.isMyTurn, true)
    }

    func testDecodesPaginatedGameHistoryAndAnnotatedPGNExport() throws {
        let historyData = Data(
            #"{"version":1,"request_id":"history-1","type":"game_history_updated","page":{"games":[{"provider":"lichess","id":"AbCd1234","url":"https://lichess.org/AbCd1234","analysis_url":"https://lichess.org/AbCd1234/black/analysis","player_color":"black","opponent_name":"Opponent","opponent_title":"GM","opponent_rating":2100,"variant_id":"three-check","variant_name":"Three-check","rated":true,"speed":"blitz","status":"resign","winner":"white","created_at_millis":2000,"last_move_at_millis":2900}],"next_before_millis":1999},"append":false}"#.utf8
        )
        let exportData = Data(
            #"{"version":1,"request_id":"export-1","type":"game_exported","game_export":{"provider":"lichess","game_id":"AbCd1234","suggested_filename":"lichess-AbCd1234.pgn","pgn":"[Event \"Rated blitz game\"]\n\n1. e4 e5 *\n"}}"#.utf8
        )

        let history = try JSONDecoder().decode(WireEvent.self, from: historyData)
        let game = try XCTUnwrap(history.page?.games.first)
        let export = try JSONDecoder().decode(WireEvent.self, from: exportData).gameExport

        XCTAssertEqual(history.append, false)
        XCTAssertEqual(history.page?.nextBeforeMillis, 1_999)
        XCTAssertEqual(game.playerColor, .black)
        XCTAssertEqual(game.opponentDisplayName, "GM Opponent")
        XCTAssertEqual(game.variantID, "three-check")
        XCTAssertEqual(game.analysisURL, "https://lichess.org/AbCd1234/black/analysis")
        XCTAssertEqual(export?.suggestedFilename, "lichess-AbCd1234.pgn")
        XCTAssertTrue(export?.pgn.contains("1. e4 e5") == true)
    }

    func testEncodesHistoryAndExportCommandsWithExplicitWireKeys() throws {
        let history = RefreshGameHistoryCommand(beforeMillis: 1_999, limit: 20)
        let export = ExportGameCommand(gameID: "AbCd1234")

        let historyObject = try jsonObject(history)
        let exportObject = try jsonObject(export)

        XCTAssertEqual(historyObject["type"] as? String, "refresh_game_history")
        XCTAssertEqual(historyObject["before_millis"] as? Int, 1_999)
        XCTAssertEqual(historyObject["limit"] as? Int, 20)
        XCTAssertNotNil(historyObject["request_id"])
        XCTAssertEqual(exportObject["type"] as? String, "export_game")
        XCTAssertEqual(exportObject["game_id"] as? String, "AbCd1234")
    }

    func testDecodesNativeGameReviewAndPosition() throws {
        let data = Data(
            #"{"version":1,"request_id":"review-1","type":"game_review_loaded","review":{"provider":"lichess","game_id":"AbCd1234","variant_id":"standard","initial_fen":"startpos","opening":{"eco":"C20","name":"King's Pawn Game","ply":2},"moves":[{"ply":1,"san":"e4","move_id":"e2e4","clock_millis":600000,"evaluation":{"centipawns":18}},{"ply":2,"san":"e5","move_id":"e7e5","evaluation":{"centipawns":72,"best_move":"e7e6","variation":"e6 d4","judgment":{"kind":"inaccuracy","comment":"Inaccuracy. e6 was best."}}}]},"board":{"pieces":[{"square":"e1","color":"white","role":"king","promoted":false},{"square":"e8","color":"black","role":"king","promoted":false},{"square":"e4","color":"white","role":"pawn","promoted":false},{"square":"e5","color":"black","role":"pawn","promoted":false}],"pockets":[],"turn":"white","ply":2,"moves":["e2e4","e7e5"],"last_move":{"id":"e7e5","from":"e7","to":"e5"},"legal_moves":[],"in_check":false}}"#.utf8
        )

        let event = try JSONDecoder().decode(WireEvent.self, from: data)
        let review = try XCTUnwrap(event.review)
        let board = try XCTUnwrap(event.board)

        XCTAssertEqual(review.gameID, "AbCd1234")
        XCTAssertEqual(review.opening?.name, "King's Pawn Game")
        XCTAssertEqual(review.moves.map(\.san), ["e4", "e5"])
        XCTAssertEqual(review.moves.last?.evaluation?.bestMove, "e7e6")
        XCTAssertEqual(review.moves.last?.evaluation?.judgment?.kind, .inaccuracy)
        XCTAssertEqual(board.ply, 2)
        XCTAssertEqual(board.lastMove?.id, "e7e5")
    }

    func testEncodesNativeReviewCommandsWithExplicitWireKeys() throws {
        let load = LoadGameReviewCommand(gameID: "AbCd1234")
        let position = ShowGameReviewPositionCommand(gameID: "AbCd1234", ply: 17)

        let loadObject = try jsonObject(load)
        let positionObject = try jsonObject(position)

        XCTAssertEqual(loadObject["type"] as? String, "load_game_review")
        XCTAssertEqual(loadObject["game_id"] as? String, "AbCd1234")
        XCTAssertNotNil(loadObject["request_id"])
        XCTAssertEqual(positionObject["type"] as? String, "show_game_review_position")
        XCTAssertEqual(positionObject["game_id"] as? String, "AbCd1234")
        XCTAssertEqual(positionObject["ply"] as? Int, 17)
    }

    func testDecodesPortableBoardProviderPresentation() throws {
        let data = Data(
            #"{"version":1,"request_id":"board-1","type":"board_presentation_loaded","board_presentation":{"provider":"libchess","board_theme":"slate","piece_theme":"cc0-silhouette","board":{"display_name":"Slate","palette":{"light_square":{"red":204,"green":213,"blue":224,"alpha":255},"dark_square":{"red":78,"green":101,"blue":128,"alpha":255},"coordinate_on_light":{"red":78,"green":101,"blue":128,"alpha":255},"coordinate_on_dark":{"red":204,"green":213,"blue":224,"alpha":255},"last_move":{"red":255,"green":190,"blue":74,"alpha":112},"selection":{"red":100,"green":210,"blue":255,"alpha":132},"legal_move":{"red":14,"green":23,"blue":33,"alpha":92},"check_center":{"red":255,"green":69,"blue":58,"alpha":204},"check_edge":{"red":255,"green":69,"blue":58,"alpha":23},"border":{"red":7,"green":17,"blue":28,"alpha":82},"shadow":{"red":0,"green":0,"blue":0,"alpha":56}},"metrics":{"maximum_extent":900,"corner_radius":6,"border_width":1,"shadow_radius":10,"shadow_offset_y":5,"coordinate_font_scale_percent":11,"coordinate_inset":3,"destination_dot_scale_percent":21,"destination_ring_inset_percent":5,"destination_ring_width_percent":6,"check_gradient_radius_percent":53}},"pieces":{"display_name":"CC0 Silhouette","assets":{"pieces":[{"color":"white","role":"pawn","asset":{"kind":"svg","value":"<svg width='50' height='50' viewBox='0 0 50 50' xmlns='http://www.w3.org/2000/svg'><circle cx='25' cy='25' r='20' fill='black'/></svg>","tintable":true}}],"promoted_marker":{"kind":"text_glyph","value":"★","tintable":true}},"palette":{"white_piece":{"red":250,"green":252,"blue":255,"alpha":255},"black_piece":{"red":18,"green":25,"blue":34,"alpha":255},"white_piece_shadow":{"red":3,"green":13,"blue":24,"alpha":153},"black_piece_shadow":{"red":226,"green":239,"blue":255,"alpha":92},"promoted_marker":{"red":255,"green":190,"blue":74,"alpha":255}},"metrics":{"scale_percent":82,"shadow_radius_tenths":9,"shadow_offset_y_tenths":6,"promoted_marker_scale_percent":13,"promoted_marker_inset":3}},"motion":{"board_resize":{"duration_millis":260,"curve":"spring","extra_bounce_percent":0},"piece_move":{"duration_millis":180,"curve":"spring","extra_bounce_percent":0},"selection":{"duration_millis":120,"curve":"ease_out","extra_bounce_percent":0},"piece_appearance_scale_percent":55,"fade_piece_appearance":true,"maximum_animated_ply_distance":1},"zoom":{"presets":[{"id":"small","display_name":"Small","scale_percent":70},{"id":"medium","display_name":"Medium","scale_percent":85},{"id":"large","display_name":"Large","scale_percent":100}],"default_preset":"medium"}}}"#.utf8
        )

        let event = try JSONDecoder().decode(WireEvent.self, from: data)
        let presentation = try XCTUnwrap(event.boardPresentation)

        XCTAssertEqual(event.requestID, "board-1")
        XCTAssertEqual(presentation.id, "libchess/slate/cc0-silhouette")
        XCTAssertEqual(
            presentation.pieceAsset(for: .pawn, color: .white)?.kind,
            .svg
        )
        XCTAssertEqual(presentation.board.displayName, "Slate")
        XCTAssertEqual(presentation.pieces.displayName, "CC0 Silhouette")
        let svg = try XCTUnwrap(presentation.pieceAsset(for: .pawn, color: .white))
        XCTAssertNotNil(svg.value.data(using: .utf8).flatMap(NSImage.init(data:)))
        XCTAssertEqual(presentation.motion.selection.curve, .easeOut)
        XCTAssertEqual(presentation.zoom.defaultValue?.displayName, "Medium")
    }

    func testEncodesBoardPresentationCommandWithExplicitWireKeys() throws {
        let command = LoadBoardPresentationCommand(
            provider: "libchess",
            boardTheme: "slate",
            pieceTheme: "cc0-silhouette"
        )
        let object = try jsonObject(command)

        XCTAssertEqual(object["type"] as? String, "load_board_presentation")
        XCTAssertEqual(object["provider"] as? String, "libchess")
        XCTAssertEqual(object["board_theme"] as? String, "slate")
        XCTAssertEqual(object["piece_theme"] as? String, "cc0-silhouette")
        XCTAssertNotNil(object["request_id"])
    }

    func testEncodesPortableCustomizationCommands() throws {
        let board = CustomBoardTheme(
            provider: "libchess",
            id: "night-board",
            displayName: "Night Board",
            baseTheme: "slate",
            adjustment: ThemeColorAdjustment(
                hueDegrees: 18,
                saturationPercent: 12,
                brightnessPercent: -20
            ),
            colors: BoardColorOverrides(
                lightSquare: RgbaColor(red: 160, green: 170, blue: 180),
                darkSquare: RgbaColor(red: 35, green: 45, blue: 60)
            )
        )
        let pieces = CustomPieceTheme(
            provider: "libchess",
            id: "blue-pieces",
            displayName: "Blue Pieces",
            baseTheme: "system-solid",
            adjustment: .identity,
            colors: PieceColorOverrides(
                blackPiece: RgbaColor(red: 20, green: 60, blue: 180)
            ),
            assets: nil
        )

        let boardObject = try jsonObject(RegisterCustomBoardThemeCommand(theme: board))
        let pieceObject = try jsonObject(RegisterCustomPieceThemeCommand(theme: pieces))
        let removeObject = try jsonObject(
            RemoveCustomBoardThemeCommand(provider: "libchess", theme: "night-board")
        )

        XCTAssertEqual(boardObject["type"] as? String, "register_custom_board_theme")
        let encodedBoard = try XCTUnwrap(boardObject["theme"] as? [String: Any])
        XCTAssertEqual(encodedBoard["base_theme"] as? String, "slate")
        let adjustment = try XCTUnwrap(encodedBoard["adjustment"] as? [String: Any])
        XCTAssertEqual(adjustment["hue_degrees"] as? Int, 18)
        XCTAssertEqual(pieceObject["type"] as? String, "register_custom_piece_theme")
        XCTAssertEqual(removeObject["type"] as? String, "remove_custom_board_theme")
        XCTAssertEqual(removeObject["theme"] as? String, "night-board")
    }

    func testDecodesPortableCustomizationSnapshot() throws {
        let data = Data(
            #"{"version":1,"request_id":"custom-1","type":"board_customization_changed","board_providers":[],"board_customization":{"version":1,"board_themes":[{"provider":"libchess","id":"night-board","display_name":"Night Board","base_theme":"slate","adjustment":{"hue_degrees":18,"saturation_percent":12,"brightness_percent":-20},"colors":{"light_square":{"red":160,"green":170,"blue":180,"alpha":255},"dark_square":{"red":35,"green":45,"blue":60,"alpha":255}}}],"piece_themes":[]}}"#.utf8
        )

        let event = try JSONDecoder().decode(WireEvent.self, from: data)
        let snapshot = try XCTUnwrap(event.boardCustomization)

        XCTAssertEqual(snapshot.version, BOARD_CUSTOMIZATION_STATE_VERSION)
        XCTAssertEqual(snapshot.boardThemes.first?.displayName, "Night Board")
        XCTAssertEqual(snapshot.boardThemes.first?.adjustment.brightnessPercent, -20)
        XCTAssertEqual(snapshot.boardThemes.first?.colors.darkSquare?.blue, 60)
    }

    func testDecodesAClientPredictedBoardBeforeServerConfirmation() throws {
        let data = Data(
            #"{"version":1,"request_id":"move-1","type":"move_predicted","game_id":"v8BRXYtM","move_id":"e2e4","board":{"pieces":[{"square":"e1","color":"white","role":"king","promoted":false},{"square":"e8","color":"black","role":"king","promoted":false},{"square":"e4","color":"white","role":"pawn","promoted":false}],"pockets":[],"turn":"black","ply":1,"moves":["e2e4"],"last_move":{"id":"e2e4","from":"e2","to":"e4"},"legal_moves":[{"id":"e7e5","from":"e7","to":"e5"}],"in_check":false}}"#.utf8
        )

        let event = try JSONDecoder().decode(WireEvent.self, from: data)
        let board = try XCTUnwrap(event.board)

        XCTAssertEqual(event.requestID, "move-1")
        XCTAssertEqual(event.gameID, "v8BRXYtM")
        XCTAssertEqual(event.moveID, "e2e4")
        XCTAssertEqual(board.moves, ["e2e4"])
        XCTAssertEqual(board.turn, .black)
        XCTAssertEqual(board.lastMove?.id, "e2e4")
        XCTAssertTrue(board.pieces.contains(where: { $0.square == "e4" }))
    }

    func testEncodesLiveGameplayCommandsWithExplicitWireKeys() throws {
        let start = StartLiveGameCommand(gameID: "v8BRXYtM", playerColor: .black)
        let stop = StopLiveGameCommand(gameID: "v8BRXYtM")
        let move = PlayMoveCommand(gameID: "v8BRXYtM", moveID: "e7e8q", offerDraw: true)
        let action = PerformGameActionCommand(gameID: "v8BRXYtM", action: .offerTakeback)

        let startObject = try jsonObject(start)
        let stopObject = try jsonObject(stop)
        let moveObject = try jsonObject(move)
        let actionObject = try jsonObject(action)

        XCTAssertEqual(startObject["type"] as? String, "start_live_game")
        XCTAssertEqual(startObject["game_id"] as? String, "v8BRXYtM")
        XCTAssertEqual(startObject["player_color"] as? String, "black")
        XCTAssertEqual(stopObject["type"] as? String, "stop_live_game")
        XCTAssertEqual(stopObject["game_id"] as? String, "v8BRXYtM")
        XCTAssertEqual(moveObject["type"] as? String, "play_move")
        XCTAssertEqual(moveObject["move_id"] as? String, "e7e8q")
        XCTAssertEqual(moveObject["offer_draw"] as? Bool, true)
        XCTAssertEqual(actionObject["type"] as? String, "perform_game_action")
        XCTAssertEqual(actionObject["action"] as? String, "offer_takeback")
    }

    private func jsonObject<Value: Encodable>(_ value: Value) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
