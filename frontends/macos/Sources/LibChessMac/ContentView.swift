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
    @State private var variantID = ""
    @State private var timeControlMode = BotTimeControlMode.clock
    @State private var initialSeconds: UInt32 = 600
    @State private var incrementSeconds: UInt32 = 0
    @State private var correspondenceDays: UInt8 = 3
    @State private var color = GameColorPreference.random
    @State private var useCustomPosition = false
    @State private var initialFEN = ""

    var body: some View {
        GroupBox("Play a bot") {
            VStack(alignment: .leading, spacing: 18) {
                Text("Create a casual game against a bot from \(store.connectedProvider?.displayName ?? "the connected provider"). Every choice below is advertised by LibChess for the active provider.")
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
                            Text(store.isCreatingBotGame ? "Creating…" : "Create and Open")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isCreatingBotGame || validationMessage != nil)
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
                    Text("\(game.variant.displayName) · \(game.playerColor.label) · \(game.timeControl.label)")
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
