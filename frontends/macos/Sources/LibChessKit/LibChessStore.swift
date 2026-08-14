import Combine
import CLibChess
import Foundation

@MainActor
public final class LibChessStore: ObservableObject {
    @Published public private(set) var providers: [ProviderDescriptor] = []
    @Published public private(set) var selectedBackend: ProviderDescriptor?
    @Published public private(set) var boardProviders: [BoardProviderDescriptor] = []
    @Published public private(set) var boardPresentation: BoardPresentation?
    @Published public private(set) var boardCustomization = BoardCustomizationState.empty
    @Published public private(set) var isLoadingBoardPresentation = false
    @Published public private(set) var isSavingBoardCustomization = false
    @Published public private(set) var account: ChessAccount?
    @Published public private(set) var connectionState = ConnectionState.disconnected
    @Published public private(set) var savedCredentialAvailable = false
    @Published public private(set) var isLoadingSavedCredential = false
    @Published public private(set) var authorizationURL: URL?
    @Published public private(set) var createdBotGames: [String: BotGame] = [:]
    @Published public private(set) var isCreatingBotGame = false
    @Published public private(set) var activeGames: [LiveGameSummary] = []
    @Published public private(set) var liveGames: [String: LiveGame] = [:]
    @Published public private(set) var recentGames: [GameHistoryEntry] = []
    @Published public private(set) var isLoadingGameHistory = false
    @Published public private(set) var nextGameHistoryCursor: UInt64?
    @Published public private(set) var exportedGame: GameExport?
    @Published public private(set) var gameReviews: [String: GameReview] = [:]
    @Published public private(set) var reviewBoards: [String: BoardState] = [:]
    @Published private var loadingGameReviewIDs: Set<String> = []
    @Published private var loadingReviewPositionIDs: Set<String> = []
    @Published public private(set) var focusedGameID: String?
    @Published public private(set) var predictedBoards: [String: BoardState] = [:]
    @Published private var liveGameReceivedDates: [String: Date] = [:]
    @Published private var chatMessagesByGame: [String: [LiveChatMessage]] = [:]
    @Published private var loadingGameIDs: Set<String> = []
    @Published private var connectedGameIDs: Set<String> = []
    @Published private var submittingMoveGameIDs: Set<String> = []
    @Published private var performingActionGameIDs: Set<String> = []
    @Published public var message: String?

    private let decoder: JSONDecoder
    private let tokenStore = KeychainTokenStore()
    private var nativeClient: NativeClient?
    private var pendingBotGameRequestID: String?
    private var pendingBoardPresentationRequestID: String?
    private var pendingBoardCustomizationRequestID: String?
    private var pendingBoardCustomizationAction: PendingBoardCustomizationAction?
    private var pendingLiveGameRequests: [String: String] = [:]
    private var pendingMoveRequests: [String: PendingMove] = [:]
    private var pendingMoveRequestByGame: [String: String] = [:]
    private var pendingGameActionRequests: [String: String] = [:]
    private var pendingGameActionRequestByGame: [String: String] = [:]
    private var predictions: [String: MovePrediction] = [:]
    private var pendingGameHistoryRequest: PendingGameHistoryRequest?
    private var pendingGameExportRequests: [String: String] = [:]
    private var pendingGameReviewRequests: [String: String] = [:]
    private var pendingReviewPositionRequests: [String: PendingReviewPosition] = [:]
    private var pendingReviewPositionRequestByGame: [String: String] = [:]
    private var catalogWatchStarted = false
    private var catalogWatchRequestID: String?
    private var liveGamesRefreshTask: Task<Void, Never>?
    private var catalogReconnectTask: Task<Void, Never>?
    private var boardCustomizationSaveTask: Task<Void, Never>?

    public init() {
        decoder = JSONDecoder()

        do {
            nativeClient = try NativeClient { [weak self] data in
                self?.receive(data)
            }
        } catch {
            message = error.localizedDescription
        }
    }

    public func refreshSavedCredentialAvailability() {
        guard let provider = selectedBackend,
              provider.connection.usesOAuthPKCE
        else {
            savedCredentialAvailable = false
            return
        }
        let tokenStore = tokenStore
        Task { [weak self] in
            do {
                let isAvailable = try await Task.detached(priority: .utility) {
                    try tokenStore.contains(provider: provider.id)
                }.value
                self?.savedCredentialAvailable = isAvailable
            } catch {
                self?.message = error.localizedDescription
            }
        }
    }

    public func beginOAuth() {
        guard selectedBackend?.connection.usesOAuthPKCE == true else {
            return
        }
        message = nil
        send(BasicCommand(type: "begin_oauth"))
    }

    public func connectUsingSavedCredential() {
        guard !isLoadingSavedCredential,
              let provider = selectedBackend,
              provider.connection.usesOAuthPKCE
        else {
            return
        }
        isLoadingSavedCredential = true
        let tokenStore = tokenStore
        Task { [weak self] in
            defer { self?.isLoadingSavedCredential = false }
            do {
                let token = try await Task.detached(priority: .userInitiated) {
                    try tokenStore.load(provider: provider.id)
                }.value
                guard let self else {
                    return
                }
                guard let token else {
                    savedCredentialAvailable = false
                    message = "No saved \(provider.displayName) credential was found."
                    return
                }
                message = nil
                send(ConnectCommand(provider: provider.id, accessToken: token))
            } catch {
                self?.message = error.localizedDescription
            }
        }
    }

    @discardableResult
    public func handleOpenURL(_ url: URL) -> Bool {
        guard connectionState == .authorizing,
              let redirect = selectedBackend?.connection.redirectURI,
              let expected = URL(string: redirect),
              url.scheme?.lowercased() == expected.scheme?.lowercased(),
              url.host?.lowercased() == expected.host?.lowercased(),
              url.path == expected.path
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
        guard let selectedBackend,
              account?.provider == selectedBackend.id
        else {
            return nil
        }
        return selectedBackend
    }

    public func selectBackend(_ backend: ProviderDescriptor) {
        guard backend.available, selectedBackend?.id != backend.id else {
            return
        }
        message = nil
        send(SelectBackendCommand(backend: backend.id))
    }

    public func clearBackendSelection() {
        send(BasicCommand(type: "clear_backend_selection"))
        selectedBackend = nil
        savedCredentialAvailable = false
        resetSessionState()
    }

    public var supportsBotGames: Bool {
        guard let descriptor = connectedProvider else {
            return false
        }
        return descriptor.capabilities.contains(.botGames)
            && !descriptor.botOpponents.isEmpty
            && descriptor.botGameOptions != nil
    }

    public var supportsGameHistory: Bool {
        connectedProvider?.capabilities.contains(.gameHistory) == true
    }

    public var supportsGameReview: Bool {
        connectedProvider?.capabilities.contains(.gameReview) == true
    }

    public var supportsPGNExport: Bool {
        connectedProvider?.capabilities.contains(.pgnExport) == true
    }

    public var botOpponents: [BotOpponent] {
        connectedProvider?.botOpponents ?? []
    }

