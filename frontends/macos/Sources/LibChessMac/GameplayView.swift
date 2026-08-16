import AppKit
import LibChessKit
import Charts
import Foundation
import SwiftUI

struct LiveGameplayView: View {
    @EnvironmentObject private var store: LibChessStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let game: LiveGame

    @AppStorage(BoardPreferenceKey.zoomPreset) private var boardZoomID = ""
    @State private var actionToConfirm: LiveGameAction?
    @State private var showsInspector = true

    var body: some View {
        Group {
            if let presentation = store.boardPresentation {
                gameplayWorkspace(presentation: presentation)
            } else {
                boardAppearanceLoadingView
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .inspector(isPresented: $showsInspector) {
            GameInspector(game: game, requestConfirmation: confirm)
                .inspectorColumnWidth(min: 280, ideal: 320, max: 380)
        }
        .toolbar {
            if let presentation = store.boardPresentation {
                ToolbarItem(placement: .primaryAction) {
                    BoardAppearanceMenu(presentation: presentation)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    NotificationCenter.default.post(
                        name: .showFloatingBoard,
                        object: game.id
                    )
                } label: {
                    Label("Floating Board", systemImage: "pip.enter")
                }
                .help("Show Board in Floating Window")
                .disabled(!game.state.isPlayable)
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

    private func gameplayWorkspace(presentation: BoardPresentation) -> some View {
        GeometryReader { geometry in
            let zoom = currentZoom(in: presentation)
            let boardExtent = ChessBoardLayout.extent(
                in: geometry.size,
                presentation: presentation,
                zoom: zoom,
                verticalChrome: 140
            )

            ChessBoardView(
                game: game,
                boardExtent: boardExtent,
                presentation: presentation
            )
            .id(game.id)
            .frame(width: boardExtent)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(28)
            .simultaneousGesture(boardMagnificationGesture(for: presentation))
            .animation(
                presentation.motion.boardResize.nativeAnimation(reduceMotion: reduceMotion),
                value: boardZoomID
            )
        }
    }

    private var boardAppearanceLoadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading board appearance…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func confirm(_ action: LiveGameAction) {
        actionToConfirm = action
    }

    private func currentZoom(in presentation: BoardPresentation) -> BoardZoomPreset {
        presentation.zoom.preset(id: boardZoomID)
            ?? presentation.zoom.defaultValue
            ?? presentation.zoom.presets[0]
    }

    private func setBoardZoom(_ preset: BoardZoomPreset, presentation: BoardPresentation) {
        withAnimation(
            presentation.motion.boardResize.nativeAnimation(reduceMotion: reduceMotion)
        ) {
            boardZoomID = preset.id
        }
    }

    private func boardMagnificationGesture(for presentation: BoardPresentation) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.08)
            .onEnded { value in
                let current = currentZoom(in: presentation)
                if value.magnification > 1 {
                    setBoardZoom(
                        presentation.zoom.adjacent(to: current, offset: 1),
                        presentation: presentation
                    )
                } else if value.magnification < 1 {
                    setBoardZoom(
                        presentation.zoom.adjacent(to: current, offset: -1),
                        presentation: presentation
                    )
                }
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

struct GameReviewView: View {
    @EnvironmentObject private var store: LibChessStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    let game: GameHistoryEntry

    @AppStorage(BoardPreferenceKey.zoomPreset) private var boardZoomID = ""
    @State private var selectedPly: UInt32?
    @State private var showsInspector = true

    var body: some View {
        Group {
            if let presentation = store.boardPresentation,
               let review = store.gameReviews[game.id],
               let board = store.reviewBoards[game.id]
            {
                reviewWorkspace(review: review, board: board, presentation: presentation)
            } else if store.boardPresentation == nil || store.isLoadingGameReview(game.id) {
                VStack(spacing: 14) {
                    ProgressView()
                        .controlSize(.large)
                    Text(store.boardPresentation == nil
                        ? "Loading board appearance…"
                        : "Loading game review…")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Review Unavailable", systemImage: "chart.xyaxis.line")
                } description: {
                    Text("The game review could not be loaded.")
                } actions: {
                    Button("Try Again") {
                        store.loadGameReview(game.id, reload: true)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: game.id) {
            if let board = store.reviewBoards[game.id] {
                selectedPly = board.ply
            } else {
                selectedPly = nil
                store.loadGameReview(game.id)
            }
        }
        .onChange(of: store.gameReviews[game.id]?.moves.count) { _, moveCount in
            guard let moveCount else {
                return
            }
            let finalPly = UInt32(moveCount)
            if selectedPly == nil || selectedPly.map({ $0 > finalPly }) == true {
                selectedPly = finalPly
            }
        }
    }

    private func reviewWorkspace(
        review: GameReview,
        board: BoardState,
        presentation: BoardPresentation
    ) -> some View {
        GeometryReader { geometry in
            let zoom = currentZoom(in: presentation)
            let boardExtent = ChessBoardLayout.extent(
                in: geometry.size,
                presentation: presentation,
                zoom: zoom,
                verticalChrome: 56
            )

            ReviewChessBoardView(
                board: board,
                perspective: game.playerColor,
                presentation: presentation
            )
            .id(game.id)
            .frame(width: boardExtent, height: boardExtent)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding(28)
            .simultaneousGesture(boardMagnificationGesture(for: presentation))
            .overlay(alignment: .topTrailing) {
                if store.isLoadingReviewPosition(game.id) {
                    ProgressView()
                        .controlSize(.small)
                        .padding(14)
                }
            }
            .animation(
                presentation.motion.boardResize.nativeAnimation(reduceMotion: reduceMotion),
                value: boardZoomID
            )
        }
        .inspector(isPresented: $showsInspector) {
            GameReviewInspector(
                game: game,
                review: review,
                selectedPly: currentPly(review),
                selectPly: { selectPly($0, in: review) }
            )
            .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    selectPly(0, in: review)
                } label: {
                    Label("First Position", systemImage: "backward.end.fill")
                }
                .disabled(currentPly(review) == 0)

                Button {
                    step(-1, in: review)
                } label: {
                    Label("Previous Move", systemImage: "chevron.left")
                }
                .disabled(currentPly(review) == 0)

                Button {
                    step(1, in: review)
                } label: {
                    Label("Next Move", systemImage: "chevron.right")
                }
                .disabled(currentPly(review) >= UInt32(review.moves.count))

                Button {
                    selectPly(UInt32(review.moves.count), in: review)
                } label: {
                    Label("Final Position", systemImage: "forward.end.fill")
                }
                .disabled(currentPly(review) >= UInt32(review.moves.count))
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    store.exportGame(game.id)
                } label: {
                    if store.isExportingGame(game.id) {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Export PGN", systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(!store.supportsPGNExport || store.isExportingGame(game.id))
                .help("Export Annotated PGN…")

                Menu {
                    Button("Refresh Review") {
                        selectedPly = UInt32(review.moves.count)
                        store.loadGameReview(game.id, reload: true)
                    }

                    if !game.url.isEmpty {
                        Button("Open on \(store.selectedBackend?.displayName ?? "Web")") {
                            if let url = URL(string: game.url) {
                                openURL(url)
                            }
                        }
                    }
                } label: {
                    Label("Review Options", systemImage: "ellipsis.circle")
                }

                BoardAppearanceMenu(presentation: presentation)

                Button {
                    showsInspector.toggle()
                } label: {
                    Label("Review Inspector", systemImage: "sidebar.right")
                }
                .help(showsInspector ? "Hide Review Inspector" : "Show Review Inspector")
            }
        }
        .onMoveCommand { direction in
            switch direction {
            case .left:
                step(-1, in: review)
            case .right:
                step(1, in: review)
            default:
                break
            }
        }
        .focusable()
    }

    private func currentPly(_ review: GameReview) -> UInt32 {
        min(selectedPly ?? UInt32(review.moves.count), UInt32(review.moves.count))
    }

    private func selectPly(_ ply: UInt32, in review: GameReview) {
        let boundedPly = min(ply, UInt32(review.moves.count))
        selectedPly = boundedPly
        store.showGameReviewPosition(game.id, ply: boundedPly)
    }

    private func step(_ amount: Int, in review: GameReview) {
        let next = max(0, min(Int(currentPly(review)) + amount, review.moves.count))
        selectPly(UInt32(next), in: review)
    }

    private func currentZoom(in presentation: BoardPresentation) -> BoardZoomPreset {
        presentation.zoom.preset(id: boardZoomID)
            ?? presentation.zoom.defaultValue
            ?? presentation.zoom.presets[0]
    }

    private func setBoardZoom(_ preset: BoardZoomPreset, presentation: BoardPresentation) {
        withAnimation(
            presentation.motion.boardResize.nativeAnimation(reduceMotion: reduceMotion)
        ) {
            boardZoomID = preset.id
        }
    }

    private func boardMagnificationGesture(for presentation: BoardPresentation) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.08)
            .onEnded { value in
                let current = currentZoom(in: presentation)
                if value.magnification > 1 {
                    setBoardZoom(
                        presentation.zoom.adjacent(to: current, offset: 1),
                        presentation: presentation
                    )
                } else if value.magnification < 1 {
                    setBoardZoom(
                        presentation.zoom.adjacent(to: current, offset: -1),
                        presentation: presentation
                    )
                }
            }
    }
}

private struct BoardAppearanceMenu: View {
    @EnvironmentObject private var store: LibChessStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(BoardPreferenceKey.zoomPreset) private var boardZoomID = ""

    let presentation: BoardPresentation

    var body: some View {
        Menu {
            Picker("Board", selection: boardThemeSelection) {
                ForEach(store.boardProviders) { provider in
                    Section(provider.displayName) {
                        ForEach(provider.boardThemes) { theme in
                            Text(theme.displayName)
                                .tag("\(provider.id)/\(theme.id)")
                        }
                    }
                }
            }

            Picker("Pieces", selection: pieceThemeSelection) {
                ForEach(store.boardProviders) { provider in
                    Section(provider.displayName) {
                        ForEach(provider.pieceThemes) { theme in
                            Text(theme.displayName)
                                .tag("\(provider.id)/\(theme.id)")
                        }
                    }
                }
            }

            Divider()

            Button("Zoom In") {
                setZoom(presentation.zoom.adjacent(to: currentZoom, offset: 1))
            }
            .disabled(presentation.zoom.adjacent(to: currentZoom, offset: 1) == currentZoom)

            Button("Zoom Out") {
                setZoom(presentation.zoom.adjacent(to: currentZoom, offset: -1))
            }
            .disabled(presentation.zoom.adjacent(to: currentZoom, offset: -1) == currentZoom)

            Picker("Board Size", selection: $boardZoomID) {
                ForEach(presentation.zoom.presets) { preset in
                    Text(preset.displayName).tag(preset.id)
                }
            }
        } label: {
            if store.isLoadingBoardPresentation {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label("Board Appearance", systemImage: "checkerboard.rectangle")
            }
        }
        .help(
            "\(presentation.board.displayName) board · "
                + "\(presentation.pieces.displayName) pieces · "
                + currentZoom.displayName
        )
    }

    private var currentZoom: BoardZoomPreset {
        presentation.zoom.preset(id: boardZoomID)
            ?? presentation.zoom.defaultValue
            ?? presentation.zoom.presets[0]
    }

    private var boardThemeSelection: Binding<String> {
        Binding(
            get: { "\(presentation.provider)/\(presentation.boardTheme)" },
            set: { selection in
                guard let (provider, boardTheme) = parse(selection),
                      let descriptor = store.boardProviders.first(where: {
                          $0.id == provider
                      })
                else {
                    return
                }
                let pieceTheme = provider == presentation.provider
                    && descriptor.pieceThemes.contains(where: {
                        $0.id == presentation.pieceTheme
                    })
                    ? presentation.pieceTheme
                    : descriptor.defaultPieceTheme
                store.selectBoardPresentation(
                    provider: provider,
                    boardTheme: boardTheme,
                    pieceTheme: pieceTheme
                )
            }
        )
    }

    private var pieceThemeSelection: Binding<String> {
        Binding(
            get: { "\(presentation.provider)/\(presentation.pieceTheme)" },
            set: { selection in
                guard let (provider, pieceTheme) = parse(selection),
                      let descriptor = store.boardProviders.first(where: {
                          $0.id == provider
                      })
                else {
                    return
                }
                let boardTheme = provider == presentation.provider
                    && descriptor.boardThemes.contains(where: {
                        $0.id == presentation.boardTheme
                    })
                    ? presentation.boardTheme
                    : descriptor.defaultBoardTheme
                store.selectBoardPresentation(
                    provider: provider,
                    boardTheme: boardTheme,
                    pieceTheme: pieceTheme
                )
            }
        )
    }

    private func parse(_ selection: String) -> (provider: String, theme: String)? {
        let parts = selection.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            return nil
        }
        return (parts[0], parts[1])
    }

    private func setZoom(_ preset: BoardZoomPreset) {
        withAnimation(
            presentation.motion.boardResize.nativeAnimation(reduceMotion: reduceMotion)
        ) {
            boardZoomID = preset.id
        }
    }
}

private struct ReviewChessBoardView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let board: BoardState
    let perspective: PlayerColor
    let presentation: BoardPresentation

    @State private var renderedPieces: [RenderedBoardPiece]
    @State private var renderedPly: UInt32
    @Namespace private var pieceAnimation

    init(
        board: BoardState,
        perspective: PlayerColor,
        presentation: BoardPresentation
    ) {
        self.board = board
        self.perspective = perspective
        self.presentation = presentation
        _renderedPieces = State(initialValue: board.pieces.map(RenderedBoardPiece.initial))
        _renderedPly = State(initialValue: board.ply)
    }

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 8)
        let boardPieces = Dictionary(uniqueKeysWithValues: board.pieces.map { ($0.square, $0) })
        let animatedPieces = Dictionary(
            uniqueKeysWithValues: renderedPieces.map { ($0.piece.square, $0) }
        )
        let lastMoveSquares = Set([board.lastMove?.from, board.lastMove?.to].compactMap { $0 })

        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(Array(BoardPerspective.squares(for: perspective).enumerated()), id: \.element) {
                index, square in
                let piece = boardPieces[square]
                BoardSquareView(
                    square: square,
                    piece: piece,
                    isLight: isLightSquare(square),
                    isSelected: false,
                    isDestination: false,
                    isLastMove: lastMoveSquares.contains(square),
                    isCheckedKing: board.inCheck
                        && piece?.role == .king
                        && piece?.color == board.turn,
                    showsRank: index.isMultiple(of: 8),
                    showsFile: index >= 56,
                    presentation: presentation
                )
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let renderedPiece = animatedPieces[square] {
                        AnimatedPieceView(
                            piece: renderedPiece.piece,
                            presentation: presentation
                        )
                            .matchedGeometryEffect(id: renderedPiece.id, in: pieceAnimation)
                            .transition(presentation.pieceAppearanceTransition)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel(for: square, piece: piece))
            }
        }
        .boardChrome(presentation)
        .onChange(of: board.pieces) { _, pieces in
            updateRenderedPieces(pieces)
        }
    }

    private func updateRenderedPieces(_ pieces: [BoardPiece]) {
        let next = RenderedBoardPiece.reconcile(
            previous: renderedPieces,
            current: pieces,
            lastMove: board.lastMove
        )
        let shouldAnimate = !reduceMotion
            && abs(Int(board.ply) - Int(renderedPly))
                <= Int(presentation.motion.maximumAnimatedPlyDistance)
        withAnimation(
            shouldAnimate
                ? presentation.motion.pieceMove.nativeAnimation(reduceMotion: false)
                : nil
        ) {
            renderedPieces = next
            renderedPly = board.ply
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

private struct GameReviewInspector: View {
    @EnvironmentObject private var store: LibChessStore
    let game: GameHistoryEntry
    let review: GameReview
    let selectedPly: UInt32
    let selectPly: (UInt32) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        gameSummary

                        if !evaluatedMoves.isEmpty {
                            analysisChart
                        }

                        selectedMoveAnalysis

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Moves")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)

                            moveList
                        }
                    }
                    .padding(16)
                }
                .onChange(of: selectedPly) { _, ply in
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(ply, anchor: .center)
                    }
                }
            }

            Divider()

            reviewControls
                .padding(12)
        }
    }

    private var gameSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(game.playerColor == .white ? .white : .black)
                    .frame(width: 22, height: 22)
                    .overlay { Circle().stroke(.secondary, lineWidth: 1) }

                VStack(alignment: .leading, spacing: 2) {
                    Text("vs \(game.opponentDisplayName)")
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(resultText) · \(game.variantName) · \(game.speed.displayName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let opening = review.opening {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(opening.name)
                            .lineLimit(2)
                        Text(opening.eco)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "book.closed")
                        .foregroundStyle(.secondary)
                }
            }

            if !judgments.isEmpty {
                HStack(spacing: 14) {
                    JudgmentCount(label: "Inaccuracies", count: judgmentCount(.inaccuracy), color: .yellow)
                    JudgmentCount(label: "Mistakes", count: judgmentCount(.mistake), color: .orange)
                    JudgmentCount(label: "Blunders", count: judgmentCount(.blunder), color: .red)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
    }

    private var analysisChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Evaluation")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let evaluation = selectedEvaluation {
                    Text(evaluation.displayText)
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
            }

            Chart {
                RuleMark(y: .value("Equal", 0))
                    .foregroundStyle(.secondary.opacity(0.35))

                ForEach(evaluatedMoves, id: \.ply) { move in
                    LineMark(
                        x: .value("Ply", move.ply),
                        y: .value("Evaluation", move.evaluation.chartValue)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color.accentColor)
                }

                RuleMark(x: .value("Selected", selectedPly))
                    .foregroundStyle(.primary.opacity(0.4))
            }
            .chartYScale(domain: -10 ... 10)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 92)
            .contentShape(Rectangle())
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var selectedMoveAnalysis: some View {
        if selectedPly == 0 {
            Label("Starting position", systemImage: "flag.pattern.checkered")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        } else if let move = selectedMove, let evaluation = move.evaluation {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(moveTitle(move))
                        .font(.headline)
                    Spacer()
                    Text(evaluation.displayText)
                        .font(.body.monospacedDigit().weight(.semibold))
                }

                if let judgment = evaluation.judgment {
                    Label(judgment.kind.displayName, systemImage: judgment.kind.symbolName)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(judgment.kind.color)
                    Text(judgment.comment)
                        .font(.callout)
                }

                if let bestMove = evaluation.bestMove {
                    LabeledContent("Best move", value: bestMove)
                        .font(.callout)
                }

                if let variation = evaluation.variation {
                    Text("Suggested line")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(variation)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        } else if selectedPly > 0 {
            ContentUnavailableView {
                Label("No Engine Evaluation", systemImage: "gauge.with.dots.needle.0percent")
            } description: {
                Text(
                    evaluatedMoves.isEmpty
                        ? "\(store.selectedBackend?.displayName ?? "The selected backend") has not produced computer analysis for this game. Move replay and PGN export remain available here."
                        : "This move has no stored engine annotation."
                )
            }
            .frame(minHeight: 110)
        }
    }

    private var moveList: some View {
        LazyVGrid(
            columns: [
                GridItem(.fixed(30), alignment: .trailing),
                GridItem(.flexible(), spacing: 5),
                GridItem(.flexible(), spacing: 5),
            ],
            alignment: .leading,
            spacing: 5
        ) {
            ForEach(Array(movePairs.enumerated()), id: \.element.number) { _, pair in
                Text("\(pair.number).")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)

                reviewMoveButton(pair.white)

                if let black = pair.black {
                    reviewMoveButton(black)
                } else {
                    Color.clear.frame(height: 28)
                }
            }
        }
    }

    private func reviewMoveButton(_ move: GameReviewMove) -> some View {
        Button {
            selectPly(move.ply)
        } label: {
            HStack(spacing: 4) {
                Text(move.san)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                if let judgment = move.evaluation?.judgment {
                    Image(systemName: judgment.kind.symbolName)
                        .font(.caption2)
                        .foregroundStyle(judgment.kind.color)
                }
                Spacer(minLength: 1)
            }
            .padding(.horizontal, 7)
            .frame(height: 28)
            .background(
                selectedPly == move.ply ? Color.accentColor.opacity(0.18) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
        }
        .buttonStyle(.plain)
        .id(move.ply)
    }

    private var reviewControls: some View {
        HStack(spacing: 8) {
            Button {
                selectPly(0)
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .disabled(selectedPly == 0)

            Button {
                selectPly(selectedPly - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(selectedPly == 0)

            Spacer()

            Text("\(selectedPly) / \(review.moves.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                selectPly(selectedPly + 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(selectedPly >= UInt32(review.moves.count))

            Button {
                selectPly(UInt32(review.moves.count))
            } label: {
                Image(systemName: "forward.end.fill")
            }
            .disabled(selectedPly >= UInt32(review.moves.count))
        }
        .buttonStyle(.borderless)
    }

    private var selectedMove: GameReviewMove? {
        guard selectedPly > 0 else {
            return nil
        }
        return review.moves[Int(selectedPly - 1)]
    }

    private var selectedEvaluation: GameMoveEvaluation? {
        selectedMove?.evaluation
    }

    private var evaluatedMoves: [EvaluatedReviewMove] {
        review.moves.compactMap { move in
            move.evaluation.map { EvaluatedReviewMove(ply: move.ply, evaluation: $0) }
        }
    }

    private var judgments: [GameMoveJudgment] {
        review.moves.compactMap { $0.evaluation?.judgment }
    }

    private func judgmentCount(_ kind: GameMoveJudgmentKind) -> Int {
        judgments.filter { $0.kind == kind }.count
    }

    private var movePairs: [ReviewMovePair] {
        stride(from: 0, to: review.moves.count, by: 2).map { index in
            ReviewMovePair(
                number: index / 2 + 1,
                white: review.moves[index],
                black: review.moves.indices.contains(index + 1) ? review.moves[index + 1] : nil
            )
        }
    }

    private func moveTitle(_ move: GameReviewMove) -> String {
        move.ply.isMultiple(of: 2)
            ? "\((move.ply + 1) / 2)… \(move.san)"
            : "\((move.ply + 1) / 2). \(move.san)"
    }

    private var resultText: String {
        guard let winner = game.winner else {
            return game.status == "aborted" ? "Aborted" : "Draw"
        }
        return winner == game.playerColor ? "Won" : "Lost"
    }
}

private struct JudgmentCount: View {
    let label: String
    let count: Int
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(count)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct ReviewMovePair {
    let number: Int
    let white: GameReviewMove
    let black: GameReviewMove?
}

private struct EvaluatedReviewMove {
    let ply: UInt32
    let evaluation: GameMoveEvaluation
}

private extension GameMoveEvaluation {
    var displayText: String {
        if let mate {
            return mate >= 0 ? "M\(mate)" : "−M\(-mate)"
        }
        guard let centipawns else {
            return "—"
        }
        return String(format: "%+.2f", Double(centipawns) / 100)
    }

    var chartValue: Double {
        if let mate {
            return mate >= 0 ? 10 : -10
        }
        return min(10, max(-10, Double(centipawns ?? 0) / 100))
    }
}

private extension GameMoveJudgmentKind {
    var displayName: String {
        switch self {
        case .inaccuracy: "Inaccuracy"
        case .mistake: "Mistake"
        case .blunder: "Blunder"
        }
    }

    var symbolName: String {
        switch self {
        case .inaccuracy: "questionmark.circle.fill"
        case .mistake: "exclamationmark.triangle.fill"
        case .blunder: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .inaccuracy: .yellow
        case .mistake: .orange
        case .blunder: .red
        }
    }
}

struct FloatingBoardView: View {
    @EnvironmentObject private var store: LibChessStore
    @Environment(\.openURL) private var openURL

    let gameID: String
    let closeWindow: () -> Void
    let showMainGame: (String) -> Void

    var body: some View {
        GeometryReader { geometry in
            if let game = store.liveGame(gameID),
               let presentation = store.boardPresentation
            {
                let boardExtent = min(geometry.size.width, geometry.size.height)

                ChessBoardView(
                    game: game,
                    boardExtent: boardExtent,
                    presentation: presentation,
                    showsPockets: false
                )
                .frame(width: boardExtent, height: boardExtent)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .contextMenu {
                    contextualGameActions(for: game)
                }
                .accessibilityLabel("Floating chessboard")
            }
        }
        .background(Color.clear)
        .onChange(of: store.liveGame(gameID)?.state.isPlayable) { wasPlayable, isPlayable in
            guard wasPlayable == true, isPlayable != true else {
                return
            }
            DispatchQueue.main.async {
                closeWindow()
            }
        }
    }

    @ViewBuilder
    private func contextualGameActions(for game: LiveGame) -> some View {
        let actionsAreBusy = store.isSubmittingMove(game.id)
            || store.isPerformingGameAction(game.id)

        if game.opponentDrawOfferForPlayer {
            Button("Accept Draw") {
                store.performGameAction(.acceptDraw, in: game.id)
            }
            .disabled(actionsAreBusy)

            Button("Decline Draw") {
                store.performGameAction(.declineDraw, in: game.id)
            }
            .disabled(actionsAreBusy)
        } else if game.opponentTakebackOfferForPlayer {
            Button("Accept Takeback") {
                store.performGameAction(.acceptTakeback, in: game.id)
            }
            .disabled(actionsAreBusy)

            Button("Decline Takeback") {
                store.performGameAction(.declineTakeback, in: game.id)
            }
            .disabled(actionsAreBusy)
        } else {
            Button(game.ownDrawOffer ? "Draw Offered" : "Offer Draw") {
                store.performGameAction(.offerDraw, in: game.id)
            }
            .disabled(actionsAreBusy || game.ownDrawOffer)

            Button(game.ownTakebackOffer ? "Takeback Requested" : "Request Takeback") {
                store.performGameAction(.offerTakeback, in: game.id)
            }
            .disabled(actionsAreBusy || game.ownTakebackOffer)
        }

        if game.canClaimVictory {
            Button("Claim Victory") {
                store.performGameAction(.claimVictory, in: game.id)
            }
            .disabled(actionsAreBusy)
        }

        Button("Claim Draw") {
            store.performGameAction(.claimDraw, in: game.id)
        }
        .disabled(actionsAreBusy)

        if !store.isLiveStreamConnected(game.id) {
            Button("Reconnect Live Updates") {
                store.reconnectLiveGame(game.id)
            }
            .disabled(store.isLoadingLiveGame(game.id))
        }

        Divider()

        Menu {
            Button("Confirm \(game.terminationActionTitle)", role: .destructive) {
                store.performGameAction(game.terminationAction, in: game.id)
            }
        } label: {
            Label(
                "\(game.terminationActionTitle)…",
                systemImage: game.terminationAction == .abort ? "xmark" : "flag.fill"
            )
        }
        .disabled(actionsAreBusy)

        Divider()

        Button {
            showMainGame(game.id)
        } label: {
            Label("Show Full Game", systemImage: "macwindow")
        }

        if !game.url.isEmpty, let url = URL(string: game.url) {
            Button {
                openURL(url)
            } label: {
                Label("Open on \(store.selectedBackend?.displayName ?? "Web")", systemImage: "safari")
            }
        }

        Button {
            DispatchQueue.main.async {
                closeWindow()
            }
        } label: {
            Label("Close Floating Board", systemImage: "xmark.circle")
        }
    }
}

private struct ChessBoardView: View {
    @EnvironmentObject private var store: LibChessStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let game: LiveGame
    let boardExtent: CGFloat
    let presentation: BoardPresentation
    let showsPockets: Bool

    @State private var selectedSquare: String?
    @State private var selectedDrop: PieceRole?
    @State private var promotionMoves: [LegalMove] = []
    @State private var renderedPieces: [RenderedBoardPiece]
    @State private var renderedPly: UInt32
    @Namespace private var pieceAnimation

    init(
        game: LiveGame,
        boardExtent: CGFloat,
        presentation: BoardPresentation,
        showsPockets: Bool = true
    ) {
        self.game = game
        self.boardExtent = boardExtent
        self.presentation = presentation
        self.showsPockets = showsPockets
        _renderedPieces = State(
            initialValue: game.state.board.pieces.map(RenderedBoardPiece.initial)
        )
        _renderedPly = State(initialValue: game.state.board.ply)
    }

    var body: some View {
        Group {
            if showsPockets {
                VStack(spacing: 9) {
                    PocketRow(
                        pieces: pockets(for: opponentColor),
                        selectedRole: $selectedDrop,
                        selectable: false,
                        legalDropRoles: [],
                        presentation: presentation
                    )

                    boardSurface

                    PocketRow(
                        pieces: pockets(for: game.playerColor),
                        selectedRole: $selectedDrop,
                        selectable: canMove,
                        legalDropRoles: legalDropRoles,
                        presentation: presentation
                    )
                }
            } else {
                boardSurface
            }
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

    private var boardSurface: some View {
        board
            .frame(width: boardExtent, height: boardExtent)
            .aspectRatio(1, contentMode: .fit)
            .boardChrome(presentation)
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
                        showsFile: index >= 56,
                        presentation: presentation
                    )
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let renderedPiece = animatedPieces[square] {
                            AnimatedPieceView(
                                piece: renderedPiece.piece,
                                presentation: presentation
                            )
                                .matchedGeometryEffect(
                                    id: renderedPiece.id,
                                    in: pieceAnimation
                                )
                                .transition(presentation.pieceAppearanceTransition)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityLabel(for: square, piece: piece))
            }
        }
        .animation(
            presentation.motion.selection.nativeAnimation(reduceMotion: reduceMotion),
            value: selectedSquare
        )
        .animation(
            presentation.motion.selection.nativeAnimation(reduceMotion: reduceMotion),
            value: selectedDrop
        )
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
            && abs(Int(boardState.ply) - Int(renderedPly))
                <= Int(presentation.motion.maximumAnimatedPlyDistance)
        withAnimation(
            shouldAnimate
                ? presentation.motion.pieceMove.nativeAnimation(reduceMotion: false)
                : nil
        ) {
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
    let presentation: BoardPresentation

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            PieceGlyph(
                role: piece.role,
                color: piece.color,
                size: size * CGFloat(presentation.pieces.metrics.scalePercent) / 100,
                presentation: presentation
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                if piece.promoted {
                    BoardAssetView(
                        asset: presentation.pieces.assets.promotedMarker,
                        size: size
                            * CGFloat(
                                presentation.pieces.metrics.promotedMarkerScalePercent
                            )
                            / 100
                    )
                        .foregroundStyle(presentation.pieces.palette.promotedMarker.color)
                        .padding(CGFloat(presentation.pieces.metrics.promotedMarkerInset))
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
    let presentation: BoardPresentation

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            ZStack {
                (isLight
                    ? presentation.board.palette.lightSquare.color
                    : presentation.board.palette.darkSquare.color)

                if isLastMove {
                    presentation.board.palette.lastMove.color
                }
                if isSelected {
                    presentation.board.palette.selection.color
                }
                if isCheckedKing {
                    RadialGradient(
                        colors: [
                            presentation.board.palette.checkCenter.color,
                            presentation.board.palette.checkEdge.color,
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: size
                            * CGFloat(
                                presentation.board.metrics.checkGradientRadiusPercent
                            )
                            / 100
                    )
                }

                if isDestination {
                    if piece == nil {
                        Circle()
                            .fill(presentation.board.palette.legalMove.color)
                            .frame(
                                width: size
                                    * CGFloat(
                                        presentation.board.metrics.destinationDotScalePercent
                                    )
                                    / 100,
                                height: size
                                    * CGFloat(
                                        presentation.board.metrics.destinationDotScalePercent
                                    )
                                    / 100
                            )
                    } else {
                        Circle()
                            .stroke(
                                presentation.board.palette.legalMove.color,
                                lineWidth: size
                                    * CGFloat(
                                        presentation.board.metrics.destinationRingWidthPercent
                                    )
                                    / 100
                            )
                            .padding(
                                size
                                    * CGFloat(
                                        presentation.board.metrics.destinationRingInsetPercent
                                    )
                                    / 100
                            )
                    }
                }

                if showsRank {
                    coordinateLabel(String(square.suffix(1)), size: size)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .topLeading
                        )
                }
                if showsFile {
                    coordinateLabel(String(square.prefix(1)), size: size)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: .bottomTrailing
                        )
                }
            }
        }
    }

    private func coordinateLabel(_ text: String, size: CGFloat) -> some View {
        Text(text)
            .font(.system(
                size: size
                    * CGFloat(presentation.board.metrics.coordinateFontScalePercent)
                    / 100,
                weight: .bold,
                design: .rounded
            ))
            .foregroundStyle(
                isLight
                    ? presentation.board.palette.coordinateOnLight.color
                    : presentation.board.palette.coordinateOnDark.color
            )
            .padding(CGFloat(presentation.board.metrics.coordinateInset))
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
    let presentation: BoardPresentation

    var body: some View {
        HStack(spacing: 6) {
            ForEach(pieces) { piece in
                Button {
                    selectedRole = selectedRole == piece.role ? nil : piece.role
                } label: {
                    HStack(spacing: 3) {
                        PieceGlyph(
                            role: piece.role,
                            color: piece.color,
                            size: 24,
                            presentation: presentation
                        )
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
    let presentation: BoardPresentation

    var body: some View {
        Group {
            if let asset = presentation.pieceAsset(for: role, color: color) {
                BoardAssetView(asset: asset, size: size)
            }
        }
        .foregroundStyle(
            color == .white
                ? presentation.pieces.palette.whitePiece.color
                : presentation.pieces.palette.blackPiece.color
        )
        .shadow(
            color: color == .white
                ? presentation.pieces.palette.whitePieceShadow.color
                : presentation.pieces.palette.blackPieceShadow.color,
            radius: CGFloat(presentation.pieces.metrics.shadowRadiusTenths) / 10,
            x: 0,
            y: CGFloat(presentation.pieces.metrics.shadowOffsetYTenths) / 10
        )
        .accessibilityHidden(true)
    }
}

private struct BoardAssetView: View {
    let asset: BoardAsset
    let size: CGFloat

    var body: some View {
        Group {
            switch asset.kind {
            case .textGlyph:
                Text(asset.value)
                    .font(.system(size: size, weight: .regular, design: .serif))
            case .svg:
                if let image = BoardAssetImageCache.shared.image(for: asset) {
                    Image(nsImage: image)
                        .resizable()
                        .renderingMode(asset.tintable ? .template : .original)
                        .scaledToFit()
                        .frame(width: size, height: size)
                }
            }
        }
    }
}

@MainActor
private final class BoardAssetImageCache {
    static let shared = BoardAssetImageCache()

    private var images: [String: NSImage] = [:]

    func image(for asset: BoardAsset) -> NSImage? {
        guard asset.kind == .svg else {
            return nil
        }
        let cacheKey = "\(asset.tintable):\(asset.value)"
        if let cached = images[cacheKey] {
            return cached
        }
        guard let data = asset.value.data(using: .utf8),
              let image = NSImage(data: data)
        else {
            return nil
        }
        image.isTemplate = asset.tintable
        images[cacheKey] = image
        return image
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
                    if !game.url.isEmpty, let url = URL(string: game.url) {
                        Link("Open on \(store.selectedBackend?.displayName ?? "Web")", destination: url)
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
                if !game.url.isEmpty, let url = URL(string: game.url) {
                    Link("View on \(store.selectedBackend?.displayName ?? "Web")", destination: url)
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
        game.opponentDrawOfferForPlayer
    }

    private var ownDrawOffer: Bool {
        game.ownDrawOffer
    }

    private var opponentTakebackOffer: Bool {
        game.opponentTakebackOfferForPlayer
    }

    private var ownTakebackOffer: Bool {
        game.ownTakebackOffer
    }

    private var canClaimVictory: Bool {
        game.canClaimVictory
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
        let moves = store.displayedMoves(for: game)
        return stride(from: 0, to: moves.count, by: 2).map { index in
            MovePair(
                number: index / 2 + 1,
                white: moves[index],
                black: moves.indices.contains(index + 1)
                    ? moves[index + 1]
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

private extension LiveGame {
    var opponentDrawOfferForPlayer: Bool {
        playerColor == .white ? state.blackDrawOffer : state.whiteDrawOffer
    }

    var ownDrawOffer: Bool {
        playerColor == .white ? state.whiteDrawOffer : state.blackDrawOffer
    }

    var opponentTakebackOfferForPlayer: Bool {
        playerColor == .white ? state.blackTakebackOffer : state.whiteTakebackOffer
    }

    var ownTakebackOffer: Bool {
        playerColor == .white ? state.whiteTakebackOffer : state.blackTakebackOffer
    }

    var canClaimVictory: Bool {
        state.opponentGone && state.claimWinInSeconds == 0
    }

    var terminationAction: LiveGameAction {
        state.board.ply < 2 ? .abort : .resign
    }

    var terminationActionTitle: String {
        terminationAction == .abort ? "Abort Game" : "Resign"
    }
}

private extension UInt64 {
    func saturatingSubtract(_ other: UInt64) -> UInt64 {
        self > other ? self - other : 0
    }
}

private extension RgbaColor {
    var color: Color {
        Color(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: Double(alpha) / 255
        )
    }
}

private extension BoardAnimationRule {
    func nativeAnimation(reduceMotion: Bool) -> Animation? {
        guard !reduceMotion else {
            return nil
        }

        let duration = Double(durationMillis) / 1_000
        switch curve {
        case .linear:
            return .linear(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        case .spring:
            return .snappy(
                duration: duration,
                extraBounce: Double(extraBouncePercent) / 100
            )
        }
    }
}

private extension BoardPresentation {
    var pieceAppearanceTransition: AnyTransition {
        let scale = AnyTransition.scale(
            scale: Double(motion.pieceAppearanceScalePercent) / 100
        )
        return motion.fadePieceAppearance ? scale.combined(with: .opacity) : scale
    }
}

private extension View {
    func boardChrome(_ presentation: BoardPresentation) -> some View {
        let cornerRadius = CGFloat(presentation.board.metrics.cornerRadius)
        return clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(
                        presentation.board.palette.border.color,
                        lineWidth: CGFloat(presentation.board.metrics.borderWidth)
                    )
            }
            .shadow(
                color: presentation.board.palette.shadow.color,
                radius: CGFloat(presentation.board.metrics.shadowRadius),
                y: CGFloat(presentation.board.metrics.shadowOffsetY)
            )
    }
}
