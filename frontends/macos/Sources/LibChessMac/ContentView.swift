import LibChessKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: LibChessStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            detail
        }
        .alert(
            "LibChess",
            isPresented: Binding(
                get: { store.message != nil },
                set: { if !$0 { store.message = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                store.message = nil
            }
        } message: {
            Text(store.message ?? "")
        }
        .onChange(of: store.authorizationURL) { _, authorizationURL in
            if let authorizationURL {
                openURL(authorizationURL)
            }
        }
        .onChange(of: store.gameURLToOpen) { _, gameURL in
            if let gameURL {
                openURL(gameURL)
                store.didOpenCreatedGame()
            }
        }
        .onOpenURL { callbackURL in
            _ = store.handleOpenURL(callbackURL)
        }
    }

    private var sidebar: some View {
        List {
            Section("Play providers") {
                if store.providers.isEmpty {
                    Label("Loading providers…", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.providers) { provider in
                        Label(provider.displayName, systemImage: "network")
                    }
                }
            }

            Section("Status") {
                Label(statusTitle, systemImage: statusSymbol)
                    .foregroundStyle(statusColor)
            }
        }
        .navigationTitle("LibChess")
    }

    @ViewBuilder
    private var detail: some View {
        switch store.connectionState {
        case .connected:
            ConnectedView()
        case .authorizing:
            AuthorizingView()
        case .connecting:
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text("Finishing Lichess sign-in…")
                    .font(.headline)
                Text("LibChess is exchanging the one-time code and validating your account.")
                    .foregroundStyle(.secondary)
            }
        case .disconnected:
            ConnectView()
        }
    }

    private var statusTitle: String {
        switch store.connectionState {
        case .connected: "Connected"
        case .authorizing: "Waiting for sign-in"
        case .connecting: "Connecting"
        case .disconnected: "Not connected"
        }
    }

    private var statusSymbol: String {
        switch store.connectionState {
        case .connected: "checkmark.circle.fill"
        case .authorizing: "safari"
        case .connecting: "arrow.triangle.2.circlepath"
        case .disconnected: "circle.dashed"
        }
    }

    private var statusColor: Color {
        switch store.connectionState {
        case .connected: .green
        case .authorizing: .blue
        case .connecting: .orange
        case .disconnected: .secondary
        }
    }
}

private struct ConnectView: View {
    @EnvironmentObject private var store: LibChessStore

