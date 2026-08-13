import Combine
import Foundation
import LibChessKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: LibChessStore
    @Environment(\.openURL) private var openURL
    @State private var selection: SidebarDestination? = .newGame
    @State private var exportDocument: PGNDocument?
    @State private var exportFilename = "game.pgn"
    @State private var showsFileExporter = false

    var body: some View {
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
        .onChange(of: store.connectionState.rawValue) { previousState, state in
            if state == ConnectionState.connected.rawValue,
               previousState != ConnectionState.connected.rawValue
            {
                selection = .newGame
            } else if state == ConnectionState.disconnected.rawValue {
                selection = .account
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
        .onChange(of: selection) { _, destination in
            if case let .some(.game(gameID)) = destination {
                store.openLiveGame(gameID)
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
        .onChange(of: store.authorizationURL) { _, authorizationURL in
            if let authorizationURL {
                openURL(authorizationURL)
            }
        }
        .onOpenURL { callbackURL in
            _ = store.handleOpenURL(callbackURL)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showNewGame)) { _ in
            selection = .newGame
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

    private var sidebar: some View {
        List(selection: $selection) {
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
                    isSelected: selection == .account
                ) {
                    selection = .account
                }
                .environmentObject(store)
                .padding(8)
            }
            .background(.bar)
        }
        .navigationTitle("LibChess")
    }

    @ViewBuilder
    private var detail: some View {
        switch store.connectionState {
        case .connected:
            connectedDetail
        case .authorizing:
            AuthorizingView()
        case .connecting:
            ConnectingView()
        case .disconnected:
            ConnectView()
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
            RecentGamesView()
        case .account:
            AccountOverviewView()
        }
    }
}

private enum SidebarDestination: Hashable {
    case newGame
    case game(String)
    case history
    case account
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
    @EnvironmentObject private var store: LibChessStore

    let account: ChessAccount?
    let providerName: String?
    let connectionState: ConnectionState
    let isSelected: Bool
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
            isSelected ? Color.accentColor.opacity(0.18) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7)
        )
        .contextMenu {
            if connectionState == .connected {
                Button("Refresh Account") {
                    store.refreshAccount()
                }
                Button("Disconnect") {
                    store.disconnect()
                }
                Divider()
                Button("Disconnect and Remove from This Mac", role: .destructive) {
                    store.disconnect(forgetCredential: true)
                }
            }
        }
        .help(account == nil ? "Sign in to a chess service" : "Show account overview")
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
            "Waiting for Lichess"
        case .connecting:
            "Connecting…"
        case .disconnected:
            "Lichess"
        }
    }
}

private struct RecentGamesView: View {
    @EnvironmentObject private var store: LibChessStore

