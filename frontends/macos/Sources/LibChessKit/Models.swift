import Foundation

public struct PlatformCapability: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let account = Self(rawValue: "account")
    public static let botGames = Self(rawValue: "bot_games")
    public static let challenges = Self(rawValue: "challenges")
    public static let liveGames = Self(rawValue: "live_games")
    public static let matchmaking = Self(rawValue: "matchmaking")
    public static let oauthPkce = Self(rawValue: "oauth_pkce")
    public static let pgnExport = Self(rawValue: "pgn_export")
    public static let realtimeEvents = Self(rawValue: "realtime_events")
}

public struct BotOpponent: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

public struct GameVariant: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let supportsCustomPosition: Bool
    public let requiresCustomPosition: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case supportsCustomPosition = "supports_custom_position"
        case requiresCustomPosition = "requires_custom_position"
    }
}

public struct ClockTimeControlOptions: Codable, Hashable, Sendable {
    public let initialSeconds: [UInt32]
    public let incrementSeconds: [UInt32]
    public let minimumEstimatedDurationSeconds: UInt32?

    private enum CodingKeys: String, CodingKey {
        case initialSeconds = "initial_seconds"
        case incrementSeconds = "increment_seconds"
        case minimumEstimatedDurationSeconds = "minimum_estimated_duration_seconds"
    }
}

public struct BotGameOptions: Codable, Hashable, Sendable {
    public let variants: [GameVariant]
    public let colors: Set<GameColorPreference>
    public let clock: ClockTimeControlOptions?
    public let correspondenceDays: [UInt8]
    public let unlimited: Bool

    private enum CodingKeys: String, CodingKey {
        case variants
        case colors
        case clock
        case correspondenceDays = "correspondence_days"
        case unlimited
    }
}

public struct ProviderDescriptor: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let webURL: String?
    public let capabilities: Set<PlatformCapability>
    public let botOpponents: [BotOpponent]
    public let botGameOptions: BotGameOptions?

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case webURL = "web_url"
        case capabilities
        case botOpponents = "bot_opponents"
        case botGameOptions = "bot_game_options"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        webURL = try container.decodeIfPresent(String.self, forKey: .webURL)
        capabilities = try container.decode(Set<PlatformCapability>.self, forKey: .capabilities)
        botOpponents = try container.decodeIfPresent([BotOpponent].self, forKey: .botOpponents) ?? []
        botGameOptions = try container.decodeIfPresent(BotGameOptions.self, forKey: .botGameOptions)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(webURL, forKey: .webURL)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(botOpponents, forKey: .botOpponents)
        try container.encodeIfPresent(botGameOptions, forKey: .botGameOptions)
    }
}

public struct ChessAccount: Codable, Equatable, Sendable {
    public let provider: String
    public let id: String
    public let username: String
    public let title: String?

    public var displayName: String {
        if let title {
            return "\(title) \(username)"
        }
        return username
    }
}

public enum GameColorPreference: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case white
    case black
    case random

    public var id: Self { self }
}

public enum PlayerColor: String, Codable, CaseIterable, Hashable, Sendable {
    case white
    case black
}

public enum PieceRole: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case pawn
    case knight
    case bishop
    case rook
    case queen
    case king

    public var id: Self { self }
}

public struct BoardPiece: Codable, Hashable, Identifiable, Sendable {
    public let square: String
    public let color: PlayerColor
    public let role: PieceRole
    public let promoted: Bool

    public var id: String { square }
}

public struct PocketPiece: Codable, Hashable, Identifiable, Sendable {
    public let color: PlayerColor
    public let role: PieceRole
    public let count: UInt8

    public var id: String { "\(color.rawValue)-\(role.rawValue)" }
}

public struct LegalMove: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let from: String?
    public let to: String
    public let promotion: PieceRole?
    public let drop: PieceRole?
}

public struct BoardState: Codable, Equatable, Sendable {
    public let pieces: [BoardPiece]
    public let pockets: [PocketPiece]
    public let turn: PlayerColor
    public let ply: UInt32
    public let moves: [String]
    public let lastMove: LegalMove?
    public let legalMoves: [LegalMove]
    public let inCheck: Bool

    private enum CodingKeys: String, CodingKey {
        case pieces
        case pockets
        case turn
        case ply
        case moves
        case lastMove = "last_move"
        case legalMoves = "legal_moves"
        case inCheck = "in_check"
    }
}

public struct LiveGamePlayer: Codable, Equatable, Sendable {
    public let id: String?
    public let name: String
    public let title: String?
    public let rating: UInt32?
    public let provisional: Bool
    public let aiLevel: UInt8?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case title
        case rating
        case provisional
        case aiLevel = "ai_level"
    }

    public var displayName: String {
        if let title {
            return "\(title) \(name)"
        }
        return name
    }
}

public struct LiveGameState: Codable, Equatable, Sendable {
    public let board: BoardState
    public let status: String
    public let winner: PlayerColor?
    public let whiteTimeMillis: UInt64?
    public let blackTimeMillis: UInt64?
    public let whiteIncrementMillis: UInt64?
    public let blackIncrementMillis: UInt64?
    public let whiteDrawOffer: Bool
    public let blackDrawOffer: Bool
    public let whiteTakebackOffer: Bool
    public let blackTakebackOffer: Bool
    public let opponentGone: Bool
    public let claimWinInSeconds: UInt32?

