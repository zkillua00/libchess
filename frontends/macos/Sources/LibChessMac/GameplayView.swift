import LibChessKit
import Foundation
import SwiftUI

private enum BoardZoomLevel: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: Self { self }

    var label: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    var scale: CGFloat {
        switch self {
        case .small: 0.70
        case .medium: 0.85
        case .large: 1
        }
    }

    var larger: Self {
        switch self {
        case .small: .medium
        case .medium, .large: .large
        }
    }

    var smaller: Self {
        switch self {
        case .small, .medium: .small
        case .large: .medium
        }
    }
}

struct LiveGameplayView: View {
    @EnvironmentObject private var store: LibChessStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let game: LiveGame

    @AppStorage("org.libchess.macos.boardZoom") private var boardZoomRaw = BoardZoomLevel.medium.rawValue
    @State private var actionToConfirm: LiveGameAction?
    @State private var showsInspector = true

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = max(160, geometry.size.width - 56)
            let availableHeight = max(160, geometry.size.height - 140)
            let fittedBoardSize = min(900, availableWidth, availableHeight)
            let boardSize = min(
                fittedBoardSize,
                max(240, fittedBoardSize * boardZoomLevel.scale)
            )

            ChessBoardView(game: game)
                .id(game.id)
                .frame(width: boardSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(28)
                .animation(
                    reduceMotion ? nil : .snappy(duration: 0.26, extraBounce: 0),
                    value: boardZoomRaw
                )
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .inspector(isPresented: $showsInspector) {
            GameInspector(game: game, requestConfirmation: confirm)
                .inspectorColumnWidth(min: 280, ideal: 320, max: 380)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Zoom In") {
                        setBoardZoom(boardZoomLevel.larger)
                    }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(boardZoomLevel.larger == boardZoomLevel)

                    Button("Zoom Out") {
                        setBoardZoom(boardZoomLevel.smaller)
                    }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(boardZoomLevel.smaller == boardZoomLevel)

                    Divider()

                    Picker("Board Size", selection: $boardZoomRaw) {
                        ForEach(BoardZoomLevel.allCases) { level in
                            Text(level.label).tag(level.rawValue)
                        }
                    }
                } label: {
                    Label("Board Size", systemImage: "magnifyingglass")
                }
                .help("Board Size: \(boardZoomLevel.label)")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    showsInspector.toggle()
                } label: {
                    Label("Game Inspector", systemImage: "sidebar.right")
                }
                .help(showsInspector ? "Hide Game Inspector" : "Show Game Inspector")
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
                    store.performGameAction(actionToConfirm, in: game.id)
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

    private var boardZoomLevel: BoardZoomLevel {
        BoardZoomLevel(rawValue: boardZoomRaw) ?? .medium
    }

    private func setBoardZoom(_ level: BoardZoomLevel) {
        withAnimation(reduceMotion ? nil : .snappy(duration: 0.26, extraBounce: 0)) {
            boardZoomRaw = level.rawValue
        }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let game: LiveGame

    @State private var selectedSquare: String?
    @State private var selectedDrop: PieceRole?
    @State private var promotionMoves: [LegalMove] = []
    @State private var renderedPieces: [RenderedBoardPiece]
    @State private var renderedPly: UInt32
    @Namespace private var pieceAnimation

    init(game: LiveGame) {
        self.game = game
        _renderedPieces = State(
            initialValue: game.state.board.pieces.map(RenderedBoardPiece.initial)
        )
        _renderedPly = State(initialValue: game.state.board.ply)
    }

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
        .onChange(of: boardState.ply) { _, _ in
            clearSelection()
        }
        .onChange(of: boardState.pieces) { _, pieces in
            updateRenderedPieces(pieces)
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
                    store.playMove(move, in: game.id)
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
            uniqueKeysWithValues: boardState.pieces.map { ($0.square, $0) }
        )
        let animatedPieces = Dictionary(
            uniqueKeysWithValues: renderedPieces.map { ($0.piece.square, $0) }
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
                        isCheckedKing: boardState.inCheck
                            && piece?.role == .king
                            && piece?.color == boardState.turn,
                        showsRank: index.isMultiple(of: 8),
                        showsFile: index >= 56
                    )
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let renderedPiece = animatedPieces[square] {
                            AnimatedPieceView(piece: renderedPiece.piece)
                                .matchedGeometryEffect(
                                    id: renderedPiece.id,
                                    in: pieceAnimation
                                )
                                .transition(.scale(scale: 0.55).combined(with: .opacity))
                                .allowsHitTesting(false)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(for: square, piece: piece))
            }
        }
        .animation(.easeOut(duration: 0.12), value: selectedSquare)
        .animation(.easeOut(duration: 0.12), value: selectedDrop)
    }

    private var canMove: Bool {
        game.state.isPlayable
            && boardState.turn == game.playerColor
            && !store.isSubmittingMove(game.id)
            && !store.isPerformingGameAction(game.id)
    }

    private var boardState: BoardState {
        store.displayedBoard(for: game)
    }

    private var opponentColor: PlayerColor {
        game.playerColor == .white ? .black : .white
    }

    private var orientedSquares: [String] {
        BoardPerspective.squares(for: game.playerColor)
    }

    private var legalDestinations: Set<String> {
        if let selectedDrop {
            return Set(boardState.legalMoves.compactMap { move in
                move.drop == selectedDrop ? move.to : nil
            })
        }
        guard let selectedSquare else {
            return []
        }
        return Set(boardState.legalMoves.compactMap { move in
            move.from == selectedSquare ? move.to : nil
        })
    }

    private var legalDropRoles: Set<PieceRole> {
        Set(boardState.legalMoves.compactMap(\.drop))
    }

    private var lastMoveSquares: Set<String> {
        guard let lastMove = boardState.lastMove else {
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
        boardState.pockets.filter { $0.color == color }
    }

    private func handleTap(_ square: String, piece: BoardPiece?) {
        guard canMove else {
            return
        }

        if let selectedDrop {
            if let move = boardState.legalMoves.first(where: {
                $0.drop == selectedDrop && $0.to == square
            }) {
                store.playMove(move, in: game.id)
                clearSelection()
            } else if piece?.color == game.playerColor {
                self.selectedDrop = nil
                select(square)
            }
            return
        }

        if let selectedSquare {
            let candidates = boardState.legalMoves.filter {
                $0.from == selectedSquare && $0.to == square
            }
            if candidates.count == 1, let move = candidates.first {
                store.playMove(move, in: game.id)
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
        let hasLegalMove = boardState.legalMoves.contains { $0.from == square }
        selectedSquare = hasLegalMove ? square : nil
    }

    private func clearSelection() {
        selectedSquare = nil
        selectedDrop = nil
        promotionMoves = []
    }

    private func updateRenderedPieces(_ pieces: [BoardPiece]) {
        let next = RenderedBoardPiece.reconcile(
            previous: renderedPieces,
            current: pieces,
            lastMove: boardState.lastMove
        )
        let shouldAnimate = !reduceMotion
            && abs(Int(boardState.ply) - Int(renderedPly)) <= 1
        withAnimation(shouldAnimate ? .snappy(duration: 0.18, extraBounce: 0) : nil) {
            renderedPieces = next
            renderedPly = boardState.ply
        }
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

private struct AnimatedPieceView: View {
    let piece: BoardPiece

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            PieceGlyph(
                role: piece.role,
                color: piece.color,
                size: size * 0.72
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                if piece.promoted {
                    Image(systemName: "star.fill")
                        .font(.system(size: size * 0.13))
                        .foregroundStyle(.yellow)
                        .padding(3)
                }
            }
        }
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

private struct RenderedBoardPiece: Identifiable, Equatable {
    let id: String
    let piece: BoardPiece

    static func initial(_ piece: BoardPiece) -> Self {
        Self(
            id: "initial-\(piece.color.rawValue)-\(piece.role.rawValue)-\(piece.square)",
            piece: piece
        )
    }

    static func reconcile(
        previous: [Self],
        current: [BoardPiece],
        lastMove: LegalMove?
    ) -> [Self] {
        var unused = previous
        var identities: [String: String] = [:]

        if let from = lastMove?.from,
           let to = lastMove?.to,
           let oldIndex = unused.firstIndex(where: { $0.piece.square == from }),
           let currentPiece = current.first(where: { $0.square == to }),
           unused[oldIndex].piece.color == currentPiece.color
        {
            identities[to] = unused.remove(at: oldIndex).id
        }

        for piece in current where identities[piece.square] == nil {
            guard let oldIndex = unused.firstIndex(where: {
                $0.piece.square == piece.square
                    && $0.piece.color == piece.color
                    && $0.piece.role == piece.role
            }) else {
                continue
            }
            identities[piece.square] = unused.remove(at: oldIndex).id
        }

        for piece in current where identities[piece.square] == nil {
            let candidates = unused.indices.filter {
                unused[$0].piece.color == piece.color
                    && unused[$0].piece.role == piece.role
            }
            guard let oldIndex = candidates.min(by: {
                squareDistance(unused[$0].piece.square, piece.square)
                    < squareDistance(unused[$1].piece.square, piece.square)
            }) else {
                continue
            }
            identities[piece.square] = unused.remove(at: oldIndex).id
        }

        return current.map { piece in
            Self(
                id: identities[piece.square] ?? UUID().uuidString,
                piece: piece
            )
        }
    }

    private static func squareDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == 2, right.count == 2 else {
            return .max
        }
        return abs(Int(left[0]) - Int(right[0])) + abs(Int(left[1]) - Int(right[1]))
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

private struct GameInspector: View {
    @EnvironmentObject private var store: LibChessStore
    let game: LiveGame
    let requestConfirmation: (LiveGameAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PlayerClockRow(
                player: opponent,
                color: opponentColor,
                game: game,
                board: boardState,
                receivedAt: store.liveGameReceivedAt(game.id),
                isYou: false
            )

            Divider()

            gameSummary
                .padding(14)

            Divider()

            moveHistory
                .frame(maxHeight: .infinity)

            Divider()

            Group {
                if game.state.isPlayable {
                    actionControls
                } else {
                    finishedControls
                }
            }
            .padding(14)

            Divider()

            PlayerClockRow(
                player: player,
                color: game.playerColor,
                game: game,
                board: boardState,
                receivedAt: store.liveGameReceivedAt(game.id),
                isYou: true
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
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

            if game.state.isPlayable && !store.isLiveStreamConnected(game.id) {
                HStack {
                    Label("Live updates disconnected", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button(store.isLoadingLiveGame(game.id) ? "Connecting…" : "Reconnect") {
                        store.reconnectLiveGame(game.id)
                    }
                    .controlSize(.small)
                    .disabled(store.isLoadingLiveGame(game.id))
                }
            }
        }
    }

    private var moveHistory: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Moves")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 12)

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
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
                .frame(minHeight: 110)
                .onChange(of: boardState.ply) { _, _ in
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
                    Button("Accept") { store.performGameAction(.acceptDraw, in: game.id) }
                        .buttonStyle(.borderedProminent)
                    Button("Decline") { store.performGameAction(.declineDraw, in: game.id) }
                }
            } else if opponentTakebackOffer {
                Text("Your opponent requested a takeback.")
                    .font(.callout.weight(.medium))
                HStack {
                    Button("Accept") { store.performGameAction(.acceptTakeback, in: game.id) }
                        .buttonStyle(.borderedProminent)
                    Button("Decline") { store.performGameAction(.declineTakeback, in: game.id) }
                }
            } else {
                HStack {
                    Button(ownDrawOffer ? "Draw offered" : "Offer draw") {
                        store.performGameAction(.offerDraw, in: game.id)
                    }
                    .disabled(ownDrawOffer)

                    Button(ownTakebackOffer ? "Takeback requested" : "Takeback") {
                        store.performGameAction(.offerTakeback, in: game.id)
                    }
                    .disabled(ownTakebackOffer)
                }
            }

            HStack {
                if canClaimVictory {
                    Button("Claim victory") {
                        store.performGameAction(.claimVictory, in: game.id)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Button(boardState.ply < 2 ? "Abort" : "Resign", role: .destructive) {
                    requestConfirmation(boardState.ply < 2 ? .abort : .resign)
                }

                Menu {
                    Button("Claim draw") {
                        store.performGameAction(.claimDraw, in: game.id)
                    }
                    if let url = URL(string: game.url) {
                        Link("Open on Lichess", destination: url)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
            }
            .disabled(store.isSubmittingMove(game.id) || store.isPerformingGameAction(game.id))

            if store.isSubmittingMove(game.id) {
                Label("Move pending server confirmation", systemImage: "arrow.up.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if store.isPerformingGameAction(game.id) {
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
                    store.stopObservingLiveGame(game.id)
                    NotificationCenter.default.post(name: .showNewGame, object: nil)
                }
                .buttonStyle(.borderedProminent)
                if let url = URL(string: game.url) {
                    Link("View on Lichess", destination: url)
                }
            }
        }
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
        stride(from: 0, to: boardState.moves.count, by: 2).map { index in
            MovePair(
                number: index / 2 + 1,
                white: boardState.moves[index],
                black: boardState.moves.indices.contains(index + 1)
                    ? boardState.moves[index + 1]
                    : nil
            )
        }
    }

    private var boardState: BoardState {
        store.displayedBoard(for: game)
    }
}

private struct PlayerClockRow: View {
    let player: LiveGamePlayer
    let color: PlayerColor
    let game: LiveGame
    let board: BoardState
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
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            board.turn == color && game.state.isPlayable
                ? Color.accentColor.opacity(0.12)
                : Color.clear
        )
    }

    private var clockIsRunning: Bool {
        game.clock != nil
            && game.state.status == "started"
            && board.turn == color
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
           board.turn == color,
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