    var body: some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "checkerboard.rectangle")
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 7) {
                    Text("Sign in to Lichess")
                        .font(.largeTitle.bold())
                    Text("LibChess opens Lichess in your browser and asks only for permission to play games on your behalf.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button("Sign in with Lichess") {
                        store.beginLichessOAuth()
                    }
                    .buttonStyle(.borderedProminent)

                    if store.savedCredentialAvailable {
                        Button("Use Saved Credential") {
                            store.connectUsingSavedCredential()
                        }
                    }

                    Spacer()
                }

                Label(
                    "Authentication stays in your browser. The resulting credential is stored in macOS Keychain after Lichess validates it.",
                    systemImage: "lock.shield"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(32)
            .frame(maxWidth: 620)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            Spacer()
        }
        .padding(32)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct AuthorizingView: View {
    @EnvironmentObject private var store: LibChessStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 22) {
            Spacer()

            Image(systemName: "safari")
                .font(.system(size: 58))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("Finish signing in through Lichess")
                    .font(.largeTitle.bold())
                Text("Approve the board:play permission in your browser. LibChess will continue automatically when Lichess returns you here.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            HStack(spacing: 12) {
                if let authorizationURL = store.authorizationURL {
                    Button("Reopen Browser") {
                        openURL(authorizationURL)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button("Cancel", role: .cancel) {
                    store.cancelOAuth()
                }
            }

            Spacer()
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ConnectedView: View {
    @EnvironmentObject private var store: LibChessStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 16) {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .font(.system(size: 46))
                        .foregroundStyle(.green)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.account?.displayName ?? "Connected")
                            .font(.title.bold())
                        Text("\(store.connectedProvider?.displayName ?? "Chess provider") account verified through LibChess")
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Menu("Account") {
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

                if store.supportsBotGames {
                    BotGameCreatorView()
                } else {
                    GroupBox("Play a bot") {
                        Label(
                            "The connected provider does not advertise bot game creation.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.secondary)
                        .padding(8)
                    }
                }

                if let game = store.createdBotGame {
                    CreatedBotGameView(game: game)
                }

                GroupBox("Coming next") {
                    Text("The native board, game-state stream, move submission, clocks, and game actions will attach to the created game in the next slices.")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(.secondary)
                        .padding(6)
                }
            }
            .padding(32)
            .frame(maxWidth: 760)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct BotGameCreatorView: View {
    @EnvironmentObject private var store: LibChessStore
    @State private var opponentID = ""
    @State private var timeControl = BotTimeControlPreset.rapid
    @State private var color = GameColorPreference.random

    var body: some View {
        GroupBox("Play a bot") {
            VStack(alignment: .leading, spacing: 18) {
                Text("Create a casual standard game against a bot from \(store.connectedProvider?.displayName ?? "the connected provider"). The opponent catalog comes from LibChess, so this frontend does not encode provider-specific bot levels.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

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
                        Text("Time control")
                        Picker("Time control", selection: $timeControl) {
                            ForEach(BotTimeControlPreset.options) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GridRow {
                        Text("Play as")
                        Picker("Play as", selection: $color) {
                            Label("White", systemImage: "circle.fill")
                                .tag(GameColorPreference.white)
                            Label("Random", systemImage: "shuffle")
                                .tag(GameColorPreference.random)
                            Label("Black", systemImage: "circle")
                                .tag(GameColorPreference.black)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                }

                HStack {
                    Label("Standard chess · Casual · Blitz or slower", systemImage: "checkmark.shield")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        store.createBotGame(
                            opponentID: selectedOpponentID,
                            initialSeconds: timeControl.initialSeconds,
                            incrementSeconds: timeControl.incrementSeconds,
                            color: color
                        )
                    } label: {
                        HStack(spacing: 7) {
                            if store.isCreatingBotGame {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(store.isCreatingBotGame ? "Creating…" : "Create and Open")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isCreatingBotGame || selectedOpponentID.isEmpty)
                }
            }
            .padding(10)
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
}

private struct CreatedBotGameView: View {
    let game: BotGame

    var body: some View {
        GroupBox("Last created game") {
            HStack(spacing: 14) {
                Image(systemName: "checkerboard.rectangle")
                    .font(.title)
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 4) {
                    Text(game.opponent.displayName)
                        .font(.headline)
                    Text("\(game.playerColor.label) · \(game.clock.label)")
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let url = URL(string: game.url) {
                    Link("Open Game", destination: url)
                }
            }
            .padding(8)
        }
    }
}

private struct BotTimeControlPreset: Hashable, Identifiable {
    let initialSeconds: Int
    let incrementSeconds: Int

    var id: String { "\(initialSeconds)-\(incrementSeconds)" }
    var label: String { "\(initialSeconds / 60) + \(incrementSeconds)" }

    static let rapid = Self(initialSeconds: 600, incrementSeconds: 0)
    static let options = [
        Self(initialSeconds: 180, incrementSeconds: 0),
        Self(initialSeconds: 180, incrementSeconds: 2),
        Self(initialSeconds: 300, incrementSeconds: 0),
        Self(initialSeconds: 300, incrementSeconds: 3),
        rapid,
        Self(initialSeconds: 900, incrementSeconds: 10),
        Self(initialSeconds: 1_800, incrementSeconds: 0),
    ]
}

private extension PlayerColor {
    var label: String {
        switch self {
        case .white: "Playing White"
        case .black: "Playing Black"
        }
    }
}

private extension ClockTimeControl {
    var label: String {
        "\(initialSeconds / 60) + \(incrementSeconds)"
    }
}
