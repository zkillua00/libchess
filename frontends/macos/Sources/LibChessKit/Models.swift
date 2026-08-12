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

public enum PlayerColor: String, Codable, Sendable {
    case white
    case black
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
    }
}