    public var botGameOptions: BotGameOptions? {
        connectedProvider?.botGameOptions
    }

    public func selectBoardPresentation(
        provider: String,
        boardTheme: String,
        pieceTheme: String
    ) {
        guard boardProviders.contains(where: {
            $0.id == provider
                && $0.boardThemes.contains(where: { $0.id == boardTheme })
                && $0.pieceThemes.contains(where: { $0.id == pieceTheme })
        }) else {
            message = "The selected board or piece theme is not advertised by LibChess."
            return
        }

        if boardPresentation?.provider == provider,
           boardPresentation?.boardTheme == boardTheme,
           boardPresentation?.pieceTheme == pieceTheme
        {
            persistBoardPresentation(
                provider: provider,
                boardTheme: boardTheme,
                pieceTheme: pieceTheme
            )
            return
        }

        let command = LoadBoardPresentationCommand(
            provider: provider,
            boardTheme: boardTheme,
            pieceTheme: pieceTheme
        )
        pendingBoardPresentationRequestID = command.requestID
        isLoadingBoardPresentation = true
        if !send(command) {
            pendingBoardPresentationRequestID = nil
            isLoadingBoardPresentation = false
        }
    }

    public func registerCustomBoardTheme(_ theme: CustomBoardTheme) {
        let command = RegisterCustomBoardThemeCommand(theme: theme)
        beginBoardCustomizationRequest(
            command,
            action: .selectBoard(provider: theme.provider, theme: theme.id)
        )
    }

    public func registerCustomPieceTheme(_ theme: CustomPieceTheme) {
        let command = RegisterCustomPieceThemeCommand(theme: theme)
        beginBoardCustomizationRequest(
            command,
            action: .selectPieces(provider: theme.provider, theme: theme.id)
        )
    }

    public func removeCustomBoardTheme(provider: String, theme: String) {
        let command = RemoveCustomBoardThemeCommand(provider: provider, theme: theme)
        beginBoardCustomizationRequest(
            command,
            action: .removeBoard(provider: provider, theme: theme)
        )
    }

    public func removeCustomPieceTheme(provider: String, theme: String) {
        let command = RemoveCustomPieceThemeCommand(provider: provider, theme: theme)
        beginBoardCustomizationRequest(
            command,
            action: .removePieces(provider: provider, theme: theme)
        )
    }

    public var botVariants: [GameVariant] {
        botGameOptions?.variants ?? []
    }

    public func liveGame(_ gameID: String) -> LiveGame? {
        liveGames[gameID]
    }

    public func displayedBoard(for game: LiveGame) -> BoardState {
        predictedBoards[game.id] ?? game.state.board
    }

    public func liveGameReceivedAt(_ gameID: String) -> Date? {
        liveGameReceivedDates[gameID]
    }

    public func liveChatMessages(_ gameID: String) -> [LiveChatMessage] {
        chatMessagesByGame[gameID] ?? []
    }

    public func isLoadingLiveGame(_ gameID: String) -> Bool {
        loadingGameIDs.contains(gameID)
    }

    public func isLiveStreamConnected(_ gameID: String) -> Bool {
        connectedGameIDs.contains(gameID)
    }

    public func isSubmittingMove(_ gameID: String) -> Bool {
        submittingMoveGameIDs.contains(gameID)
    }

    public func isPerformingGameAction(_ gameID: String) -> Bool {
        performingActionGameIDs.contains(gameID)
    }

    public func openLiveGame(_ gameID: String) {
        guard let summary = activeGames.first(where: { $0.id == gameID }) else {
            return
        }
        focusedGameID = gameID
        guard !connectedGameIDs.contains(gameID), !loadingGameIDs.contains(gameID) else {
            return
        }
        startLiveGame(summary, preservingSnapshot: liveGames[gameID] != nil)
    }

    public func refreshLiveGames() {
        guard connectionState == .connected else {
            return
        }
        send(BasicCommand(type: "refresh_live_games"))
    }

    public func refreshGameHistory() {
        requestGameHistory(beforeMillis: nil)
    }

    public func loadMoreGameHistory() {
        guard let nextGameHistoryCursor else {
            return
        }
        requestGameHistory(beforeMillis: nextGameHistoryCursor)
    }

    public func exportGame(_ gameID: String) {
        guard connectionState == .connected,
              supportsPGNExport,
              pendingGameExportRequests.values.contains(gameID) == false,
              recentGames.contains(where: { $0.id == gameID })
                  || activeGames.contains(where: { $0.id == gameID })
        else {
            return
        }
        let command = ExportGameCommand(gameID: gameID)
        pendingGameExportRequests[command.requestID] = gameID
        message = nil
        if !send(command) {
            pendingGameExportRequests.removeValue(forKey: command.requestID)
        }
    }

    public func isExportingGame(_ gameID: String) -> Bool {
        pendingGameExportRequests.values.contains(gameID)
    }

    public func loadGameReview(_ gameID: String, reload: Bool = false) {
        guard connectionState == .connected,
              supportsGameReview,
              recentGames.contains(where: { $0.id == gameID }),
              !loadingGameReviewIDs.contains(gameID),
              reload || gameReviews[gameID] == nil
        else {
            return
        }
        let command = LoadGameReviewCommand(gameID: gameID)
        pendingGameReviewRequests[command.requestID] = gameID
        loadingGameReviewIDs.insert(gameID)
        message = nil
        if !send(command) {
            pendingGameReviewRequests.removeValue(forKey: command.requestID)
            loadingGameReviewIDs.remove(gameID)
        }
    }

    public func showGameReviewPosition(_ gameID: String, ply: UInt32) {
        guard let review = gameReviews[gameID],
              ply <= UInt32(review.moves.count)
        else {
            return
        }
        if reviewBoards[gameID]?.ply == ply {
            return
        }
        if let previousRequestID = pendingReviewPositionRequestByGame[gameID] {
            pendingReviewPositionRequests.removeValue(forKey: previousRequestID)
        }
        let command = ShowGameReviewPositionCommand(gameID: gameID, ply: ply)
        pendingReviewPositionRequests[command.requestID] = PendingReviewPosition(
            gameID: gameID,
            ply: ply
        )
        pendingReviewPositionRequestByGame[gameID] = command.requestID
        loadingReviewPositionIDs.insert(gameID)
        if !send(command) {
            clearPendingReviewPosition(requestID: command.requestID)
        }
    }

    public func isLoadingGameReview(_ gameID: String) -> Bool {
        loadingGameReviewIDs.contains(gameID)
    }

    public func isLoadingReviewPosition(_ gameID: String) -> Bool {
        loadingReviewPositionIDs.contains(gameID)
    }

    public func consumeExportedGame() {
        exportedGame = nil
    }