    private enum CodingKeys: String, CodingKey {
        case board
        case status
        case winner
        case whiteTimeMillis = "white_time_millis"
        case blackTimeMillis = "black_time_millis"
        case whiteIncrementMillis = "white_increment_millis"
        case blackIncrementMillis = "black_increment_millis"
        case whiteDrawOffer = "white_draw_offer"
        case blackDrawOffer = "black_draw_offer"
        case whiteTakebackOffer = "white_takeback_offer"
        case blackTakebackOffer = "black_takeback_offer"
        case opponentGone = "opponent_gone"
        case claimWinInSeconds = "claim_win_in_seconds"
    }

    public var isPlayable: Bool {
        status == "created" || status == "started"
    }
}

public struct LiveGameClock: Codable, Equatable, Sendable {
    public let initialMillis: UInt64
    public let incrementMillis: UInt64

    private enum CodingKeys: String, CodingKey {
        case initialMillis = "initial_millis"
        case incrementMillis = "increment_millis"
    }
}

public struct LiveGame: Codable, Equatable, Identifiable, Sendable {
    public let provider: String
    public let id: String
    public let url: String
    public let playerColor: PlayerColor
    public let variantID: String
    public let variantName: String
    public let rated: Bool
    public let speed: String
    public let clock: LiveGameClock?
    public let daysPerTurn: UInt32?
    public let white: LiveGamePlayer
    public let black: LiveGamePlayer
    public let state: LiveGameState

    private enum CodingKeys: String, CodingKey {
        case provider
        case id
        case url
        case playerColor = "player_color"
        case variantID = "variant_id"
        case variantName = "variant_name"
        case rated
        case speed
        case clock
        case daysPerTurn = "days_per_turn"
        case white
        case black
        case state
    }
}

public struct LiveChatMessage: Codable, Equatable, Sendable {
    public let gameID: String
    public let room: String
    public let username: String
    public let text: String

    private enum CodingKeys: String, CodingKey {
        case gameID = "game_id"
        case room
        case username
        case text
    }
}

public enum LiveGameAction: String, Codable, CaseIterable, Hashable, Identifiable, Sendable {
    case abort
    case resign
    case offerDraw = "offer_draw"
    case acceptDraw = "accept_draw"
    case declineDraw = "decline_draw"
    case offerTakeback = "offer_takeback"
    case acceptTakeback = "accept_takeback"
    case declineTakeback = "decline_takeback"
    case claimVictory = "claim_victory"
    case claimDraw = "claim_draw"

    public var id: Self { self }
}

public enum BotGameTimeControl: Codable, Equatable, Sendable {
    case clock(initialSeconds: UInt32, incrementSeconds: UInt32)
    case correspondence(daysPerMove: UInt8)
    case unlimited

    private enum Kind: String, Codable {
        case clock
        case correspondence
        case unlimited
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case initialSeconds = "initial_seconds"
        case incrementSeconds = "increment_seconds"
        case daysPerMove = "days_per_move"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .clock:
            self = try .clock(
                initialSeconds: container.decode(UInt32.self, forKey: .initialSeconds),
                incrementSeconds: container.decode(UInt32.self, forKey: .incrementSeconds)
            )
        case .correspondence:
            self = try .correspondence(
                daysPerMove: container.decode(UInt8.self, forKey: .daysPerMove)
            )
        case .unlimited:
            self = .unlimited
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .clock(initialSeconds, incrementSeconds):
            try container.encode(Kind.clock, forKey: .type)
            try container.encode(initialSeconds, forKey: .initialSeconds)
            try container.encode(incrementSeconds, forKey: .incrementSeconds)
        case let .correspondence(daysPerMove):
            try container.encode(Kind.correspondence, forKey: .type)
            try container.encode(daysPerMove, forKey: .daysPerMove)
        case .unlimited:
            try container.encode(Kind.unlimited, forKey: .type)
        }
    }
}

public struct BotGame: Codable, Equatable, Identifiable, Sendable {
    public let provider: String
    public let id: String
    public let url: String
    public let playerColor: PlayerColor
    public let opponent: BotOpponent
    public let variant: GameVariant
    public let timeControl: BotGameTimeControl
    public let initialFEN: String?

    private enum CodingKeys: String, CodingKey {
        case provider
        case id
        case url
        case playerColor = "player_color"
        case opponent
        case variant
        case timeControl = "time_control"
        case initialFEN = "initial_fen"
    }
}

public enum ConnectionState: String, Codable, Sendable {
    case authorizing
    case connected
    case connecting
    case disconnected
}

public struct LibChessFailure: Codable, Error, Equatable, Sendable {
    public let kind: String
    public let message: String
    public let retryable: Bool
}

struct WireEvent: Decodable, Sendable {
    let version: UInt32
    let requestID: String?
    let type: String
    let providers: [ProviderDescriptor]?
    let account: ChessAccount?
    let state: ConnectionState?
    let provider: String?
    let error: LibChessFailure?
    let authorizationURL: String?
    let scopes: [String]?
    let accessToken: String?
    let expiresInSeconds: UInt64?
    let game: BotGame?
    let liveGame: LiveGame?
    let chat: LiveChatMessage?
    let gameID: String?
    let moveID: String?
    let action: LiveGameAction?

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case type
        case providers
        case account
        case state
        case provider
        case error
        case authorizationURL = "authorization_url"
        case scopes
        case accessToken = "access_token"
        case expiresInSeconds = "expires_in_seconds"
        case game
        case liveGame = "live_game"
        case chat
        case gameID = "game_id"
        case moveID = "move_id"
        case action
    }
}
