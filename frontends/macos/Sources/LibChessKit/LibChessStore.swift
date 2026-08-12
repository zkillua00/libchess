import Combine
import CLibChess
import Foundation

@MainActor
public final class LibChessStore: ObservableObject {
    @Published public private(set) var providers: [ProviderDescriptor] = []
    @Published public private(set) var account: ChessAccount?
    @Published public private(set) var connectionState = ConnectionState.disconnected
    @Published public private(set) var savedCredentialAvailable = false
    @Published public private(set) var authorizationURL: URL?
    @Published public var message: String?

    private let decoder: JSONDecoder
    private let tokenStore = KeychainTokenStore()
    private var nativeClient: NativeClient?

    public init() {
        decoder = JSONDecoder()

        do {
            savedCredentialAvailable = try tokenStore.load(provider: "lichess") != nil
            nativeClient = try NativeClient { [weak self] data in
                self?.receive(data)
            }
        } catch {
            message = error.localizedDescription
        }
    }

    public func beginLichessOAuth() {
        message = nil
        send(
            BeginOAuthCommand(
                provider: "lichess",
                clientID: LichessOAuth.clientID,
                redirectURI: LichessOAuth.redirectURI
            )
        )
    }

    public func connectUsingSavedCredential() {
        do {
            guard let token = try tokenStore.load(provider: "lichess") else {
                savedCredentialAvailable = false
                message = "No saved Lichess credential was found."
                return
            }
            message = nil
            send(ConnectCommand(provider: "lichess", accessToken: token))
        } catch {
            message = error.localizedDescription
        }
    }

    @discardableResult
    public func handleOpenURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == LichessOAuth.callbackScheme,
              url.host?.lowercased() == "oauth",
              url.path == "/lichess"
        else {
            return false
        }

        authorizationURL = nil
        message = nil
        send(CompleteOAuthCommand(callbackURL: url.absoluteString))
        return true
    }

    public func cancelOAuth() {
        authorizationURL = nil
        send(BasicCommand(type: "cancel_oauth"))
    }

    public func refreshAccount() {
        message = nil
        send(BasicCommand(type: "refresh_account"))
    }

    public func disconnect(forgetCredential: Bool = false) {
        send(BasicCommand(type: "disconnect"))
        account = nil
        authorizationURL = nil

        guard forgetCredential else {
            return
        }
        do {
            try tokenStore.delete(provider: "lichess")
            savedCredentialAvailable = false
        } catch {
            message = error.localizedDescription
        }
    }

    private func send<Command: Encodable>(_ command: Command) {
        do {
            guard let nativeClient else {
                throw NativeClientError.couldNotCreate
            }
            try nativeClient.send(command)
        } catch {
            message = error.localizedDescription
        }
    }

    private func receive(_ data: Data) {
        do {
            let event = try decoder.decode(WireEvent.self, from: data)
            guard event.version == LIBCHESS_API_VERSION else {
                throw NativeClientError.unsupportedAPIVersion(
                    expected: LIBCHESS_API_VERSION,
                    actual: event.version
                )
            }

            switch event.type {
            case "ready", "providers":
                providers = event.providers ?? []
            case "connection_state_changed":
                if let state = event.state {
                    connectionState = state
                }
                if event.state == .disconnected {
                    account = nil
                    authorizationURL = nil
                }
            case "account_updated":
                account = event.account
            case "oauth_authorization_required":
                receiveAuthorizationURL(event.authorizationURL)
            case "oauth_credential_issued":
                persistOAuthCredential(event)
            case "error":
                message = event.error?.message ?? "LibChess reported an unknown error."
            default:
                break
            }
        } catch {
            message = "Could not decode a LibChess event: \(error.localizedDescription)"
        }
    }

    private func receiveAuthorizationURL(_ value: String?) {
        guard let value,
              let url = URL(string: value),
              url.scheme == "https",
              url.host == "lichess.org"
        else {
            message = "LibChess returned an invalid Lichess authorization URL."
            return
        }
        authorizationURL = url
    }

    private func persistOAuthCredential(_ event: WireEvent) {
        guard let token = event.accessToken,
              !token.isEmpty,
              token.count <= 4096
        else {
            message = "Lichess returned an invalid OAuth credential."
            return
        }
        let provider = event.provider ?? "lichess"
        do {
            try tokenStore.save(token, provider: provider)
            savedCredentialAvailable = true
        } catch {
            message = "Connected, but the credential could not be saved: \(error.localizedDescription)"
        }
    }
}

public enum LichessOAuth {
    public static let clientID = "org.libchess.macos"
    public static let callbackScheme = "org.libchess.macos"
    public static let redirectURI = "org.libchess.macos://oauth/lichess"
}

struct BasicCommand: Encodable {
    let version = LIBCHESS_API_VERSION
    let requestID = UUID().uuidString
    let type: String

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case type
    }
}

struct ConnectCommand: Encodable {
    let version = LIBCHESS_API_VERSION
    let requestID = UUID().uuidString
    let type = "connect"
    let provider: String
    let accessToken: String

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case type
        case provider
        case accessToken = "access_token"
    }
}

struct BeginOAuthCommand: Encodable {
    let version = LIBCHESS_API_VERSION
    let requestID = UUID().uuidString
    let type = "begin_oauth"
    let provider: String
    let clientID: String
    let redirectURI: String

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case type
        case provider
        case clientID = "client_id"
        case redirectURI = "redirect_uri"
    }
}

struct CompleteOAuthCommand: Encodable {
    let version = LIBCHESS_API_VERSION
    let requestID = UUID().uuidString
    let type = "complete_oauth"
    let callbackURL: String

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case type
        case callbackURL = "callback_url"
    }
}