    public func createBotGame(
        opponentID: String,
        variantID: String,
        timeControl: BotGameTimeControl,
        color: GameColorPreference,
        initialFEN: String?,
        initialMoves: [String] = [],
        replyDelayMillis: UInt32? = nil
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
              supports(replyDelayMillis, using: options),
              customPositionIsValid(normalizedFEN, for: variant),
              moveHistoryIsValid(initialMoves, initialFEN: normalizedFEN, for: variant)
        else {
            message = "Choose settings advertised by the connected chess provider."
            return
        }

        message = nil
        isCreatingBotGame = true
        let command = CreateBotGameCommand(
            opponentID: opponentID,
            variantID: variantID,
            timeControl: timeControl,
            color: color,
            initialFEN: normalizedFEN,
            initialMoves: initialMoves,
            replyDelayMillis: replyDelayMillis
        )
        pendingBotGameRequestID = command.requestID
        let sent = send(command)
        if !sent {
            isCreatingBotGame = false
            pendingBotGameRequestID = nil
        }
    }

    public func playMove(_ move: LegalMove, in gameID: String, offerDraw: Bool = false) {
        guard let game = liveGames[gameID],
              game.state.isPlayable,
              displayedBoard(for: game).turn == game.playerColor,
              displayedBoard(for: game).legalMoves.contains(move),
              !submittingMoveGameIDs.contains(gameID),
              !performingActionGameIDs.contains(gameID)
        else {
            return
        }
        let command = PlayMoveCommand(
            gameID: game.id,
            moveID: move.id,
            offerDraw: offerDraw
        )
        let pending = PendingMove(
            requestID: command.requestID,
            gameID: gameID,
            moveID: move.id,
            baseMoves: game.state.board.moves
        )
        pendingMoveRequests[command.requestID] = pending
        pendingMoveRequestByGame[gameID] = command.requestID
        submittingMoveGameIDs.insert(gameID)
        message = nil
        if !send(command) {
            clearPendingMove(requestID: command.requestID, rollback: true)
        }
    }

    public func performGameAction(_ action: LiveGameAction, in gameID: String) {
        guard let game = liveGames[gameID],
              game.state.isPlayable,
              !submittingMoveGameIDs.contains(gameID),
              !performingActionGameIDs.contains(gameID)
        else {
            return
        }
        let command = PerformGameActionCommand(gameID: game.id, action: action)
        pendingGameActionRequests[command.requestID] = gameID
        pendingGameActionRequestByGame[gameID] = command.requestID
        performingActionGameIDs.insert(gameID)
        message = nil
        if !send(command) {
            clearPendingGameAction(requestID: command.requestID)
        }
    }

    public func reconnectLiveGame(_ gameID: String) {
        guard let summary = activeGames.first(where: { $0.id == gameID }),
              let game = liveGames[gameID],
              game.state.isPlayable
        else {
            return
        }
        startLiveGame(summary, preservingSnapshot: true)
    }

    public func stopObservingLiveGame(_ gameID: String) {
        if liveGames[gameID] != nil || loadingGameIDs.contains(gameID) {
            send(StopLiveGameCommand(gameID: gameID))
        }
        liveGames.removeValue(forKey: gameID)
        liveGameReceivedDates.removeValue(forKey: gameID)
        chatMessagesByGame.removeValue(forKey: gameID)
        loadingGameIDs.remove(gameID)
        connectedGameIDs.remove(gameID)
        rollbackPrediction(for: gameID)
        if let requestID = pendingMoveRequestByGame[gameID] {
            clearPendingMove(requestID: requestID, rollback: true)
        }
        if let requestID = pendingGameActionRequestByGame[gameID] {
            clearPendingGameAction(requestID: requestID)
        }
        pendingLiveGameRequests = pendingLiveGameRequests.filter { $0.value != gameID }
    }

    public func disconnect(forgetCredential: Bool = false) {
        let credentialProvider = selectedBackend?.connection.usesOAuthPKCE == true
            ? selectedBackend?.id
            : nil
        send(BasicCommand(type: "disconnect"))
        resetSessionState()

        guard forgetCredential, let credentialProvider else {
            return
        }
        savedCredentialAvailable = false
        let tokenStore = tokenStore
        Task { [weak self] in
            do {
                try await Task.detached(priority: .utility) {
                    try tokenStore.delete(provider: credentialProvider)
                }.value
            } catch {
                self?.message = error.localizedDescription
            }
        }
    }

