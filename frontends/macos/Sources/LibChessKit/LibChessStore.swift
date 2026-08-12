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
    @Published public private(set) var createdBotGame: BotGame?
    @Published public private(set) var gameURLToOpen: URL?
    @Published public private(set) var isCreatingBotGame = false
    @Published public var message: String?

    private let decoder: JSONDecoder
    private let tokenStore = KeychainTokenStore()
    private var nativeClient: NativeClient?
    private var pendingBotGameRequestID: String?

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

    public var connectedProvider: ProviderDescriptor? {
        guard let provider = account?.provider else {
            return nil
        }
        return providers.first(where: { $0.id == provider })
    }

    public var supportsBotGames: Bool {
        guard let descriptor = connectedProvider else {
            return false
        }
        return descriptor.capabilities.contains(.botGames)
            && !descriptor.botOpponents.isEmpty
            && descriptor.botGameOptions != nil
    }

    public var botOpponents: [BotOpponent] {
        connectedProvider?.botOpponents ?? []
    }

    public var botGameOptions: BotGameOptions? {
        connectedProvider?.botGameOptions
    }

    public var botVariants: [GameVariant] {
        botGameOptions?.variants ?? []
    }

    public func createBotGame(
        opponentID: String,
        variantID: String,
        timeControl: BotGameTimeControl,
        color: GameColorPreference,
        initialFEN: String?
    ) {
        guard !isCreatingBotGame else {
            return
        }
        let normalizedFEN = initialFEN?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        guard botOpponents.contains(where: { $0.id == opponentID }),
              let options = botGameOptions,
              let variant = options.variants.first(where: { $0.id == variantID }),
              options.colors.contains(color),
              supports(timeControl, using: options),
              customPositionIsValid(normalizedFEN, for: variant)
        else {
            message = "Choose settings advertised by the connected chess provider."
            return
        }

        message = nil
        createdBotGame = nil
        gameURLToOpen = nil
        isCreatingBotGame = true
        let command = CreateBotGameCommand(
            opponentID: opponentID,
            variantID: variantID,
            timeControl: timeControl,
            color: color,
            initialFEN: normalizedFEN
        )
        pendingBotGameRequestID = command.requestID
        let sent = send(command)
        if !sent {
            isCreatingBotGame = false
            pendingBotGameRequestID = nil
        }
    }

    public func didOpenCreatedGame() {
        gameURLToOpen = nil
    }

    public func disconnect(forgetCredential: Bool = false) {
        send(BasicCommand(type: "disconnect"))
        account = nil
        authorizationURL = nil
        createdBotGame = nil
        gameURLToOpen = nil
        isCreatingBotGame = false
        pendingBotGameRequestID = nil

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

    @discardableResult
    private func send<Command: Encodable>(_ command: Command) -> Bool {
        do {
            guard let nativeClient else {
                throw NativeClientError.couldNotCreate
            }
            try nativeClient.send(command)
            return true
        } catch {
            message = error.localizedDescription
            return false
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
            case "bot_game_created":
                receiveBotGame(event.game, requestID: event.requestID)
            case "error":
                if event.requestID == pendingBotGameRequestID {
                    isCreatingBotGame = false
                    pendingBotGameRequestID = nil
                }
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

    private func receiveBotGame(_ game: BotGame?, requestID: String?) {
        guard let pendingBotGameRequestID,
              requestID == pendingBotGameRequestID
        else {
            return
        }
        self.pendingBotGameRequestID = nil

        guard let game,
              let provider = connectedProvider,
              let options = provider.botGameOptions,
              game.provider == provider.id,
              botOpponents.contains(game.opponent),
              options.variants.contains(game.variant),
              supports(game.timeControl, using: options),
              customPositionIsValid(game.initialFEN, for: game.variant),
              game.id.utf8.count == 8,
              game.id.utf8.allSatisfy({ byte in
                  (48 ... 57).contains(byte)
                      || (65 ... 90).contains(byte)
                      || (97 ... 122).contains(byte)
              }),
              let url = URL(string: game.url),
              let providerWebURLValue = provider.webURL,
              let providerWebURL = URL(string: providerWebURLValue),
              providerWebURL.scheme?.lowercased() == "https",
              url.scheme?.lowercased() == providerWebURL.scheme?.lowercased(),
              url.host?.lowercased() == providerWebURL.host?.lowercased(),
              url.port == providerWebURL.port,
              url.user == nil,
              url.password == nil
        else {
            isCreatingBotGame = false
            message = "LibChess returned an invalid bot game destination."
            return
        }

        isCreatingBotGame = false
        createdBotGame = game
        gameURLToOpen = url
    }

    private func supports(_ timeControl: BotGameTimeControl, using options: BotGameOptions) -> Bool {
        switch timeControl {
        case let .clock(initialSeconds, incrementSeconds):
            guard let clock = options.clock,
                  clock.initialSeconds.contains(initialSeconds),
                  clock.incrementSeconds.contains(incrementSeconds)
            else {
                return false
            }
            let estimatedDuration = UInt64(initialSeconds) + UInt64(incrementSeconds) * 40
            return clock.minimumEstimatedDurationSeconds.map {
                estimatedDuration >= UInt64($0)
            } ?? true
        case let .correspondence(daysPerMove):
            return options.correspondenceDays.contains(daysPerMove)
        case .unlimited:
            return options.unlimited
        }
    }

    private func customPositionIsValid(_ fen: String?, for variant: GameVariant) -> Bool {
        if variant.requiresCustomPosition && fen == nil {
            return false
        }
        guard let fen else {
            return true
        }
        return variant.supportsCustomPosition
            && fen.utf8.count <= 1_024
            && fen.unicodeScalars.allSatisfy { (32 ... 126).contains($0.value) }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
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

struct CreateBotGameCommand: Encodable {
    let version = LIBCHESS_API_VERSION
    let requestID: String
    let type = "create_bot_game"
    let opponentID: String
    let variantID: String
    let timeControl: BotGameTimeControl
    let color: GameColorPreference
    let initialFEN: String?

    init(
        requestID: String = UUID().uuidString,
        opponentID: String,
        variantID: String,
        timeControl: BotGameTimeControl,
        color: GameColorPreference,
        initialFEN: String?
    ) {
        self.requestID = requestID
        self.opponentID = opponentID
        self.variantID = variantID
        self.timeControl = timeControl
        self.color = color
        self.initialFEN = initialFEN
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case type
        case opponentID = "opponent_id"
        case variantID = "variant_id"
        case timeControl = "time_control"
        case color
        case initialFEN = "initial_fen"
    }
}
