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
    public static let challenges = Self(rawValue: "challenges")
    public static let liveGames = Self(rawValue: "live_games")
    public static let matchmaking = Self(rawValue: "matchmaking")
    public static let oauthPkce = Self(rawValue: "oauth_pkce")
    public static let pgnExport = Self(rawValue: "pgn_export")
    public static let realtimeEvents = Self(rawValue: "realtime_events")
}

public struct ProviderDescriptor: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let capabilities: Set<PlatformCapability>

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case capabilities
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
    }
}
