import Foundation

public enum PlatformCapability: String, Codable, Hashable, Sendable {
    case account
    case challenges
    case liveGames = "live_games"
    case matchmaking
    case pgnExport = "pgn_export"
    case realtimeEvents = "realtime_events"
}

public struct ProviderDescriptor: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let capabilities: Set<PlatformCapability>
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
}