    private func resetSessionState() {
        account = nil
        authorizationURL = nil
        createdBotGames = [:]
        activeGames = []
        liveGames = [:]
        recentGames = []
        isLoadingGameHistory = false
        nextGameHistoryCursor = nil
        exportedGame = nil
        gameReviews = [:]
        reviewBoards = [:]
        loadingGameReviewIDs = []
        loadingReviewPositionIDs = []
        focusedGameID = nil
        predictedBoards = [:]
        liveGameReceivedDates = [:]
        chatMessagesByGame = [:]
        loadingGameIDs = []
        connectedGameIDs = []
        submittingMoveGameIDs = []
        performingActionGameIDs = []
        isCreatingBotGame = false
        isLoadingSavedCredential = false
        pendingBotGameRequestID = nil
        pendingLiveGameRequests = [:]
        pendingMoveRequests = [:]
        pendingMoveRequestByGame = [:]
        pendingGameActionRequests = [:]
        pendingGameActionRequestByGame = [:]
        predictions = [:]
        pendingGameHistoryRequest = nil
        pendingGameExportRequests = [:]
        pendingGameReviewRequests = [:]
        pendingReviewPositionRequests = [:]
        pendingReviewPositionRequestByGame = [:]
        catalogWatchStarted = false
        catalogWatchRequestID = nil
        liveGamesRefreshTask?.cancel()
        liveGamesRefreshTask = nil
        catalogReconnectTask?.cancel()
        catalogReconnectTask = nil
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

    private func beginBoardCustomizationRequest<Command: BoardCustomizationCommand>(
        _ command: Command,
        action: PendingBoardCustomizationAction
    ) {
        guard !isSavingBoardCustomization else {
            return
        }
        message = nil
        pendingBoardCustomizationRequestID = command.requestID
        pendingBoardCustomizationAction = action
        isSavingBoardCustomization = true
        if !send(command) {
            pendingBoardCustomizationRequestID = nil
            pendingBoardCustomizationAction = nil
            isSavingBoardCustomization = false
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
            case "ready":
                providers = event.providers ?? []
                selectedBackend = event.selectedBackend
                receiveBoardCatalog(event)
                boardCustomization = event.boardCustomization ?? .empty
                beginSavedBoardCustomizationRestore()
            case "providers":
                providers = event.providers ?? []
            case "backend_selection_changed":
                resetSessionState()
                selectedBackend = event.backend
                refreshSavedCredentialAvailability()
            case "board_providers":
                receiveBoardCatalog(event)
            case "board_presentation_loaded":
                receiveBoardPresentation(event)
            case "board_customization_changed":
                receiveBoardCustomization(event)
            case "connection_state_changed":
                if let state = event.state {
                    connectionState = state
                }
                if event.state == .connected {
                    beginLiveGameSynchronization()
                }
                if event.state == .disconnected {
                    account = nil
                    authorizationURL = nil
                    catalogWatchStarted = false
                }
            case "account_updated":
                account = event.account
            case "oauth_authorization_required":
                receiveAuthorizationURL(event.authorizationURL)
            case "oauth_credential_issued":
                persistOAuthCredential(event)
            case "bot_game_created":
                receiveBotGame(event.game, requestID: event.requestID)
            case "live_game_updated":
                receiveLiveGame(event.liveGame)
            case "live_games_updated":
                receiveLiveGames(event.games)
            case "game_history_updated":
                receiveGameHistory(event)
            case "game_exported":
                receiveGameExport(event)
            case "game_review_loaded":
                receiveGameReview(event)
            case "game_review_position_updated":
                receiveGameReviewPosition(event)
            case "live_games_changed":
                scheduleLiveGamesRefresh()
            case "live_game_chat":
                receiveChat(event.chat)
            case "live_game_stream_ended":
                if let gameID = event.gameID {
                    loadingGameIDs.remove(gameID)
                    connectedGameIDs.remove(gameID)
                    pendingLiveGameRequests = pendingLiveGameRequests.filter { $0.value != gameID }
                    refreshLiveGames()
                }
            case "move_predicted":
                receiveMovePrediction(event)
            case "move_submitted":
                if let requestID = event.requestID,
                   let pending = pendingMoveRequests[requestID],
                   pending.gameID == event.gameID,
                   pending.moveID == event.moveID
                {
                    clearPendingMove(requestID: requestID, rollback: false)
                }
            case "game_action_completed":
                if let requestID = event.requestID,
                   pendingGameActionRequests[requestID] == event.gameID
                {
                    clearPendingGameAction(requestID: requestID)
                }
            case "error":
                if event.requestID == pendingBotGameRequestID {
                    isCreatingBotGame = false
                    pendingBotGameRequestID = nil
                }
                if event.requestID == pendingBoardPresentationRequestID {
                    pendingBoardPresentationRequestID = nil
                    isLoadingBoardPresentation = false
                }
                if event.requestID == pendingBoardCustomizationRequestID {
                    pendingBoardCustomizationRequestID = nil
                    pendingBoardCustomizationAction = nil
                    isSavingBoardCustomization = false
                }
                if let requestID = event.requestID,
                   let gameID = pendingLiveGameRequests.removeValue(forKey: requestID)
                {
                    loadingGameIDs.remove(gameID)
                    connectedGameIDs.remove(gameID)
                }
                if let requestID = event.requestID,
                   pendingMoveRequests[requestID] != nil
                {
                    clearPendingMove(requestID: requestID, rollback: true)
                }
                if let requestID = event.requestID,
                   pendingGameActionRequests[requestID] != nil
                {
                    clearPendingGameAction(requestID: requestID)
                }
                if event.requestID == pendingGameHistoryRequest?.requestID {
                    pendingGameHistoryRequest = nil
                    isLoadingGameHistory = false
                }
                if let requestID = event.requestID {
                    pendingGameExportRequests.removeValue(forKey: requestID)
                }
                if let requestID = event.requestID,
                   let gameID = pendingGameReviewRequests.removeValue(forKey: requestID)
                {
                    loadingGameReviewIDs.remove(gameID)
                }
                if let requestID = event.requestID,
                   pendingReviewPositionRequests[requestID] != nil
                {
                    clearPendingReviewPosition(requestID: requestID)
                }
                if event.requestID == catalogWatchRequestID {
                    catalogWatchStarted = false
                    catalogWatchRequestID = nil
                    scheduleCatalogReconnect()
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
              let originValue = selectedBackend?.connection.authorizationOrigin,
              let origin = URL(string: originValue),
              url.scheme?.lowercased() == origin.scheme?.lowercased(),
              url.host?.lowercased() == origin.host?.lowercased(),
              url.port == origin.port,
              url.user == nil,
              url.password == nil
        else {
            message = "LibChess returned an invalid authorization URL."
            return
        }
        authorizationURL = url
    }

    private func receiveBoardCatalog(_ event: WireEvent) {
        if let catalog = event.boardProviders {
            boardProviders = catalog
        }
        if let presentation = event.boardPresentation {
            boardPresentation = presentation
            reconcileBoardZoomPreference(with: presentation)
        }
    }

    private func restoreBoardPresentationPreference() {
        guard let boardPresentation else {
            return
        }

        let defaults = UserDefaults.standard
        let provider = defaults.string(forKey: BoardPreferenceKey.provider)
            ?? boardPresentation.provider
        let boardTheme = defaults.string(forKey: BoardPreferenceKey.boardTheme)
            ?? boardPresentation.boardTheme
        let pieceTheme = defaults.string(forKey: BoardPreferenceKey.pieceTheme)
            ?? boardPresentation.pieceTheme
        let preferenceIsValid = boardProviders.contains(where: {
            $0.id == provider
                && $0.boardThemes.contains(where: { $0.id == boardTheme })
                && $0.pieceThemes.contains(where: { $0.id == pieceTheme })
        })
        if preferenceIsValid,
           (provider != boardPresentation.provider
               || boardTheme != boardPresentation.boardTheme
               || pieceTheme != boardPresentation.pieceTheme)
        {
            selectBoardPresentation(
                provider: provider,
                boardTheme: boardTheme,
                pieceTheme: pieceTheme
            )
        } else {
            persistBoardPresentation(
                provider: boardPresentation.provider,
                boardTheme: boardPresentation.boardTheme,
                pieceTheme: boardPresentation.pieceTheme
            )
        }
    }

    private func beginSavedBoardCustomizationRestore() {
        isSavingBoardCustomization = true
        Task { [weak self] in
            do {
                let state = try await Task.detached(priority: .utility) {
                    let data = try BoardCustomizationFileStore().load()
                    guard let data else {
                        return Optional<BoardCustomizationState>.none
                    }
                    let state = try JSONDecoder().decode(BoardCustomizationState.self, from: data)
                    guard state.version == BOARD_CUSTOMIZATION_STATE_VERSION else {
                        throw CocoaError(.coderReadCorrupt)
                    }
                    return state
                }.value
                guard let self else {
                    return
                }
                guard let state else {
                    isSavingBoardCustomization = false
                    restoreBoardPresentationPreference()
                    return
                }

                let command = LoadBoardCustomizationStateCommand(state: state)
                pendingBoardCustomizationRequestID = command.requestID
                pendingBoardCustomizationAction = .restore
                if !send(command) {
                    pendingBoardCustomizationRequestID = nil
                    pendingBoardCustomizationAction = nil
                    isSavingBoardCustomization = false
                    restoreBoardPresentationPreference()
                }
            } catch {
                self?.isSavingBoardCustomization = false
                self?.message = "Saved board customization could not be restored."
                self?.restoreBoardPresentationPreference()
            }
        }
    }

    private func receiveBoardCustomization(_ event: WireEvent) {
        guard let requestID = event.requestID,
              requestID == pendingBoardCustomizationRequestID,
              let customization = event.boardCustomization,
              let catalog = event.boardProviders
        else {
            return
        }

        let action = pendingBoardCustomizationAction
        pendingBoardCustomizationRequestID = nil
        pendingBoardCustomizationAction = nil
        isSavingBoardCustomization = false
        boardCustomization = customization
        boardProviders = catalog
        persistBoardCustomization(customization)

        switch action {
        case let .selectBoard(provider, theme):
            guard let descriptor = catalog.first(where: { $0.id == provider }) else {
                return
            }
            let pieceTheme = boardPresentation?.provider == provider
                && descriptor.pieceThemes.contains(where: {
                    $0.id == boardPresentation?.pieceTheme
                })
                ? boardPresentation?.pieceTheme ?? descriptor.defaultPieceTheme
                : descriptor.defaultPieceTheme
            selectBoardPresentation(
                provider: provider,
                boardTheme: theme,
                pieceTheme: pieceTheme
            )
        case let .selectPieces(provider, theme):
            guard let descriptor = catalog.first(where: { $0.id == provider }) else {
                return
            }
            let boardTheme = boardPresentation?.provider == provider
                && descriptor.boardThemes.contains(where: {
                    $0.id == boardPresentation?.boardTheme
                })
                ? boardPresentation?.boardTheme ?? descriptor.defaultBoardTheme
                : descriptor.defaultBoardTheme
            selectBoardPresentation(
                provider: provider,
                boardTheme: boardTheme,
                pieceTheme: theme
            )
        case let .removeBoard(provider, theme):
            if boardPresentation?.provider == provider,
               boardPresentation?.boardTheme == theme,
               let descriptor = catalog.first(where: { $0.id == provider })
            {
                selectBoardPresentation(
                    provider: provider,
                    boardTheme: descriptor.defaultBoardTheme,
                    pieceTheme: boardPresentation?.pieceTheme ?? descriptor.defaultPieceTheme
                )
            }
        case let .removePieces(provider, theme):
            if boardPresentation?.provider == provider,
               boardPresentation?.pieceTheme == theme,
               let descriptor = catalog.first(where: { $0.id == provider })
            {
                selectBoardPresentation(
                    provider: provider,
                    boardTheme: boardPresentation?.boardTheme ?? descriptor.defaultBoardTheme,
                    pieceTheme: descriptor.defaultPieceTheme
                )
            }
        case .restore:
            restoreBoardPresentationPreference()
        case nil:
            break
        }
    }

    private func persistBoardCustomization(_ customization: BoardCustomizationState) {
        let previousSave = boardCustomizationSaveTask
        boardCustomizationSaveTask = Task { [weak self] in
            await previousSave?.value
            do {
                try await Task.detached(priority: .utility) {
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.sortedKeys]
                    let data = try encoder.encode(customization)
                    try BoardCustomizationFileStore().save(data)
                }.value
            } catch {
                self?.message =
                    "Board customization could not be saved: \(error.localizedDescription)"
            }
        }
    }

    private func receiveBoardPresentation(_ event: WireEvent) {
        guard let requestID = event.requestID,
              requestID == pendingBoardPresentationRequestID,
              let presentation = event.boardPresentation,
              boardProviders.contains(where: {
                  $0.id == presentation.provider
                      && $0.boardThemes.contains(where: {
                          $0.id == presentation.boardTheme
                      })
                      && $0.pieceThemes.contains(where: {
                          $0.id == presentation.pieceTheme
                      })
              })
        else {
            return
        }

        pendingBoardPresentationRequestID = nil
        isLoadingBoardPresentation = false
        boardPresentation = presentation
        reconcileBoardZoomPreference(with: presentation)
        persistBoardPresentation(
            provider: presentation.provider,
            boardTheme: presentation.boardTheme,
            pieceTheme: presentation.pieceTheme
        )
    }

    private func persistBoardPresentation(
        provider: String,
        boardTheme: String,
        pieceTheme: String
    ) {
        let defaults = UserDefaults.standard
        defaults.set(provider, forKey: BoardPreferenceKey.provider)
        defaults.set(boardTheme, forKey: BoardPreferenceKey.boardTheme)
        defaults.set(pieceTheme, forKey: BoardPreferenceKey.pieceTheme)
    }

    private func reconcileBoardZoomPreference(with presentation: BoardPresentation) {
        let defaults = UserDefaults.standard
        let savedID = defaults.string(forKey: BoardPreferenceKey.zoomPreset) ?? ""
        guard presentation.zoom.preset(id: savedID) == nil,
              let fallback = presentation.zoom.defaultValue ?? presentation.zoom.presets.first
        else {
            return
        }
        defaults.set(fallback.id, forKey: BoardPreferenceKey.zoomPreset)
    }

    private func persistOAuthCredential(_ event: WireEvent) {
        guard let token = event.accessToken,
              !token.isEmpty,
              token.count <= 4096,
              let provider = event.provider,
              provider == selectedBackend?.id
        else {
            message = "The selected backend returned an invalid OAuth credential."
            return
        }
        let tokenStore = tokenStore
        Task { [weak self] in
            do {
                try await Task.detached(priority: .utility) {
                    try tokenStore.save(token, provider: provider)
                }.value
                self?.savedCredentialAvailable = true
            } catch {
                self?.message =
                    "Connected, but the credential could not be saved: \(error.localizedDescription)"
            }
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
              !game.speed.isEmpty,
              game.speed.utf8.count <= 64,
              Self.gameIDIsValid(game.id),
              Self.backendResourceURLIsValid(game.url, for: provider)
        else {
            isCreatingBotGame = false
            message = "LibChess returned an invalid bot game destination."
            return
        }

        isCreatingBotGame = false
        createdBotGames[game.id] = game
        let summary = LiveGameSummary(
            provider: game.provider,
            id: game.id,
            url: game.url,
            playerColor: game.playerColor,
            displayName: game.opponent.displayName,
            variantID: game.variant.id,
            variantName: game.variant.displayName,
            rated: false,
            speed: game.speed,
            isMyTurn: game.isMyTurn
        )
        upsertActiveGame(summary, atFront: true)
        focusedGameID = game.id
        startLiveGame(summary, preservingSnapshot: false)
        refreshLiveGames()
    }

    private func startLiveGame(_ game: LiveGameSummary, preservingSnapshot: Bool) {
        let command = StartLiveGameCommand(
            gameID: game.id,
            playerColor: game.playerColor
        )
        if !preservingSnapshot {
            liveGames.removeValue(forKey: game.id)
            liveGameReceivedDates.removeValue(forKey: game.id)
            chatMessagesByGame[game.id] = []
        }
        loadingGameIDs.insert(game.id)
        connectedGameIDs.remove(game.id)
        pendingLiveGameRequests[command.requestID] = game.id
        if !send(command) {
            loadingGameIDs.remove(game.id)
            pendingLiveGameRequests.removeValue(forKey: command.requestID)
        }
    }

    private func receiveLiveGame(_ game: LiveGame?) {
        guard let game,
              let provider = connectedProvider,
              game.provider == provider.id,
              activeGames.contains(where: {
                  $0.id == game.id && $0.playerColor == game.playerColor
              }) || createdBotGames[game.id]?.playerColor == game.playerColor,
              liveGameIsValid(game)
        else {
            if let gameID = game?.id {
                loadingGameIDs.remove(gameID)
            }
            message = "LibChess returned an invalid live-game position."
            return
        }

        reconcilePrediction(with: game)
        liveGames[game.id] = game
        liveGameReceivedDates[game.id] = Date()
        loadingGameIDs.remove(game.id)
        connectedGameIDs.insert(game.id)
        pendingLiveGameRequests = pendingLiveGameRequests.filter { $0.value != game.id }
        upsertActiveGame(summary(for: game), atFront: false)
        if !game.state.isPlayable {
            rollbackPrediction(for: game.id)
            if let requestID = pendingMoveRequestByGame[game.id] {
                clearPendingMove(requestID: requestID, rollback: true)
            }
            if let requestID = pendingGameActionRequestByGame[game.id] {
                clearPendingGameAction(requestID: requestID)
            }
        }
    }

    private func receiveChat(_ chat: LiveChatMessage?) {
        guard let chat, liveGames[chat.gameID] != nil else {
            return
        }
        var messages = chatMessagesByGame[chat.gameID] ?? []
        messages.append(chat)
        if messages.count > 100 {
            messages.removeFirst(messages.count - 100)
        }
        chatMessagesByGame[chat.gameID] = messages
    }

    private func beginLiveGameSynchronization() {
        refreshLiveGames()
        guard !catalogWatchStarted else {
            return
        }
        let command = BasicCommand(type: "watch_live_games")
        if send(command) {
            catalogWatchStarted = true
            catalogWatchRequestID = command.requestID
        }
    }

    private func scheduleLiveGamesRefresh() {
        liveGamesRefreshTask?.cancel()
        liveGamesRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else {
                return
            }
            self?.refreshLiveGames()
        }
    }

    private func scheduleCatalogReconnect() {
        catalogReconnectTask?.cancel()
        catalogReconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, self?.connectionState == .connected else {
                return
            }
            self?.beginLiveGameSynchronization()
        }
    }

    private func receiveLiveGames(_ games: [LiveGameSummary]?) {
        guard let games, games.allSatisfy(liveGameSummaryIsValid) else {
            message = "LibChess returned an invalid ongoing-game list."
            return
        }

        var merged = games
        let listedIDs = Set(games.map(\.id))
        for game in liveGames.values where game.state.isPlayable && !listedIDs.contains(game.id) {
            merged.append(summary(for: game))
        }
        for game in createdBotGames.values where !listedIDs.contains(game.id)
            && !merged.contains(where: { $0.id == game.id })
        {
            merged.append(
                LiveGameSummary(
                    provider: game.provider,
                    id: game.id,
                    url: game.url,
                    playerColor: game.playerColor,
                    displayName: game.opponent.displayName,
                    variantID: game.variant.id,
                    variantName: game.variant.displayName,
                    rated: false,
                    speed: game.speed,
                    isMyTurn: game.isMyTurn
                )
            )
        }
        activeGames = merged
    }

    private func requestGameHistory(beforeMillis: UInt64?) {
        guard connectionState == .connected,
              connectedProvider?.capabilities.contains(.gameHistory) == true,
              pendingGameHistoryRequest == nil
        else {
            return
        }
        let command = RefreshGameHistoryCommand(beforeMillis: beforeMillis, limit: 20)
        pendingGameHistoryRequest = PendingGameHistoryRequest(
            requestID: command.requestID,
            beforeMillis: beforeMillis
        )
        isLoadingGameHistory = true
        message = nil
        if !send(command) {
            pendingGameHistoryRequest = nil
            isLoadingGameHistory = false
        }
    }

    private func receiveGameHistory(_ event: WireEvent) {
        guard let pending = pendingGameHistoryRequest,
              event.requestID == pending.requestID
        else {
            return
        }
        pendingGameHistoryRequest = nil
        isLoadingGameHistory = false

        guard event.append == (pending.beforeMillis != nil),
              let page = event.page,
              page.games.count <= 20,
              page.games.allSatisfy(gameHistoryEntryIsValid),
              Set(page.games.map(\.id)).count == page.games.count,
              zip(page.games, page.games.dropFirst()).allSatisfy({ pair in
                  pair.0.createdAtMillis >= pair.1.createdAtMillis
              }),
              page.nextBeforeMillis.map({ cursor in
                  page.games.last.map { cursor < $0.createdAtMillis } ?? false
              }) ?? true
        else {
            message = "LibChess returned an invalid game-history page."
            return
        }
        nextGameHistoryCursor = page.nextBeforeMillis
        if pending.beforeMillis == nil {
            recentGames = page.games
            return
        }
        let existingIDs = Set(recentGames.map(\.id))
        recentGames.append(contentsOf: page.games.filter { !existingIDs.contains($0.id) })
    }

    private func receiveGameExport(_ event: WireEvent) {
        guard let requestID = event.requestID,
              let expectedGameID = pendingGameExportRequests.removeValue(forKey: requestID),
              let export = event.gameExport,
              export.gameID == expectedGameID,
              export.provider == connectedProvider?.id,
              export.suggestedFilename.utf8.count <= 128,
              export.suggestedFilename.hasSuffix(".pgn"),
              !export.suggestedFilename.contains("/"),
              !export.suggestedFilename.contains("\\"),
              !export.pgn.isEmpty,
              export.pgn.utf8.count <= 8 * 1_024 * 1_024,
              !export.pgn.contains("\0")
        else {
            message = "LibChess returned an invalid game export."
            return
        }
        exportedGame = export
    }

    private func receiveGameReview(_ event: WireEvent) {
        guard let requestID = event.requestID,
              let expectedGameID = pendingGameReviewRequests.removeValue(forKey: requestID)
        else {
            return
        }
        loadingGameReviewIDs.remove(expectedGameID)

        guard let review = event.review,
              review.gameID == expectedGameID,
              gameReviewIsValid(review),
              let board = event.board,
              board.ply == UInt32(review.moves.count),
              board.moves == review.moves.map(\.moveID),
              boardStateIsValid(board)
        else {
            message = "LibChess returned an invalid game review."
            return
        }
        gameReviews[expectedGameID] = review
        reviewBoards[expectedGameID] = board
    }

    private func receiveGameReviewPosition(_ event: WireEvent) {
        guard let requestID = event.requestID,
              let pending = pendingReviewPositionRequests[requestID],
              pendingReviewPositionRequestByGame[pending.gameID] == requestID,
              event.gameID == pending.gameID,
              let review = gameReviews[pending.gameID],
              let board = event.board,
              event.board?.ply == pending.ply,
              event.board?.moves == review.moves.prefix(Int(pending.ply)).map(\.moveID),
              boardStateIsValid(board)
        else {
            if let requestID = event.requestID {
                clearPendingReviewPosition(requestID: requestID)
            }
            return
        }
        reviewBoards[pending.gameID] = board
        clearPendingReviewPosition(requestID: requestID)
    }

    private func clearPendingReviewPosition(requestID: String) {
        guard let pending = pendingReviewPositionRequests.removeValue(forKey: requestID) else {
            return
        }
        if pendingReviewPositionRequestByGame[pending.gameID] == requestID {
            pendingReviewPositionRequestByGame.removeValue(forKey: pending.gameID)
            loadingReviewPositionIDs.remove(pending.gameID)
        }
    }

    private func receiveMovePrediction(_ event: WireEvent) {
        guard let requestID = event.requestID,
              let pending = pendingMoveRequests[requestID],
              pending.gameID == event.gameID,
              pending.moveID == event.moveID,
              let board = event.board,
              board.moves == pending.baseMoves + [pending.moveID],
              board.ply == UInt32(pending.baseMoves.count + 1),
              boardStateIsValid(board)
        else {
            return
        }
        predictions[pending.gameID] = MovePrediction(
            requestID: requestID,
            moveID: pending.moveID,
            baseMoves: pending.baseMoves
        )
        predictedBoards[pending.gameID] = board
    }

    private func reconcilePrediction(with game: LiveGame) {
        guard let prediction = predictions[game.id] else {
            return
        }
        let authoritativeMoves = game.state.board.moves
        guard authoritativeMoves.count > prediction.baseMoves.count || !game.state.isPlayable else {
            return
        }
        rollbackPrediction(for: game.id)
    }

    private func rollbackPrediction(for gameID: String) {
        predictions.removeValue(forKey: gameID)
        predictedBoards.removeValue(forKey: gameID)
    }

    private func clearPendingMove(requestID: String, rollback: Bool) {
        guard let pending = pendingMoveRequests.removeValue(forKey: requestID) else {
            return
        }
        if pendingMoveRequestByGame[pending.gameID] == requestID {
            pendingMoveRequestByGame.removeValue(forKey: pending.gameID)
            submittingMoveGameIDs.remove(pending.gameID)
        }
        if rollback {
            rollbackPrediction(for: pending.gameID)
        }
    }

    private func clearPendingGameAction(requestID: String) {
        guard let gameID = pendingGameActionRequests.removeValue(forKey: requestID) else {
            return
        }
        if pendingGameActionRequestByGame[gameID] == requestID {
            pendingGameActionRequestByGame.removeValue(forKey: gameID)
            performingActionGameIDs.remove(gameID)
        }
    }

    private func upsertActiveGame(_ game: LiveGameSummary, atFront: Bool) {
        activeGames.removeAll(where: { $0.id == game.id })
        if atFront {
            activeGames.insert(game, at: 0)
        } else {
            activeGames.append(game)
        }
    }

    private func summary(for game: LiveGame) -> LiveGameSummary {
        let opponent = game.playerColor == .white ? game.black : game.white
        return LiveGameSummary(
            provider: game.provider,
            id: game.id,
            url: game.url,
            playerColor: game.playerColor,
            displayName: opponent.displayName,
            variantID: game.variantID,
            variantName: game.variantName,
            rated: game.rated,
            speed: game.speed,
            isMyTurn: game.state.board.turn == game.playerColor && game.state.isPlayable
        )
    }

    private func liveGameIsValid(_ game: LiveGame) -> Bool {
        guard boardStateIsValid(game.state.board),
              !game.initialFEN.isEmpty,
              game.initialFEN.utf8.count <= 4_096,
              game.initialFEN.unicodeScalars.allSatisfy({ (32 ... 126).contains($0.value) }),
              let provider = connectedProvider,
              Self.backendResourceURLIsValid(game.url, for: provider)
        else {
            return false
        }
        return true
    }

    private func boardStateIsValid(_ board: BoardState) -> Bool {
        let pieces = board.pieces
        let occupiedSquares = Set(pieces.map(\.square))
        guard occupiedSquares.count == pieces.count,
              pieces.allSatisfy({ Self.isBoardSquare($0.square) }),
              board.legalMoves.allSatisfy({ move in
                  Self.isBoardSquare(move.to)
                      && (move.from.map(Self.isBoardSquare) ?? true)
                      && !move.id.isEmpty
                      && move.id.utf8.count <= 16
              })
        else {
            return false
        }
        return true
    }

    private func liveGameSummaryIsValid(_ game: LiveGameSummary) -> Bool {
        guard let provider = connectedProvider else {
            return false
        }
        return game.provider == provider.id
            && Self.gameIDIsValid(game.id)
            && !game.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && game.displayName.utf8.count <= 128
            && Self.backendResourceURLIsValid(game.url, for: provider)
    }

    private func gameHistoryEntryIsValid(_ game: GameHistoryEntry) -> Bool {
        guard let provider = connectedProvider else {
            return false
        }
        return game.provider == provider.id
            && Self.gameIDIsValid(game.id)
            && !game.opponentName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && game.opponentName.utf8.count <= 128
            && !game.variantName.isEmpty
            && game.variantName.utf8.count <= 128
            && game.lastMoveAtMillis >= game.createdAtMillis
            && Self.backendResourceURLIsValid(game.url, for: provider)
            && Self.backendResourceURLIsValid(game.analysisURL, for: provider)
    }

    private func gameReviewIsValid(_ review: GameReview) -> Bool {
        guard review.provider == connectedProvider?.id,
              let history = recentGames.first(where: { $0.id == review.gameID }),
              review.variantID == history.variantID,
              !review.initialFEN.isEmpty,
              review.initialFEN.utf8.count <= 4_096,
              review.initialFEN.unicodeScalars.allSatisfy({ (32 ... 126).contains($0.value) }),
              review.moves.count <= 2_048
        else {
            return false
        }
        return review.moves.enumerated().allSatisfy { index, move in
            move.ply == UInt32(index + 1)
                && !move.san.isEmpty
                && move.san.utf8.count <= 32
                && !move.moveID.isEmpty
                && move.moveID.utf8.count <= 16
                && move.evaluation.map(gameMoveEvaluationIsValid) ?? true
        }
    }

    private func gameMoveEvaluationIsValid(_ evaluation: GameMoveEvaluation) -> Bool {
        (evaluation.bestMove?.utf8.count ?? 0) <= 16
            && (evaluation.variation?.utf8.count ?? 0) <= 4_096
            && (evaluation.judgment?.comment.utf8.count ?? 0) <= 2_048
    }

    private static func providerURL(_ value: String, belongsTo providerValue: String) -> Bool {
        guard let url = URL(string: value),
              let providerURL = URL(string: providerValue),
              providerURL.scheme?.lowercased() == "https",
              url.scheme?.lowercased() == providerURL.scheme?.lowercased(),
              url.host?.lowercased() == providerURL.host?.lowercased(),
              url.port == providerURL.port,
              url.user == nil,
              url.password == nil
        else {
            return false
        }
        return true
    }

    private static func backendResourceURLIsValid(
        _ value: String,
        for backend: ProviderDescriptor
    ) -> Bool {
        if backend.connection.isLocal {
            return value.isEmpty
        }
        guard let webURL = backend.webURL else {
            return false
        }
        return providerURL(value, belongsTo: webURL)
    }

    private static func gameIDIsValid(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 128
            && value.utf8.allSatisfy {
                (48 ... 57).contains($0)
                    || (65 ... 90).contains($0)
                    || (97 ... 122).contains($0)
                    || $0 == 45
                    || $0 == 95
            }
    }

    private static func isBoardSquare(_ value: String) -> Bool {
        guard value.utf8.count == 2 else {
            return false
        }
        let bytes = Array(value.utf8)
        return (97 ... 104).contains(bytes[0]) && (49 ... 56).contains(bytes[1])
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

    private func supports(_ replyDelayMillis: UInt32?, using options: BotGameOptions) -> Bool {
        switch (options.replyDelay, replyDelayMillis) {
        case (nil, nil), (.some, nil):
            return true
        case let (.some(replyDelay), .some(value)):
            return replyDelay.supports(value)
        case (nil, .some):
            return false
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

    private func moveHistoryIsValid(
        _ moves: [String],
        initialFEN: String?,
        for variant: GameVariant
    ) -> Bool {
        if moves.isEmpty {
            return true
        }
        return initialFEN != nil
            && variant.supportsMoveHistory
            && moves.count <= 1_024
            && moves.allSatisfy { moveID in
                !moveID.isEmpty
                    && moveID.utf8.count <= 16
                    && moveID.utf8.allSatisfy {
                        (48 ... 57).contains($0)
                            || (65 ... 90).contains($0)
                            || (97 ... 122).contains($0)
                            || $0 == 64
                    }
            }
    }
}

private struct PendingMove {
    let requestID: String
    let gameID: String
    let moveID: String
    let baseMoves: [String]
}

private struct PendingGameHistoryRequest {
    let requestID: String
    let beforeMillis: UInt64?
}

private struct PendingReviewPosition {
    let gameID: String
    let ply: UInt32
}

private struct MovePrediction {
    let requestID: String
    let moveID: String
    let baseMoves: [String]
}

private enum PendingBoardCustomizationAction {
    case selectBoard(provider: String, theme: String)
    case selectPieces(provider: String, theme: String)
    case removeBoard(provider: String, theme: String)
    case removePieces(provider: String, theme: String)
    case restore
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
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

struct SelectBackendCommand: Encodable {
    let version = LIBCHESS_API_VERSION
    let requestID = UUID().uuidString
    let type = "select_backend"
    let backend: String

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case type
        case backend
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
    let initialMoves: [String]?
    let replyDelayMillis: UInt32?

    init(
        requestID: String = UUID().uuidString,
        opponentID: String,
        variantID: String,
        timeControl: BotGameTimeControl,
        color: GameColorPreference,
        initialFEN: String?,
        initialMoves: [String] = [],
        replyDelayMillis: UInt32? = nil
    ) {
        self.requestID = requestID
        self.opponentID = opponentID
        self.variantID = variantID
        self.timeControl = timeControl
        self.color = color
        self.initialFEN = initialFEN
        self.initialMoves = initialMoves.isEmpty ? nil : initialMoves
        self.replyDelayMillis = replyDelayMillis
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
        case initialMoves = "initial_moves"
        case replyDelayMillis = "reply_delay_millis"
    }
}

struct StartLiveGameCommand: Encodable {
    let version = LIBCHESS_API_VERSION
    let requestID = UUID().uuidString
    let type = "start_live_game"
    let gameID: String
    let playerColor: PlayerColor

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case type
        case gameID = "game_id"
        case playerColor = "player_color"
    }
}

struct StopLiveGameCommand: Encodable {
    let version = LIBCHESS_API_VERSION
    let requestID = UUID().uuidString
    let type = "stop_live_game"
    let gameID: String

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case type
        case gameID = "game_id"
    }
}

struct RefreshGameHistoryCommand: Encodable {
    let version = LIBCHESS_API_VERSION
    let requestID = UUID().uuidString
    let type = "refresh_game_history"
    let beforeMillis: UInt64?
    let limit: UInt16

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case type
        case beforeMillis = "before_millis"
        case limit
    }
}

struct ExportGameCommand: Encodable {
    let version = LIBCHESS_API_VERSION
    let requestID = UUID().uuidString
    let type = "export_game"
    let gameID: String

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case type
        case gameID = "game_id"
    }
}

struct LoadGameReviewCommand: Encodable {
    let version = LIBCHESS_API_VERSION
    let requestID = UUID().uuidString
    let type = "load_game_review"
    let gameID: String

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case type
        case gameID = "game_id"
    }
}

