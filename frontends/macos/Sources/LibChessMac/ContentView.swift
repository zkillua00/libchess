import Combine
import Foundation
import LibChessKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: LibChessStore
    @State private var selection: SidebarDestination? = .newGame
    @State private var exportDocument: PGNDocument?
    @State private var exportFilename = "game.pgn"
    @State private var showsFileExporter = false
    @State private var showsAccountPopover = false

    var body: some View {
        workspace
        .onChange(of: store.selectedBackend?.id) { _, backendID in
            if backendID == nil {
                selection = .newGame
                showsAccountPopover = false
            }
        }
        .onChange(of: store.connectionState.rawValue) { previousState, state in
            if state == ConnectionState.connected.rawValue,
               previousState != ConnectionState.connected.rawValue
            {
                selection = .newGame
            } else if state == ConnectionState.disconnected.rawValue {
                showsAccountPopover = false
            }
        }
        .onChange(of: store.focusedGameID) { _, gameID in
            if let gameID {
                selection = .game(gameID)
            }
        }
        .onChange(of: store.activeGames.map(\.id)) { _, gameIDs in
            if case let .some(.game(gameID)) = selection, !gameIDs.contains(gameID) {
                selection = .newGame
            }
        }
        .onChange(of: store.recentGames.map(\.id)) { _, gameIDs in
            if case let .some(.review(gameID)) = selection, !gameIDs.contains(gameID) {
                selection = .history
            }
        }
        .onChange(of: selection) { _, destination in
            if case let .some(.game(gameID)) = destination {
                store.openLiveGame(gameID)
            } else if case let .some(.review(gameID)) = destination {
                store.loadGameReview(gameID)
            } else if destination == .history, store.recentGames.isEmpty {
                store.refreshGameHistory()
            }
        }
        .onChange(of: store.exportedGame) { _, gameExport in
            guard let gameExport else {
                return
            }
            exportDocument = PGNDocument(text: gameExport.pgn)
            exportFilename = gameExport.suggestedFilename
            showsFileExporter = true
            store.consumeExportedGame()
        }
        .onReceive(NotificationCenter.default.publisher(for: .showNewGame)) { _ in
            guard store.connectionState == .connected else { return }
            selection = .newGame
        }
        .onReceive(NotificationCenter.default.publisher(for: .showGame)) { notification in
            guard store.connectionState == .connected,
                  let gameID = notification.object as? String
            else {
                return
            }
            selection = .game(gameID)
        }
        .fileExporter(
            isPresented: $showsFileExporter,
            document: exportDocument,
            contentType: .portableGameNotation,
            defaultFilename: exportFilename
        ) { result in
            if case let .failure(error) = result {
                store.message = "The PGN could not be saved: \(error.localizedDescription)"
            }
            exportDocument = nil
        }
    }

    private var workspace: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
        } detail: {
            detail
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let message = store.message {
                        InlineMessageBanner(message: message) {
                            store.message = nil
                        }
                    }
                }
        }
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section("Play") {
                Label("New Game", systemImage: "plus.square")
                    .tag(SidebarDestination.newGame)

                ForEach(store.activeGames) { game in
                    SidebarGameRow(game: game)
                        .tag(SidebarDestination.game(game.id))
                }
            }

            Section("Library") {
                Label("Recent Games", systemImage: "clock.arrow.circlepath")
                    .tag(SidebarDestination.history)
            }
        }
        .listStyle(.sidebar)
        .animation(.snappy(duration: 0.22), value: store.activeGames.map(\.id))
        .scrollContentBackground(.hidden)
        .background(.clear)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                SidebarAccountButton(
                    account: store.account,
                    providerName: store.connectedProvider?.displayName,
                    connectionState: store.connectionState,
                    isPresented: showsAccountPopover
                ) {
                    showsAccountPopover.toggle()
                }
                .popover(
                    isPresented: $showsAccountPopover,
                    attachmentAnchor: .point(.topTrailing),
                    arrowEdge: .top
                ) {
                    AccountPopoverView {
                        showsAccountPopover = false
                    }
                    .environmentObject(store)
                }
                .padding(8)
            }
            .background(.bar)
        }
        .navigationTitle("LibChess")
    }

    private var sidebarSelection: Binding<SidebarDestination?> {
        Binding(
            get: {
                if case .some(.review) = selection {
                    return .history
                }
                return selection
            },
            set: { selection = $0 }
        )
    }

    @ViewBuilder
    private var detail: some View {
        if store.connectionState == .connected {
            connectedDetail
        } else {
            ProgressView("Returning to launcher…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var connectedDetail: some View {
        switch selection ?? .newGame {
        case .newGame:
            NewGameView()
        case let .game(gameID):
            if let game = store.liveGame(gameID) {
                LiveGameplayView(game: game)
                    .navigationTitle(
                        store.activeGames.first(where: { $0.id == gameID })?.displayName
                            ?? game.variantName
                    )
            } else if let summary = store.activeGames.first(where: { $0.id == gameID }),
                      store.isLoadingLiveGame(gameID)
            {
                LiveGameLoadingView(game: summary)
            } else if let summary = store.activeGames.first(where: { $0.id == gameID }) {
                ContentUnavailableView {
                    Label(summary.displayName, systemImage: "checkerboard.rectangle")
                } description: {
                    Text("The game stream is not connected.")
                } actions: {
                    Button("Open Game") {
                        store.openLiveGame(gameID)
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                NewGameView()
            }
        case .history:
            RecentGamesView { gameID in
                selection = .review(gameID)
            }
        case let .review(gameID):
            if let game = store.recentGames.first(where: { $0.id == gameID }) {
                GameReviewView(game: game)
                    .navigationTitle("vs \(game.opponentDisplayName)")
            } else {
                RecentGamesView { selectedGameID in
                    selection = .review(selectedGameID)
                }
            }
        }
    }
}

private enum SidebarDestination: Hashable {
    case newGame
    case game(String)
    case history
    case review(String)
}

private struct SidebarGameRow: View {
    let game: LiveGameSummary

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkerboard.rectangle")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(game.isMyTurn ? Color.accentColor : Color.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(game.displayName)
                    .lineLimit(1)
                Text(game.isMyTurn ? "Your turn" : game.variantName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 2)

            if game.isMyTurn {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("Your turn")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SidebarAccountButton: View {
    let account: ChessAccount?
    let providerName: String?
    let connectionState: ConnectionState
    let isPresented: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                avatar

                VStack(alignment: .leading, spacing: 1) {
                    Text(account?.displayName ?? "Sign In")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(accountSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background(
            isPresented ? Color.accentColor.opacity(0.18) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .help(account == nil ? "Show sign-in options" : "Show account menu")
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(account == nil ? Color.secondary.opacity(0.28) : Color.accentColor)
            if let initial = account?.username.first {
                Text(String(initial).uppercased())
                    .font(.caption.bold())
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "person.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }

    private var accountSubtitle: String {
        switch connectionState {
        case .connected:
            providerName ?? "Connected"
        case .authorizing:
            "Waiting for \(providerName ?? "approval")"
        case .connecting:
            "Connecting…"
        case .disconnected:
            providerName ?? "Not connected"
        }
    }
}

private struct RecentGamesView: View {
    @EnvironmentObject private var store: LibChessStore
    let openReview: (String) -> Void

    var body: some View {
        Group {
            if !store.supportsGameHistory {
                ContentUnavailableView {
                    Label("Game History Unavailable", systemImage: "clock.badge.questionmark")
                } description: {
                    Text("\(store.selectedBackend?.displayName ?? "The selected backend") does not expose finished games.")
                }
            } else if store.recentGames.isEmpty, store.isLoadingGameHistory {
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Loading recent games…")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.recentGames.isEmpty {
                ContentUnavailableView {
                    Label("No Recent Games", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Finished games from the connected account will appear here.")
                } actions: {
                    Button("Refresh") {
                        store.refreshGameHistory()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    Section {
                        ForEach(store.recentGames) { game in
                            HistoryGameRow(game: game) {
                                openReview(game.id)
                            }
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }

                    if store.nextGameHistoryCursor != nil {
                        Section {
                            HStack {
                                Spacer()
                                Button {
                                    store.loadMoreGameHistory()
                                } label: {
                                    if store.isLoadingGameHistory {
                                        ProgressView()
                                            .controlSize(.small)
                                            .frame(width: 90)
                                    } else {
                                        Text("Load More")
                                            .frame(width: 90)
                                    }
                                }
                                .disabled(store.isLoadingGameHistory)
                                Spacer()
                            }
                            .padding(.vertical, 6)
                        }
                    }
                }
                .listStyle(.inset)
                .animation(.snappy(duration: 0.24), value: store.recentGames.map(\.id))
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Recent Games")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.refreshGameHistory()
                } label: {
                    Label("Refresh Games", systemImage: "arrow.clockwise")
                }
                .disabled(store.isLoadingGameHistory)
                .help("Refresh Recent Games")
            }
        }
    }
}

private struct HistoryGameRow: View {
    @EnvironmentObject private var store: LibChessStore
    @Environment(\.openURL) private var openURL

    let game: GameHistoryEntry
    let openReview: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: openReview) {
                HStack(spacing: 14) {
                    Image(systemName: resultSymbol)
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(resultColor)
                        .frame(width: 24)
                        .accessibilityLabel(resultText)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 7) {
                            Text(game.opponentDisplayName)
                                .font(.headline)
                                .lineLimit(1)
                            if let rating = game.opponentRating {
                                Text("\(rating)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            if let level = game.opponentAILevel {
                                Text("Level \(level)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        HStack(spacing: 6) {
                            Text(resultText)
                            Text("·")
                            Text(game.variantName)
                            Text("·")
                            Text(game.speed.displayName)
                            Text("·")
                            Text(game.rated ? "Rated" : "Casual")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    Text(gameDate, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .help(gameDate.formatted(date: .complete, time: .shortened))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if store.isExportingGame(game.id) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24)
            }

            Menu {
                Button {
                    openReview()
                } label: {
                    Label("Review in LibChess", systemImage: "chart.xyaxis.line")
                }
                if store.supportsPGNExport {
                    Button {
                        store.exportGame(game.id)
                    } label: {
                        Label("Export PGN…", systemImage: "square.and.arrow.down")
                    }
                    .disabled(store.isExportingGame(game.id))
                }
                if !game.url.isEmpty {
                    Divider()
                    Button {
                        openGame()
                    } label: {
                        Label("View on \(store.selectedBackend?.displayName ?? "Web")", systemImage: "safari")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 7)
        .contextMenu {
            Button("Review in LibChess", action: openReview)
            if store.supportsPGNExport {
                Button("Export PGN…") {
                    store.exportGame(game.id)
                }
                .disabled(store.isExportingGame(game.id))
            }
            if !game.url.isEmpty {
                Divider()
                Button("View on \(store.selectedBackend?.displayName ?? "Web")", action: openGame)
            }
        }
    }

    private var gameDate: Date {
        Date(timeIntervalSince1970: Double(game.lastMoveAtMillis) / 1_000)
    }

    private var resultText: String {
        guard let winner = game.winner else {
            return game.status == "aborted" ? "Aborted" : "Draw"
        }
        return winner == game.playerColor ? "Won" : "Lost"
    }

    private var resultSymbol: String {
        guard let winner = game.winner else {
            return game.status == "aborted" ? "minus.circle.fill" : "equal.circle.fill"
        }
        return winner == game.playerColor ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    private var resultColor: Color {
        guard let winner = game.winner else {
            return .secondary
        }
        return winner == game.playerColor ? .green : .red
    }

    private func openGame() {
        if let url = URL(string: game.url) {
            openURL(url)
        }
    }
}

private struct NewGameView: View {
    @EnvironmentObject private var store: LibChessStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("New Game")
                        .font(.largeTitle.bold())
                    Text("Choose an opponent and game format.")
                        .foregroundStyle(.secondary)
                }

                Divider()

                if store.supportsBotGames {
                    BotGameCreatorView()
                } else {
                    ContentUnavailableView {
                        Label("Bot games unavailable", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("\(store.selectedBackend?.displayName ?? "The selected backend") does not provide bot-game creation.")
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("New Game")
    }
}

private struct AccountPopoverView: View {
    @EnvironmentObject private var store: LibChessStore
    @Environment(\.openURL) private var openURL
    @State private var confirmsCredentialRemoval = false

    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            accountHeader

            switch store.connectionState {
            case .connected:
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                    GridRow {
                        Text("Username")
                            .foregroundStyle(.secondary)
                        Text(store.account?.username ?? "—")
                            .textSelection(.enabled)
                    }
                    GridRow {
                        Text("Provider")
                            .foregroundStyle(.secondary)
                        Text(store.connectedProvider?.displayName ?? "—")
                    }
                    GridRow {
                        Text("Account ID")
                            .foregroundStyle(.secondary)
                        Text(store.account?.id ?? "—")
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                Divider()

                HStack {
                    if store.selectedBackend?.connection.isLocal == false {
                        Button("Refresh") {
                            store.refreshAccount()
                        }
                    }

                    Spacer()

                    if store.selectedBackend?.connection.isLocal == false {
                        Button("Disconnect") {
                            store.disconnect()
                            dismiss()
                        }
                    }
                }

                if store.selectedBackend?.connection.usesOAuthPKCE == true {
                    Button("Remove Saved Credential…", role: .destructive) {
                        confirmsCredentialRemoval = true
                    }
                }

            case .authorizing:
                statusRow("Waiting for approval in your browser")

                HStack {
                    if let authorizationURL = store.authorizationURL {
                        Button("Reopen Browser") {
                            openURL(authorizationURL)
                        }
                    }

                    Spacer()

                    Button("Cancel", role: .cancel) {
                        store.cancelOAuth()
                        dismiss()
                    }
                }

            case .connecting:
                statusRow("Validating your account…")

            case .disconnected:
                Button("Sign in with \(store.selectedBackend?.displayName ?? "Backend")") {
                    store.beginOAuth()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)

                if store.savedCredentialAvailable {
                    Button {
                        store.connectUsingSavedCredential()
                        dismiss()
                    } label: {
                        if store.isLoadingSavedCredential {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Use Saved Credential")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .disabled(store.isLoadingSavedCredential)
                }

                Label(
                    "Credentials are stored in macOS Keychain without password prompts.",
                    systemImage: "lock.shield"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Divider()

            Button("Choose Another Backend…") {
                store.clearBackendSelection()
                dismiss()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .frame(width: 360)
        .alert("Remove Saved Credential?", isPresented: $confirmsCredentialRemoval) {
            Button("Remove", role: .destructive) {
                store.disconnect(forgetCredential: true)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("LibChess will disconnect and remove the \(store.selectedBackend?.displayName ?? "saved") credential from this Mac.")
        }
    }

    private var accountHeader: some View {
        HStack(spacing: 12) {
            accountAvatar

            VStack(alignment: .leading, spacing: 2) {
                Text(accountTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(accountSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    private var accountAvatar: some View {
        ZStack {
            Circle()
                .fill(store.account == nil ? Color.secondary.opacity(0.22) : Color.accentColor)

            if let initial = store.account?.username.first {
                Text(String(initial).uppercased())
                    .font(.title3.bold())
                    .foregroundStyle(.white)
            } else {
                Image(systemName: "person.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .accessibilityHidden(true)
    }

    private var accountTitle: String {
        store.account?.displayName
            ?? store.selectedBackend.map { "\($0.displayName) Account" }
            ?? "Backend Account"
    }

    private var accountSubtitle: String {
        switch store.connectionState {
        case .connected:
            "Connected"
        case .authorizing:
            "Finish signing in"
        case .connecting:
            "Connecting…"
        case .disconnected:
            "Not signed in"
        }
    }

    private func statusRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}

private struct InlineMessageBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct PGNDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.portableGameNotation] }

    let text: String

    init(text: String = "") {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

private extension UTType {
    static let portableGameNotation = UTType(
        exportedAs: "org.libchess.portable-game-notation",
        conformingTo: .plainText
    )
}

private extension String {
    var displayName: String {
        switch self {
        case "ultraBullet": "UltraBullet"
        case "bullet": "Bullet"
        case "blitz": "Blitz"
        case "rapid": "Rapid"
        case "classical": "Classical"
        case "correspondence": "Correspondence"
        default: replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

private struct LiveGameLoadingView: View {
    @EnvironmentObject private var store: LibChessStore
    let game: LiveGameSummary

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Preparing the native board…")
                .font(.title2.bold())
            Text("Connecting to \(game.displayName) · \(game.variantName)")
                .foregroundStyle(.secondary)

            Button("Cancel", role: .cancel) {
                store.stopObservingLiveGame(game.id)
                NotificationCenter.default.post(name: .showNewGame, object: nil)
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(game.displayName)
    }
}

private struct BotGameCreatorView: View {
    @EnvironmentObject private var store: LibChessStore
    @State private var opponentID: String?
    @State private var variantID: String?
    @State private var timeControlMode: BotTimeControlMode?
    @State private var initialSeconds: UInt32?
    @State private var incrementSeconds: UInt32?
    @State private var correspondenceDays: UInt8?
    @State private var color: GameColorPreference?
    @State private var replyDelayMillis: UInt32?
    @State private var useCustomPosition = false
    @State private var initialFEN = ""
    @State private var loadMoveHistory = false
    @State private var initialMoveText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Play a Bot")
                    .font(.title2.bold())
                Text("Create a casual game against \(store.connectedProvider?.displayName ?? "the connected service") AI.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 14) {
                GridRow {
                    Text("Opponent")
                    Picker("Opponent", selection: opponentSelection) {
                        ForEach(store.botOpponents) { opponent in
                            Text(opponent.displayName).tag(opponent.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GridRow {
                    Text("Variant")
                    Picker("Variant", selection: variantSelection) {
                        ForEach(store.botVariants) { variant in
                            Text(variant.displayName).tag(variant.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GridRow {
                    Text("Time control")
                    Picker("Time control", selection: timeControlModeSelection) {
                        ForEach(availableTimeControlModes) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if selectedTimeControlMode == .clock, let clockOptions {
                    GridRow {
                        Text("Initial time")
                        Picker("Initial time", selection: initialSecondsSelection) {
                            ForEach(clockOptions.initialSeconds, id: \.self) { seconds in
                                Text(seconds.initialTimeLabel).tag(seconds)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GridRow {
                        Text("Increment")
                        Picker("Increment", selection: incrementSecondsSelection) {
                            ForEach(clockOptions.incrementSeconds, id: \.self) { seconds in
                                Text(seconds.incrementLabel).tag(seconds)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if selectedTimeControlMode == .correspondence {
                    GridRow {
                        Text("Per move")
                        Picker("Days per move", selection: correspondenceDaysSelection) {
                            ForEach(correspondenceDayOptions, id: \.self) { days in
                                Text(days == 1 ? "1 day" : "\(days) days").tag(days)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                GridRow {
                    Text("Play as")
                    Picker("Play as", selection: colorSelection) {
                        ForEach(advertisedColors) { option in
                            Label(option.label, systemImage: option.systemImage)
                                .tag(option)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                if let replyDelayOptions {
                    GridRow {
                        Text("Reply delay")
                        HStack(spacing: 12) {
                            Slider(
                                value: replyDelaySelection,
                                in: Double(replyDelayOptions.minimumMillis)
                                    ... Double(replyDelayOptions.maximumMillis),
                                step: Double(replyDelayOptions.stepMillis)
                            )
                            Text(replyDelayLabel)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 58, alignment: .trailing)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }

            if let variant = selectedVariant, variant.supportsCustomPosition {
                Divider()

                if variant.requiresCustomPosition {
                    Label("This variant requires a custom initial position.", systemImage: "square.grid.3x3")
                        .font(.callout)
                } else {
                    Toggle("Use a custom initial position", isOn: $useCustomPosition)
                }

                if customPositionEnabled {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Initial position (X-FEN)")
                            .font(.callout.weight(.medium))
                        TextField("X-FEN", text: $initialFEN)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        Text("A single printable ASCII line, up to 1,024 bytes. The provider validates the chess position.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if variant.supportsMoveHistory {
                        Toggle("Load move history", isOn: $loadMoveHistory)

                        if loadMoveHistory {
                            VStack(alignment: .leading, spacing: 7) {
                                Text("Moves after the X-FEN")
                                    .font(.callout.weight(.medium))
                                TextField(
                                    "e2e4 e7e5 g1f3",
                                    text: $initialMoveText,
                                    axis: .vertical
                                )
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(2 ... 5)
                                Text("Enter UCI moves separated by spaces. LibChess replays and validates them from the X-FEN; loaded plies remain available to the move list and takeback.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            Divider()

            HStack {
                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                } else {
                    Label(summaryLabel, systemImage: "checkmark.shield")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    guard let requestedTimeControl else {
                        return
                    }
                    store.createBotGame(
                        opponentID: selectedOpponentID,
                        variantID: selectedVariantID,
                        timeControl: requestedTimeControl,
                        color: selectedColor,
                        initialFEN: customPositionEnabled ? initialFEN : nil,
                        initialMoves: requestedInitialMoves,
                        replyDelayMillis: replyDelayOptions == nil
                            ? nil
                            : selectedReplyDelayMillis
                    )
                } label: {
                    HStack(spacing: 7) {
                        if store.isCreatingBotGame {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(store.isCreatingBotGame ? "Creating…" : "Create Game")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(store.isCreatingBotGame || validationMessage != nil)
            }
        }
    }

    private var selectedOpponentID: String {
        if let opponentID, store.botOpponents.contains(where: { $0.id == opponentID }) {
            return opponentID
        }
        if let defaultID = store.botGameOptions?.defaultOpponentID,
           store.botOpponents.contains(where: { $0.id == defaultID })
        {
            return defaultID
        }
        return store.botOpponents.first?.id ?? ""
    }

    private var opponentSelection: Binding<String> {
        Binding(
            get: { selectedOpponentID },
            set: { opponentID = $0 }
        )
    }

    private var selectedVariantID: String {
        if let variantID, store.botVariants.contains(where: { $0.id == variantID }) {
            return variantID
        }
        if let defaultID = store.botGameOptions?.defaultVariantID,
           store.botVariants.contains(where: { $0.id == defaultID })
        {
            return defaultID
        }
        return store.botVariants.first?.id ?? ""
    }

    private var selectedVariant: GameVariant? {
        store.botVariants.first(where: { $0.id == selectedVariantID })
    }

    private var variantSelection: Binding<String> {
        Binding(
            get: { selectedVariantID },
            set: { variantID = $0 }
        )
    }

    private var availableTimeControlModes: [BotTimeControlMode] {
        guard let options = store.botGameOptions else {
            return []
        }
        var modes: [BotTimeControlMode] = []
        if options.clock != nil {
            modes.append(.clock)
        }
        if !options.correspondenceDays.isEmpty {
            modes.append(.correspondence)
        }
        if options.unlimited {
            modes.append(.unlimited)
        }
        return modes
    }

    private var selectedTimeControlMode: BotTimeControlMode {
        if let timeControlMode, availableTimeControlModes.contains(timeControlMode) {
            return timeControlMode
        }
        if let defaultMode, availableTimeControlModes.contains(defaultMode) {
            return defaultMode
        }
        return availableTimeControlModes.first ?? .unlimited
    }

    private var timeControlModeSelection: Binding<BotTimeControlMode> {
        Binding(
            get: { selectedTimeControlMode },
            set: { timeControlMode = $0 }
        )
    }

    private var clockOptions: ClockTimeControlOptions? {
        store.botGameOptions?.clock
    }

    private var selectedInitialSeconds: UInt32 {
        guard let choices = clockOptions?.initialSeconds else {
            return initialSeconds ?? 0
        }
        if let initialSeconds, choices.contains(initialSeconds) {
            return initialSeconds
        }
        if case let .some(.clock(defaultInitial, _)) = store.botGameOptions?.defaultTimeControl,
           choices.contains(defaultInitial)
        {
            return defaultInitial
        }
        return choices.first ?? 0
    }

    private var initialSecondsSelection: Binding<UInt32> {
        Binding(
            get: { selectedInitialSeconds },
            set: { initialSeconds = $0 }
        )
    }

    private var selectedIncrementSeconds: UInt32 {
        guard let choices = clockOptions?.incrementSeconds else {
            return incrementSeconds ?? 0
        }
        if let incrementSeconds, choices.contains(incrementSeconds) {
            return incrementSeconds
        }
        if case let .some(.clock(_, defaultIncrement)) = store.botGameOptions?.defaultTimeControl,
           choices.contains(defaultIncrement)
        {
            return defaultIncrement
        }
        return choices.first ?? 0
    }

    private var incrementSecondsSelection: Binding<UInt32> {
        Binding(
            get: { selectedIncrementSeconds },
            set: { incrementSeconds = $0 }
        )
    }

    private var correspondenceDayOptions: [UInt8] {
        store.botGameOptions?.correspondenceDays ?? []
    }

    private var selectedCorrespondenceDays: UInt8 {
        if let correspondenceDays, correspondenceDayOptions.contains(correspondenceDays) {
            return correspondenceDays
        }
        if case let .some(.correspondence(defaultDays)) = store.botGameOptions?.defaultTimeControl,
           correspondenceDayOptions.contains(defaultDays)
        {
            return defaultDays
        }
        return correspondenceDayOptions.first ?? 1
    }

    private var correspondenceDaysSelection: Binding<UInt8> {
        Binding(
            get: { selectedCorrespondenceDays },
            set: { correspondenceDays = $0 }
        )
    }

    private var advertisedColors: [GameColorPreference] {
        let colors = store.botGameOptions?.colors ?? []
        return [GameColorPreference.white, .random, .black].filter(colors.contains)
    }

    private var selectedColor: GameColorPreference {
        if let color, advertisedColors.contains(color) {
            return color
        }
        if let defaultColor = store.botGameOptions?.defaultColor,
           advertisedColors.contains(defaultColor)
        {
            return defaultColor
        }
        return advertisedColors.first ?? .random
    }

    private var colorSelection: Binding<GameColorPreference> {
        Binding(
            get: { selectedColor },
            set: { color = $0 }
        )
    }

    private var replyDelayOptions: BotReplyDelayOptions? {
        guard let options = store.botGameOptions?.replyDelay,
              options.minimumMillis <= options.maximumMillis,
              options.stepMillis > 0,
              options.supports(options.maximumMillis),
              options.supports(options.defaultMillis)
        else {
            return nil
        }
        return options
    }

    private var selectedReplyDelayMillis: UInt32 {
        guard let options = replyDelayOptions else {
            return 0
        }
        if let replyDelayMillis, options.supports(replyDelayMillis) {
            return replyDelayMillis
        }
        return options.defaultMillis
    }

    private var replyDelaySelection: Binding<Double> {
        Binding(
            get: { Double(selectedReplyDelayMillis) },
            set: { replyDelayMillis = UInt32($0.rounded()) }
        )
    }

    private var replyDelayLabel: String {
        let value = selectedReplyDelayMillis
        if value == 0 {
            return "None"
        }
        if value.isMultiple(of: 1_000) {
            return "\(value / 1_000) s"
        }
        return String(format: "%.1f s", Double(value) / 1_000)
    }

    private var customPositionEnabled: Bool {
        guard let variant = selectedVariant else {
            return false
        }
        return variant.requiresCustomPosition || (variant.supportsCustomPosition && useCustomPosition)
    }

    private var requestedInitialMoves: [String] {
        guard customPositionEnabled,
              selectedVariant?.supportsMoveHistory == true,
              loadMoveHistory
        else {
            return []
        }
        return initialMoveText
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    private var requestedTimeControl: BotGameTimeControl? {
        switch selectedTimeControlMode {
        case .clock:
            guard let clockOptions,
                  clockOptions.initialSeconds.contains(selectedInitialSeconds),
                  clockOptions.incrementSeconds.contains(selectedIncrementSeconds)
            else {
                return nil
            }
            return .clock(
                initialSeconds: selectedInitialSeconds,
                incrementSeconds: selectedIncrementSeconds
            )
        case .correspondence:
            guard correspondenceDayOptions.contains(selectedCorrespondenceDays) else {
                return nil
            }
            return .correspondence(daysPerMove: selectedCorrespondenceDays)
        case .unlimited:
            return store.botGameOptions?.unlimited == true ? .unlimited : nil
        }
    }

    private var defaultMode: BotTimeControlMode? {
        switch store.botGameOptions?.defaultTimeControl {
        case .some(.clock(_, _)): .clock
        case .some(.correspondence(_)): .correspondence
        case .some(.unlimited): .unlimited
        case nil: nil
        }
    }

    private var validationMessage: String? {
        guard !selectedOpponentID.isEmpty,
              let variant = selectedVariant,
              !advertisedColors.isEmpty,
              let timeControl = requestedTimeControl
        else {
            return "The provider did not advertise complete bot-game options."
        }

        if case let .clock(initial, increment) = timeControl, let clockOptions {
            guard clockOptions.initialSeconds.contains(initial)
            else {
                return "Choose an advertised initial time."
            }
            guard clockOptions.incrementSeconds.contains(increment)
            else {
                return "Choose an advertised increment."
            }
            let estimated = UInt64(initial) + UInt64(increment) * 40
            if let minimum = clockOptions.minimumEstimatedDurationSeconds,
               estimated < UInt64(minimum)
            {
                return "Choose a time control within the backend's advertised minimum."
            }
        }

        if variant.requiresCustomPosition && !customPositionEnabled {
            return "This variant requires an initial position."
        }
        if customPositionEnabled {
            let fen = initialFEN.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fen.isEmpty else {
                return "Enter an initial X-FEN position."
            }
            guard fen.utf8.count <= 1_024,
                  fen.unicodeScalars.allSatisfy({ (32 ... 126).contains($0.value) })
            else {
                return "X-FEN must be one printable ASCII line up to 1,024 bytes."
            }

            if loadMoveHistory && variant.supportsMoveHistory {
                let moves = requestedInitialMoves
                guard !moves.isEmpty else {
                    return "Enter at least one move to load the move history."
                }
                guard moves.count <= 1_024,
                      moves.allSatisfy({ moveID in
                          !moveID.isEmpty
                              && moveID.utf8.count <= 16
                              && moveID.utf8.allSatisfy {
                                  (48 ... 57).contains($0)
                                      || (65 ... 90).contains($0)
                                      || (97 ... 122).contains($0)
                                      || $0 == 64
                              }
                      })
                else {
                    return "Use at most 1,024 compact UCI move identifiers."
                }
            }
        }
        return nil
    }

    private var summaryLabel: String {
        let variant = selectedVariant?.displayName ?? "Chess"
        let history = requestedInitialMoves.isEmpty
            ? ""
            : " · \(requestedInitialMoves.count) loaded plies"
        return "\(variant) · Casual · \(requestedTimeControl?.label ?? "Time control")\(history)"
    }

}

private enum BotTimeControlMode: String, Hashable, Identifiable {
    case clock
    case correspondence
    case unlimited

    var id: Self { self }

    var label: String {
        switch self {
        case .clock: "Clock"
        case .correspondence: "Correspondence"
        case .unlimited: "Unlimited"
        }
    }
}

private extension PlayerColor {
    var label: String {
        switch self {
        case .white: "Playing White"
        case .black: "Playing Black"
        }
    }
}

private extension BotGameTimeControl {
    var label: String {
        switch self {
        case let .clock(initialSeconds, incrementSeconds):
            let minutes = Double(initialSeconds) / 60
            let initial = initialSeconds.isMultiple(of: 60)
                ? "\(initialSeconds / 60)"
                : minutes.formatted(.number.precision(.fractionLength(2)))
            return "\(initial) + \(incrementSeconds)"
        case let .correspondence(daysPerMove):
            return daysPerMove == 1 ? "1 day per move" : "\(daysPerMove) days per move"
        case .unlimited:
            return "Unlimited"
        }
    }
}

private extension GameColorPreference {
    var label: String {
        switch self {
        case .white: "White"
        case .random: "Random"
        case .black: "Black"
        }
    }

    var systemImage: String {
        switch self {
        case .white: "circle.fill"
        case .random: "shuffle"
        case .black: "circle"
        }
    }
}

private extension UInt32 {
    var initialTimeLabel: String {
        switch self {
        case 0:
            "0 seconds"
        case 1 ..< 60:
            "\(self) seconds"
        case 60:
            "1 minute"
        case 90:
            "1 minute 30 seconds"
        default:
            "\(self / 60) minutes"
        }
    }

    var incrementLabel: String {
        switch self {
        case 0: "No increment"
        case 1: "1 second"
        default: "\(self) seconds"
        }
    }
}