    var body: some View {
        Group {
            if !store.supportsGameHistory {
                ContentUnavailableView {
                    Label("Game History Unavailable", systemImage: "clock.badge.questionmark")
                } description: {
                    Text("The connected chess service does not expose finished games.")
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
                            HistoryGameRow(game: game)
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

    var body: some View {
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

            if store.isExportingGame(game.id) {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 24)
            }

            Menu {
                Button {
                    openAnalysis()
                } label: {
                    Label("Analyze on Lichess", systemImage: "chart.xyaxis.line")
                }
                if store.supportsPGNExport {
                    Button {
                        store.exportGame(game.id)
                    } label: {
                        Label("Export PGN…", systemImage: "square.and.arrow.down")
                    }
                    .disabled(store.isExportingGame(game.id))
                }
                Divider()
                Button {
                    openGame()
                } label: {
                    Label("View on Lichess", systemImage: "safari")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: openAnalysis)
        .contextMenu {
            Button("Analyze on Lichess", action: openAnalysis)
            if store.supportsPGNExport {
                Button("Export PGN…") {
                    store.exportGame(game.id)
                }
                .disabled(store.isExportingGame(game.id))
            }
            Divider()
            Button("View on Lichess", action: openGame)
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

    private func openAnalysis() {
        if let url = URL(string: game.analysisURL) {
            openURL(url)
        }
    }

    private func openGame() {
        if let url = URL(string: game.url) {
            openURL(url)
        }
    }
}

private struct ConnectView: View {
    @EnvironmentObject private var store: LibChessStore

    var body: some View {
        VStack(spacing: 18) {
            ContentUnavailableView {
                Label("Sign in to Lichess", systemImage: "checkerboard.rectangle")
            } description: {
                Text("Connect your account to create and play games from this Mac.")
            } actions: {
                HStack(spacing: 10) {
                    Button("Sign in with Lichess") {
                        store.beginLichessOAuth()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)

                    if store.savedCredentialAvailable {
                        Button("Use Saved Credential") {
                            store.connectUsingSavedCredential()
                        }
                    }
                }
            }

            Label(
                "Authentication opens on lichess.org. Your credential is stored in macOS Keychain.",
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Connect")
    }
}

private struct AuthorizingView: View {
    @EnvironmentObject private var store: LibChessStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        ContentUnavailableView {
            Label("Finish signing in", systemImage: "safari")
        } description: {
            Text("Approve permission in your browser. LibChess will continue when Lichess returns you here.")
        } actions: {
            HStack(spacing: 10) {
                if let authorizationURL = store.authorizationURL {
                    Button("Reopen Browser") {
                        openURL(authorizationURL)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button("Cancel", role: .cancel) {
                    store.cancelOAuth()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Connect")
    }
}

private struct ConnectingView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Connecting to Lichess", systemImage: "arrow.triangle.2.circlepath")
        } description: {
            Text("LibChess is validating your account and preparing the connection.")
        } actions: {
            ProgressView()
                .controlSize(.small)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Connect")
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
                        Text("The connected chess service does not provide bot-game creation.")
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

private struct AccountOverviewView: View {
    @EnvironmentObject private var store: LibChessStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    accountAvatar

                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.account?.displayName ?? "Account")
                            .font(.largeTitle.bold())
                        Label("Connected to \(store.connectedProvider?.displayName ?? "chess service")", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }

                Divider()

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
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                Divider()

                HStack(spacing: 10) {
                    Button("Refresh Account") {
                        store.refreshAccount()
                    }
                    Button("Disconnect") {
                        store.disconnect()
                    }
                    Spacer()
                    Button("Remove from This Mac", role: .destructive) {
                        store.disconnect(forgetCredential: true)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("Account")
    }

    private var accountAvatar: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor)
            Text(store.account?.username.first.map { String($0).uppercased() } ?? "?")
                .font(.title.bold())
                .foregroundStyle(.white)
        }
        .frame(width: 64, height: 64)
        .accessibilityHidden(true)
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
    @State private var opponentID = ""
    @State private var variantID = ""
    @State private var timeControlMode = BotTimeControlMode.clock
    @State private var initialSeconds: UInt32 = 600
    @State private var incrementSeconds: UInt32 = 0
    @State private var correspondenceDays: UInt8 = 3
    @State private var color = GameColorPreference.random
    @State private var useCustomPosition = false
    @State private var initialFEN = ""

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
                        initialFEN: customPositionEnabled ? initialFEN : nil
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
        if store.botOpponents.contains(where: { $0.id == opponentID }) {
            return opponentID
        }
        guard !store.botOpponents.isEmpty else {
            return ""
        }
        return store.botOpponents[(store.botOpponents.count - 1) / 2].id
    }

    private var opponentSelection: Binding<String> {
        Binding(
            get: { selectedOpponentID },
            set: { opponentID = $0 }
        )
    }

    private var selectedVariantID: String {
        if store.botVariants.contains(where: { $0.id == variantID }) {
            return variantID
        }
        return store.botVariants.first(where: { $0.id == "standard" })?.id
            ?? store.botVariants.first?.id
            ?? ""
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
        availableTimeControlModes.contains(timeControlMode)
            ? timeControlMode
            : availableTimeControlModes.first ?? .clock
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
            return initialSeconds
        }
        return choices.contains(initialSeconds) ? initialSeconds : choices.first ?? 0
    }

    private var initialSecondsSelection: Binding<UInt32> {
        Binding(
            get: { selectedInitialSeconds },
            set: { initialSeconds = $0 }
        )
    }

    private var selectedIncrementSeconds: UInt32 {
        guard let choices = clockOptions?.incrementSeconds else {
            return incrementSeconds
        }
        return choices.contains(incrementSeconds) ? incrementSeconds : choices.first ?? 0
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
        correspondenceDayOptions.contains(correspondenceDays)
            ? correspondenceDays
            : correspondenceDayOptions.first ?? 1
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
        if advertisedColors.contains(color) {
            return color
        }
        return advertisedColors.first ?? .random
    }

    private var colorSelection: Binding<GameColorPreference> {
        Binding(
            get: { selectedColor },
            set: { color = $0 }
        )
    }

    private var customPositionEnabled: Bool {
        guard let variant = selectedVariant else {
            return false
        }
        return variant.requiresCustomPosition || (variant.supportsCustomPosition && useCustomPosition)
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
                return "Choose a Blitz-or-slower clock."
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
        }
        return nil
    }

    private var summaryLabel: String {
        let variant = selectedVariant?.displayName ?? "Chess"
        return "\(variant) · Casual · \(requestedTimeControl?.label ?? "Time control")"
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
