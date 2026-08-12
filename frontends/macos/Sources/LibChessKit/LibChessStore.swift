import Combine
import CLibChess
import Foundation

@MainActor
public final class LibChessStore: ObservableObject {
    @Published public private(set) var providers: [ProviderDescriptor] = []
    @Published public private(set) var account: ChessAccount?
    @Published public private(set) var connectionState = ConnectionState.disconnected
    @Published public private(set) var savedCredentialAvailable = false
    @Published public var message: String?

    private let decoder: JSONDecoder
    private let tokenStore = KeychainTokenStore()
    private var nativeClient: NativeClient?
    private var pendingToken: String?

    public init() {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        self.decoder = decoder

        do {
            savedCredentialAvailable = try tokenStore.load(provider: "lichess") != nil
            nativeClient = try NativeClient { [weak self] data in
                self?.receive(data)
            }
        } catch {
            message = error.localizedDescription
        }
    }

    public func connectToLichess(accessToken: String) {
        let token = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            message = "Enter a Lichess access token."
            return
        }

        pendingToken = token
        message = nil
        send(ConnectCommand(provider: "lichess", accessToken: token))
    }

    public func connectUsingSavedCredential() {
        do {
            guard let token = try tokenStore.load(provider: "lichess") else {
                savedCredentialAvailable = false
                message = "No saved Lichess credential was found."
                return
            }
            connectToLichess(accessToken: token)
        } catch {
            message = error.localizedDescription
        }
    }

    public func refreshAccount() {
        message = nil
        send(BasicCommand(type: "refresh_account"))
    }

    public func disconnect(forgetCredential: Bool = false) {
        send(BasicCommand(type: "disconnect"))
        account = nil
        pendingToken = nil

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
                    pendingToken = nil
                }
            case "account_updated":
                account = event.account
                persistPendingCredential()
            case "error":
                message = event.error?.message ?? "LibChess reported an unknown error."
            default:
                break
            }
        } catch {
            message = "Could not decode a LibChess event: \(error.localizedDescription)"
        }
    }

    private func persistPendingCredential() {
        guard let pendingToken else {
            return
        }
        do {
            try tokenStore.save(pendingToken, provider: "lichess")
            savedCredentialAvailable = true
            self.pendingToken = nil
        } catch {
            message = "Connected, but the credential could not be saved: \(error.localizedDescription)"
        }
    }
}

private struct BasicCommand: Encodable {
    let version = LIBCHESS_API_VERSION
    let requestID = UUID().uuidString
    let type: String
}

private struct ConnectCommand: Encodable {
    let version = LIBCHESS_API_VERSION
    let requestID = UUID().uuidString
    let type = "connect"
    let provider: String
    let accessToken: String
}
