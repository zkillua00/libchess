import LibChessKit
import Foundation
import SwiftUI

struct LiveGameplayView: View {
    @EnvironmentObject private var store: LibChessStore
    let game: LiveGame

    @State private var actionToConfirm: LiveGameAction?

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 780 {
                HStack(alignment: .top, spacing: 22) {
                    ChessBoardView(game: game)
                        .frame(maxWidth: 680, maxHeight: .infinity)

                    GameSidebar(game: game, requestConfirmation: confirm)
                        .frame(width: 280)
                }
                .padding(22)
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        ChessBoardView(game: game)
                            .frame(maxWidth: 620)
                        GameSidebar(game: game, requestConfirmation: confirm)
                    }
                    .padding(20)
                }
            }
        }
        .alert(
            confirmationTitle,
            isPresented: Binding(
                get: { actionToConfirm != nil },
                set: { if !$0 { actionToConfirm = nil } }
            )
        ) {
            if let actionToConfirm {
                Button(actionToConfirm.confirmationButtonTitle, role: .destructive) {
                    store.performGameAction(actionToConfirm)
                    self.actionToConfirm = nil
                }
            }
            Button("Cancel", role: .cancel) {
                actionToConfirm = nil
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    private func confirm(_ action: LiveGameAction) {
        actionToConfirm = action
    }

    private var confirmationTitle: String {
        actionToConfirm == .abort ? "Abort this game?" : "Resign this game?"
    }

    private var confirmationMessage: String {
        if actionToConfirm == .abort {
            return "The game will end without a result."
        }
        return "The game will end immediately and your opponent will win."
    }
}

private struct ChessBoardView: View {
    @EnvironmentObject private var store: LibChessStore
    let game: LiveGame

    @State private var selectedSquare: String?
    @State private var selectedDrop: PieceRole?
    @State private var promotionMoves: [LegalMove] = []

    var body: some View {
        VStack(spacing: 9) {
            PocketRow(
                pieces: pockets(for: opponentColor),
                selectedRole: $selectedDrop,
                selectable: false,
                legalDropRoles: []
            )

            board
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.black.opacity(0.25), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.18), radius: 10, y: 5)

            PocketRow(
                pieces: pockets(for: game.playerColor),
                selectedRole: $selectedDrop,
                selectable: canMove,
                legalDropRoles: legalDropRoles
            )
        }
        .onChange(of: game.state.board.ply) { _, _ in
            clearSelection()
        }
        .onChange(of: game.state.status) { _, _ in
            if !game.state.isPlayable {
                clearSelection()
            }
        }
        .confirmationDialog(
            "Choose a promotion",
            isPresented: Binding(
                get: { !promotionMoves.isEmpty },
                set: { if !$0 { promotionMoves = [] } }
            ),
            titleVisibility: .visible
        ) {
            ForEach(sortedPromotionMoves) { move in
                Button(move.promotion?.displayName ?? "Promote") {
                    store.playMove(move)
                    clearSelection()
                }
            }
            Button("Cancel", role: .cancel) {
                promotionMoves = []
            }
        }
    }

    private var board: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 8)
        let boardPieces = Dictionary(
            uniqueKeysWithValues: game.state.board.pieces.map { ($0.square, $0) }
        )
        let destinations = legalDestinations

        return LazyVGrid(columns: columns, spacing: 0) {
            ForEach(Array(orientedSquares.enumerated()), id: \.element) { index, square in
                let piece = boardPieces[square]
                Button {
                    handleTap(square, piece: piece)
                } label: {
                    BoardSquareView(
                        square: square,
                        piece: piece,
                        isLight: isLightSquare(square),
                        isSelected: selectedSquare == square,
                        isDestination: destinations.contains(square),
                        isLastMove: lastMoveSquares.contains(square),
                        isCheckedKing: game.state.board.inCheck
                            && piece?.role == .king
                            && piece?.color == game.state.board.turn,
                        showsRank: index.isMultiple(of: 8),
                        showsFile: index >= 56
                    )
                    .aspectRatio(1, contentMode: .fit)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(for: square, piece: piece))
            }
        }
    }

    private var canMove: Bool {
        game.state.isPlayable
            && game.state.board.turn == game.playerColor
            && !store.isSubmittingMove
            && !store.isPerformingGameAction
    }

    private var opponentColor: PlayerColor {
        game.playerColor == .white ? .black : .white
    }

    private var orientedSquares: [String] {
        let files: [Character] = game.playerColor == .white
            ? Array("abcdefgh")
            : Array("hgfedcba")
        let ranks = game.playerColor == .white
            ? Array((1 ... 8).reversed())
            : Array(1 ... 8)
        return ranks.flatMap { rank in
            files.map { file in "\(file)\(rank)" }
        }
    }

    private var legalDestinations: Set<String> {
        if let selectedDrop {
            return Set(game.state.board.legalMoves.compactMap { move in
                move.drop == selectedDrop ? move.to : nil
            })
        }
        guard let selectedSquare else {
            return []
        }
        return Set(game.state.board.legalMoves.compactMap { move in
            move.from == selectedSquare ? move.to : nil
        })
    }

    private var legalDropRoles: Set<PieceRole> {
        Set(game.state.board.legalMoves.compactMap(\.drop))
    }

    private var lastMoveSquares: Set<String> {
        guard let lastMove = game.state.board.lastMove else {
            return []
        }
        return Set([lastMove.from, lastMove.to].compactMap { $0 })
    }

    private var sortedPromotionMoves: [LegalMove] {
        promotionMoves.sorted {
            ($0.promotion?.promotionOrder ?? 99) < ($1.promotion?.promotionOrder ?? 99)
        }
    }

    private func pockets(for color: PlayerColor) -> [PocketPiece] {
        game.state.board.pockets.filter { $0.color == color }
    }

    private func handleTap(_ square: String, piece: BoardPiece?) {
        guard canMove else {
            return
        }

        if let selectedDrop {
            if let move = game.state.board.legalMoves.first(where: {
                $0.drop == selectedDrop && $0.to == square
            }) {
                store.playMove(move)
                clearSelection()
            } else if piece?.color == game.playerColor {
                self.selectedDrop = nil
                select(square)
            }
            return
        }

        if let selectedSquare {
            let candidates = game.state.board.legalMoves.filter {
                $0.from == selectedSquare && $0.to == square
            }
            if candidates.count == 1, let move = candidates.first {
                store.playMove(move)
                clearSelection()
                return
            }
            if candidates.count > 1 {
                promotionMoves = candidates
                return
            }
            if selectedSquare == square {
                self.selectedSquare = nil
            } else if piece?.color == game.playerColor {
                select(square)
            } else {
                self.selectedSquare = nil
            }
            return
        }

        if piece?.color == game.playerColor {
            select(square)
        }
    }

    private func select(_ square: String) {
        let hasLegalMove = game.state.board.legalMoves.contains { $0.from == square }
        selectedSquare = hasLegalMove ? square : nil
    }

    private func clearSelection() {
        selectedSquare = nil
        selectedDrop = nil
        promotionMoves = []
    }

    private func isLightSquare(_ square: String) -> Bool {
        let bytes = Array(square.utf8)
        guard bytes.count == 2 else {
            return false
        }
        return !(Int(bytes[0] - 97) + Int(bytes[1] - 49)).isMultiple(of: 2)
    }

    private func accessibilityLabel(for square: String, piece: BoardPiece?) -> String {
        guard let piece else {
            return "Empty square \(square)"
        }
        return "\(piece.color.displayName) \(piece.role.displayName) on \(square)"
    }
}

