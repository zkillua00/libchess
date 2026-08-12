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

public struct ProviderDescriptor: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let webURL: String?
    public let capabilities: Set<PlatformCapability>
    public let botOpponents: [BotOpponent]

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case webURL = "web_url"
        case capabilities
        case botOpponents = "bot_opponents"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        webURL = try container.decodeIfPresent(String.self, forKey: .webURL)
        capabilities = try container.decode(Set<PlatformCapability>.self, forKey: .capabilities)
        botOpponents = try container.decodeIfPresent([BotOpponent].self, forKey: .botOpponents) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(webURL, forKey: .webURL)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(botOpponents, forKey: .botOpponents)
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

public enum GameColorPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case white
    case black
    case random

    public var id: Self { self }
}

public enum PlayerColor: String, Codable, Sendable {
    case white
    case black
}

public struct ClockTimeControl: Codable, Equatable, Sendable {
    public let initialSeconds: UInt32
    public let incrementSeconds: UInt32

    private enum CodingKeys: String, CodingKey {
        case initialSeconds = "initial_seconds"
        case incrementSeconds = "increment_seconds"
    }
}

public struct BotGame: Codable, Equatable, Identifiable, Sendable {
    public let provider: String
    public let id: String
    public let url: String
    public let playerColor: PlayerColor
    public let opponent: BotOpponent
    public let clock: ClockTimeControl

    private enum CodingKeys: String, CodingKey {
        case provider
        case id
        case url
        case playerColor = "player_color"
        case opponent
        case clock
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