struct LoadBoardPresentationCommand: Encodable {
    let version = LIBCHESS_API_VERSION
    let requestID = UUID().uuidString
    let type = "load_board_presentation"
    let provider: String
    let boardTheme: String
    let pieceTheme: String

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case type
        case provider
        case boardTheme = "board_theme"
        case pieceTheme = "piece_theme"
    }
}

protocol BoardCustomizationCommand: Encodable {
    var requestID: String { get }
}

struct LoadBoardCustomizationStateCommand: BoardCustomizationCommand {
    let version = LIBCHESS_API_VERSION
    let requestID = UUID().uuidString
    let type = "load_board_customization_state"
    let state: BoardCustomizationState

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case type
        case state
    }
}

struct RegisterCustomBoardThemeCommand: BoardCustomizationCommand {
    let version = LIBCHESS_API_VERSION
    let requestID = UUID().uuidString
    let type = "register_custom_board_theme"
    let theme: CustomBoardTheme

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case type
        case theme
    }
}

struct RegisterCustomPieceThemeCommand: BoardCustomizationCommand {
    let version = LIBCHESS_API_VERSION
    let requestID = UUID().uuidString
    let type = "register_custom_piece_theme"
    let theme: CustomPieceTheme

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case type
        case theme
    }
}

struct RemoveCustomBoardThemeCommand: BoardCustomizationCommand {
    let version = LIBCHESS_API_VERSION
    let requestID = UUID().uuidString
    let type = "remove_custom_board_theme"
    let provider: String
    let theme: String

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case type
        case provider
        case theme
    }
}

struct RemoveCustomPieceThemeCommand: BoardCustomizationCommand {
    let version = LIBCHESS_API_VERSION
    let requestID = UUID().uuidString
    let type = "remove_custom_piece_theme"
    let provider: String
    let theme: String

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case type
        case provider
        case theme
    }
}

struct ShowGameReviewPositionCommand: Encodable {
    let version = LIBCHESS_API_VERSION
    let requestID = UUID().uuidString
    let type = "show_game_review_position"
    let gameID: String
    let ply: UInt32

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case type
        case gameID = "game_id"
        case ply
    }
}

struct PlayMoveCommand: Encodable {
    let version = LIBCHESS_API_VERSION
    let requestID = UUID().uuidString
    let type = "play_move"
    let gameID: String
    let moveID: String
    let offerDraw: Bool

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case type
        case gameID = "game_id"
        case moveID = "move_id"
        case offerDraw = "offer_draw"
    }
}

struct PerformGameActionCommand: Encodable {
    let version = LIBCHESS_API_VERSION
    let requestID = UUID().uuidString
    let type = "perform_game_action"
    let gameID: String
    let action: LiveGameAction

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case type
        case gameID = "game_id"
        case action
    }
}