private struct BoardSquareView: View {
    let square: String
    let piece: BoardPiece?
    let isLight: Bool
    let isSelected: Bool
    let isDestination: Bool
    let isLastMove: Bool
    let isCheckedKing: Bool
    let showsRank: Bool
    let showsFile: Bool

    var body: some View {
        ZStack {
            (isLight ? Color.boardLight : Color.boardDark)

            if isLastMove {
                Color.yellow.opacity(0.42)
            }
            if isSelected {
                Color.accentColor.opacity(0.48)
            }
            if isCheckedKing {
                RadialGradient(
                    colors: [.red.opacity(0.78), .red.opacity(0.08)],
                    center: .center,
                    startRadius: 2,
                    endRadius: 42
                )
            }

            if let piece {
                GeometryReader { geometry in
                    PieceGlyph(
                        role: piece.role,
                        color: piece.color,
                        size: min(geometry.size.width, geometry.size.height) * 0.72
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topTrailing) {
                        if piece.promoted {
                            Image(systemName: "star.fill")
                                .font(.system(size: geometry.size.width * 0.13))
                                .foregroundStyle(.yellow)
                                .padding(3)
                        }
                    }
                }
            }

            if isDestination {
                if piece == nil {
                    Circle()
                        .fill(.black.opacity(0.28))
                        .frame(width: 17, height: 17)
                } else {
                    Circle()
                        .stroke(.black.opacity(0.33), lineWidth: 5)
                        .padding(4)
                }
            }

            if showsRank {
                Text(String(square.suffix(1)))
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(isLight ? Color.boardDark : Color.boardLight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(3)
            }
            if showsFile {
                Text(String(square.prefix(1)))
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(isLight ? Color.boardDark : Color.boardLight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(3)
            }
        }
    }
}

private struct PocketRow: View {
    let pieces: [PocketPiece]
    @Binding var selectedRole: PieceRole?
    let selectable: Bool
    let legalDropRoles: Set<PieceRole>

    var body: some View {
        HStack(spacing: 6) {
            ForEach(pieces) { piece in
                Button {
                    selectedRole = selectedRole == piece.role ? nil : piece.role
                } label: {
                    HStack(spacing: 3) {
                        PieceGlyph(role: piece.role, color: piece.color, size: 24)
                        if piece.count > 1 {
                            Text("×\(piece.count)")
                                .font(.caption2.monospacedDigit())
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        selectedRole == piece.role
                            ? Color.accentColor.opacity(0.28)
                            : Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!selectable || !legalDropRoles.contains(piece.role))
            }
            Spacer(minLength: 0)
        }
        .frame(height: 30)
    }
}

private struct PieceGlyph: View {
    let role: PieceRole
    let color: PlayerColor
    let size: CGFloat

    var body: some View {
        Text(role.glyph)
            .font(.system(size: size, weight: .regular, design: .serif))
            .foregroundStyle(color == .white ? Color.white : Color(red: 0.09, green: 0.09, blue: 0.08))
            .shadow(
                color: color == .white ? .black.opacity(0.58) : .white.opacity(0.32),
                radius: 0.7,
                x: 0,
                y: 0.5
            )
            .accessibilityHidden(true)
    }
}

private struct GameSidebar: View {
    @EnvironmentObject private var store: LibChessStore
    let game: LiveGame
    let requestConfirmation: (LiveGameAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PlayerClockCard(
                player: opponent,
                color: opponentColor,
                game: game,
                receivedAt: store.liveGameReceivedAt,
                isYou: false
            )

            gameSummary

            moveHistory

            if game.state.isPlayable {
                actionControls
            } else {
                finishedControls
            }

            PlayerClockCard(
                player: player,
                color: game.playerColor,
                game: game,
                receivedAt: store.liveGameReceivedAt,
                isYou: true
            )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var gameSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(game.variantName, systemImage: "checkerboard.rectangle")
                    .font(.headline)
                Spacer()
                Text(game.rated ? "Rated" : "Casual")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }

            Label(game.state.status.displayName, systemImage: game.state.isPlayable ? "bolt.fill" : "flag.checkered")
                .font(.callout)
                .foregroundStyle(game.state.isPlayable ? Color.green : Color.secondary)

            if game.state.opponentGone {
                Label(opponentGoneText, systemImage: "wifi.slash")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if game.state.isPlayable && !store.isLiveStreamConnected {
                HStack {
                    Label("Live updates disconnected", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button(store.isLoadingLiveGame ? "Connecting…" : "Reconnect") {
                        store.reconnectLiveGame()
                    }
                    .controlSize(.small)
                    .disabled(store.isLoadingLiveGame)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    }

    private var moveHistory: some View {
        GroupBox("Moves") {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        if movePairs.isEmpty {
                            Text("The game has not started.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(movePairs) { pair in
                            HStack(spacing: 8) {
                                Text("\(pair.number).")
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 28, alignment: .trailing)
                                Text(pair.white)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(pair.black ?? "")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.system(.callout, design: .monospaced))
                            .id(pair.id)
                        }
                    }
                    .padding(6)
                }
                .frame(minHeight: 90, maxHeight: 180)
                .onChange(of: game.state.board.ply) { _, _ in
                    if let last = movePairs.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var actionControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            if opponentDrawOffer {
                Text("Your opponent offered a draw.")
                    .font(.callout.weight(.medium))
                HStack {
                    Button("Accept") { store.performGameAction(.acceptDraw) }
                        .buttonStyle(.borderedProminent)
                    Button("Decline") { store.performGameAction(.declineDraw) }
                }
            } else if opponentTakebackOffer {
                Text("Your opponent requested a takeback.")
                    .font(.callout.weight(.medium))
                HStack {
                    Button("Accept") { store.performGameAction(.acceptTakeback) }
                        .buttonStyle(.borderedProminent)
                    Button("Decline") { store.performGameAction(.declineTakeback) }
                }
            } else {
                HStack {
                    Button(ownDrawOffer ? "Draw offered" : "Offer draw") {
                        store.performGameAction(.offerDraw)
                    }
                    .disabled(ownDrawOffer)

                    Button(ownTakebackOffer ? "Takeback requested" : "Takeback") {
                        store.performGameAction(.offerTakeback)
                    }
                    .disabled(ownTakebackOffer)
                }
            }

            HStack {
                if canClaimVictory {
                    Button("Claim victory") {
                        store.performGameAction(.claimVictory)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button(game.state.board.ply < 2 ? "Abort" : "Resign", role: .destructive) {
                    requestConfirmation(game.state.board.ply < 2 ? .abort : .resign)
                }

                Menu {
                    Button("Claim draw") {
                        store.performGameAction(.claimDraw)
                    }
                    if let url = URL(string: game.url) {
                        Link("Open on Lichess", destination: url)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
            }
            .disabled(store.isSubmittingMove || store.isPerformingGameAction)

            if store.isSubmittingMove {
                Label("Submitting move…", systemImage: "arrow.up.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if store.isPerformingGameAction {
                Label("Updating game…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var finishedControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(resultText)
                .font(.headline)
            HStack {
                Button("New game") {
                    store.leaveLiveGame()
                }
                .buttonStyle(.borderedProminent)
                if let url = URL(string: game.url) {
                    Link("View on Lichess", destination: url)
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var player: LiveGamePlayer {
        game.playerColor == .white ? game.white : game.black
    }

    private var opponent: LiveGamePlayer {
        game.playerColor == .white ? game.black : game.white
    }

    private var opponentColor: PlayerColor {
        game.playerColor == .white ? .black : .white
    }

    private var opponentDrawOffer: Bool {
        game.playerColor == .white ? game.state.blackDrawOffer : game.state.whiteDrawOffer
    }

    private var ownDrawOffer: Bool {
        game.playerColor == .white ? game.state.whiteDrawOffer : game.state.blackDrawOffer
    }

    private var opponentTakebackOffer: Bool {
        game.playerColor == .white
            ? game.state.blackTakebackOffer
            : game.state.whiteTakebackOffer
    }

    private var ownTakebackOffer: Bool {
        game.playerColor == .white
            ? game.state.whiteTakebackOffer
            : game.state.blackTakebackOffer
    }

    private var canClaimVictory: Bool {
        game.state.opponentGone && game.state.claimWinInSeconds == 0
    }

    private var opponentGoneText: String {
        if let seconds = game.state.claimWinInSeconds, seconds > 0 {
            return "Opponent disconnected · claim in \(seconds)s"
        }
        return "Opponent disconnected"
    }

    private var resultText: String {
        if game.state.status == "aborted" {
            return "Game aborted"
        }
        if game.state.status == "noStart" {
            return "Game not started"
        }
        guard let winner = game.state.winner else {
            return ["draw", "stalemate", "insufficientMaterialClaim"].contains(game.state.status)
                ? "Game drawn"
                : "Game ended"
        }
        return winner == game.playerColor ? "You won" : "You lost"
    }

    private var movePairs: [MovePair] {
        stride(from: 0, to: game.state.board.moves.count, by: 2).map { index in
            MovePair(
                number: index / 2 + 1,
                white: game.state.board.moves[index],
                black: game.state.board.moves.indices.contains(index + 1)
                    ? game.state.board.moves[index + 1]
                    : nil
            )
        }
    }
}

private struct PlayerClockCard: View {
    let player: LiveGamePlayer
    let color: PlayerColor
    let game: LiveGame
    let receivedAt: Date?
    let isYou: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color == .white ? .white : .black)
                .frame(width: 20, height: 20)
                .overlay {
                    Circle().stroke(.secondary, lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(player.displayName)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let rating = player.rating {
                        Text("\(rating)\(player.provisional ? "?" : "")")
                    }
                    if let aiLevel = player.aiLevel {
                        Text("Level \(aiLevel)")
                    }
                    if isYou {
                        Text("You")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 6)

            Group {
                if clockIsRunning {
                    TimelineView(.periodic(from: .now, by: clockRefreshInterval)) { timeline in
                        Text(clockText(at: timeline.date))
                    }
                } else {
                    Text(clockText(at: receivedAt ?? .now))
                }
            }
            .font(.system(size: 24, weight: .semibold, design: .monospaced))
            .contentTransition(.numericText())
        }
        .padding(11)
        .background(
            game.state.board.turn == color && game.state.isPlayable
                ? Color.accentColor.opacity(0.14)
                : Color.primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 10)
        )
    }

    private var clockIsRunning: Bool {
        game.clock != nil
            && game.state.status == "started"
            && game.state.board.turn == color
    }

    private var clockRefreshInterval: TimeInterval {
        let milliseconds = color == .white
            ? game.state.whiteTimeMillis
            : game.state.blackTimeMillis
        return milliseconds.map { $0 < 10_000 ? 0.1 : 1 } ?? 1
    }

    private func clockText(at date: Date) -> String {
        guard game.clock != nil else {
            if let days = game.daysPerTurn {
                return days == 1 ? "1 day" : "\(days) days"
            }
            return "∞"
        }
        guard var milliseconds = color == .white
            ? game.state.whiteTimeMillis
            : game.state.blackTimeMillis
        else {
            return "∞"
        }

        if game.state.status == "started",
           game.state.board.turn == color,
           let receivedAt
        {
            let elapsed = UInt64(max(0, date.timeIntervalSince(receivedAt)) * 1_000)
            milliseconds = milliseconds.saturatingSubtract(elapsed)
        }

        if milliseconds < 10_000 {
            return (Double(milliseconds) / 1_000).formatted(
                .number.precision(.fractionLength(1))
            )
        }
        let seconds = milliseconds / 1_000
        if seconds >= 3_600 {
            return String(format: "%d:%02d:%02d", seconds / 3_600, (seconds / 60) % 60, seconds % 60)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct MovePair: Identifiable {
    let number: Int
    let white: String
    let black: String?

    var id: Int { number }
}

private extension PieceRole {
    var glyph: String {
        switch self {
        case .pawn: "♟"
        case .knight: "♞"
        case .bishop: "♝"
        case .rook: "♜"
        case .queen: "♛"
        case .king: "♚"
        }
    }

    var displayName: String {
        switch self {
        case .pawn: "Pawn"
        case .knight: "Knight"
        case .bishop: "Bishop"
        case .rook: "Rook"
        case .queen: "Queen"
        case .king: "King"
        }
    }

    var promotionOrder: Int {
        switch self {
        case .queen: 0
        case .rook: 1
        case .bishop: 2
        case .knight: 3
        case .pawn, .king: 4
        }
    }
}

private extension PlayerColor {
    var displayName: String {
        self == .white ? "White" : "Black"
    }
}

private extension String {
    var displayName: String {
        switch self {
        case "created": "Created"
        case "started": "In progress"
        case "aborted": "Aborted"
        case "mate": "Checkmate"
        case "resign": "Resignation"
        case "stalemate": "Stalemate"
        case "timeout", "outoftime": "Time expired"
        case "draw": "Draw"
        case "cheat": "Fair-play termination"
        case "noStart": "Game not started"
        case "insufficientMaterialClaim": "Insufficient material"
        case "variantEnd": "Variant victory"
        default: self.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

private extension LiveGameAction {
    var confirmationButtonTitle: String {
        self == .abort ? "Abort Game" : "Resign"
    }
}

private extension UInt64 {
    func saturatingSubtract(_ other: UInt64) -> UInt64 {
        self > other ? self - other : 0
    }
}

private extension Color {
    static let boardLight = Color(red: 0.83, green: 0.77, blue: 0.65)
    static let boardDark = Color(red: 0.42, green: 0.52, blue: 0.35)
}
