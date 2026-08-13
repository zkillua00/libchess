import AppKit
import LibChessKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: LibChessStore
    @State private var selection = SettingsSection.boards

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            switch selection {
            case .boards:
                BoardThemeSettingsView()
            case .pieces:
                PieceThemeSettingsView()
            }
        }
        .frame(minWidth: 640, minHeight: 500)
        .alert("LibChess", isPresented: errorIsPresented) {
            Button("OK") {
                store.message = nil
            }
        } message: {
            Text(store.message ?? "An unknown error occurred.")
        }
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { store.message != nil },
            set: { if !$0 { store.message = nil } }
        )
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case boards
    case pieces

    var id: Self { self }

    var title: String {
        switch self {
        case .boards: "Board Themes"
        case .pieces: "Piece Themes"
        }
    }

    var symbol: String {
        switch self {
        case .boards: "checkerboard.rectangle"
        case .pieces: "crown"
        }
    }
}

private struct BoardThemeSettingsView: View {
    @EnvironmentObject private var store: LibChessStore
    @State private var selection: ThemeKey?
    @State private var draft = BoardThemeDraft.placeholder
    @State private var confirmsRemoval = false

    var body: some View {
        ThemeEditorLayout(
            title: "Board Themes",
            subtitle: "Create color-only boards and derived palettes. Piece assets stay independent.",
            controls: { themeControls },
            editor: { editor }
        )
        .onAppear {
            if draft.provider.isEmpty {
                startNewTheme()
            }
        }
        .onChange(of: selection) { _, key in
            guard let key,
                  let theme = store.boardCustomization.boardThemes.first(where: {
                      $0.provider == key.provider && $0.id == key.id
                  })
            else {
                return
            }
            draft = BoardThemeDraft(
                theme: theme,
                fallback: store.boardPresentation?.board.palette
            )
        }
        .onChange(of: store.boardCustomization.boardThemes) { _, themes in
            guard let selection,
                  let theme = themes.first(where: {
                      $0.provider == selection.provider && $0.id == selection.id
                  })
            else {
                if selection != nil {
                    startNewTheme()
                }
                return
            }
            draft = BoardThemeDraft(theme: theme, fallback: store.boardPresentation?.board.palette)
        }
        .confirmationDialog(
            "Remove this board theme?",
            isPresented: $confirmsRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Theme", role: .destructive, action: removeSelectedTheme)
            Button("Cancel", role: .cancel) {}
        }
    }

    private var themeControls: some View {
        HStack(spacing: 8) {
            Text("Theme")
                .foregroundStyle(.secondary)

            Picker("Theme", selection: $selection) {
                Text("New Board Theme")
                    .tag(nil as ThemeKey?)
                ForEach(customThemes, id: \.key) { item in
                    Text(item.theme.displayName)
                        .tag(Optional(item.key))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 280)

            Button(action: startNewTheme) {
                Image(systemName: "plus")
            }
            .help("Create Board Theme")

            Button(role: .destructive) {
                confirmsRemoval = true
            } label: {
                Image(systemName: "minus")
            }
            .disabled(selection == nil || store.isSavingBoardCustomization)
            .help("Remove Board Theme")

            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ThemeIdentityForm(
                    name: $draft.name,
                    identifier: $draft.identifier,
                    provider: $draft.provider,
                    baseTheme: $draft.baseTheme,
                    providers: store.boardProviders,
                    baseThemes: baseThemes,
                    isEditing: selection != nil,
                    kindName: "board"
                )

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 22) {
                        boardColors
                            .frame(minWidth: 260, maxWidth: .infinity)

                        BoardPalettePreview(draft: draft)
                            .frame(width: 196, height: 196)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        boardColors
                            .frame(maxWidth: .infinity)

                        BoardPalettePreview(draft: draft)
                            .frame(width: 196, height: 196)
                    }
                }

                ThemeAdjustmentForm(
                    hue: $draft.hue,
                    saturation: $draft.saturation,
                    brightness: $draft.brightness
                )

                footer
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                footerText
                    .fixedSize(horizontal: true, vertical: false)
                Spacer()
                saveProgress
                saveButton
            }

            VStack(alignment: .leading, spacing: 10) {
                footerText
                HStack {
                    Spacer()
                    saveProgress
                    saveButton
                }
            }
        }
    }

    private var boardColors: some View {
        GroupBox("Board Colors") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                colorRow("Light squares", color: $draft.lightSquare)
                colorRow("Dark squares", color: $draft.darkSquare)
                colorRow("Last move", color: $draft.lastMove)
                colorRow("Selection", color: $draft.selection)
                colorRow("Legal moves", color: $draft.legalMove)
            }
            .padding(6)
        }
    }

    private var footerText: some View {
        Text("Filters are evaluated by LibChess and saved with the portable theme definition.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var saveProgress: some View {
        if store.isSavingBoardCustomization {
            ProgressView()
                .controlSize(.small)
        }
    }

    private var saveButton: some View {
        Button(selection == nil ? "Add Theme" : "Save Changes") {
            store.registerCustomBoardTheme(draft.theme)
        }
            .buttonStyle(.borderedProminent)
            .disabled(!draft.isValid || store.isSavingBoardCustomization)
    }

    private var customThemes: [(key: ThemeKey, theme: CustomBoardTheme)] {
        store.boardCustomization.boardThemes
            .map { (ThemeKey(provider: $0.provider, id: $0.id), $0) }
            .sorted { $0.theme.displayName.localizedStandardCompare($1.theme.displayName) == .orderedAscending }
    }

    private var baseThemes: [ThemeChoice] {
        guard let descriptor = store.boardProviders.first(where: { $0.id == draft.provider }) else {
            return []
        }
        let customIDs = Set(
            store.boardCustomization.boardThemes
                .filter { $0.provider == draft.provider }
                .map(\.id)
        )
        return descriptor.boardThemes
            .filter { !customIDs.contains($0.id) }
            .map { ThemeChoice(id: $0.id, displayName: $0.displayName) }
    }

    private func startNewTheme() {
        selection = nil
        let provider = store.boardProviders.first
        let palette = store.boardPresentation?.board.palette
        draft = BoardThemeDraft(
            provider: provider?.id ?? "libchess",
            identifier: nextIdentifier(prefix: "custom-board", existing: Set(customThemes.map(\.key.id))),
            baseTheme: provider?.defaultBoardTheme ?? "classic",
            palette: palette
        )
    }

    private func removeSelectedTheme() {
        guard let selection else {
            return
        }
        store.removeCustomBoardTheme(provider: selection.provider, theme: selection.id)
        self.selection = nil
    }
}

private struct PieceThemeSettingsView: View {
    @EnvironmentObject private var store: LibChessStore
    @State private var selection: ThemeKey?
    @State private var draft = PieceThemeDraft.placeholder
    @State private var importMessage: String?
    @State private var confirmsRemoval = false

    var body: some View {
        ThemeEditorLayout(
            title: "Piece Themes",
            subtitle: "Derive colors from an installed set or register six self-contained SVG assets.",
            controls: { themeControls },
            editor: { editor }
        )
        .onAppear {
            if draft.provider.isEmpty {
                startNewTheme()
            }
        }
        .onChange(of: selection) { _, key in
            guard let key,
                  let theme = store.boardCustomization.pieceThemes.first(where: {
                      $0.provider == key.provider && $0.id == key.id
                  })
            else {
                return
            }
            draft = PieceThemeDraft(
                theme: theme,
                fallback: store.boardPresentation?.pieces.palette
            )
            importMessage = nil
        }
        .onChange(of: store.boardCustomization.pieceThemes) { _, themes in
            guard let selection,
                  let theme = themes.first(where: {
                      $0.provider == selection.provider && $0.id == selection.id
                  })
            else {
                if selection != nil {
                    startNewTheme()
                }
                return
            }
            draft = PieceThemeDraft(theme: theme, fallback: store.boardPresentation?.pieces.palette)
        }
        .confirmationDialog(
            "Remove this piece theme?",
            isPresented: $confirmsRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Theme", role: .destructive, action: removeSelectedTheme)
            Button("Cancel", role: .cancel) {}
        }
    }

    private var themeControls: some View {
        HStack(spacing: 8) {
            Text("Theme")
                .foregroundStyle(.secondary)

            Picker("Theme", selection: $selection) {
                Text("New Piece Theme")
                    .tag(nil as ThemeKey?)
                ForEach(customThemes, id: \.key) { item in
                    Text(item.theme.displayName)
                        .tag(Optional(item.key))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 280)

            Button(action: startNewTheme) {
                Image(systemName: "plus")
            }
            .help("Create Piece Theme")

            Button(role: .destructive) {
                confirmsRemoval = true
            } label: {
                Image(systemName: "minus")
            }
            .disabled(selection == nil || store.isSavingBoardCustomization)
            .help("Remove Piece Theme")

            Spacer(minLength: 0)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }

    private var editor: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ThemeIdentityForm(
                    name: $draft.name,
                    identifier: $draft.identifier,
                    provider: $draft.provider,
                    baseTheme: $draft.baseTheme,
                    providers: store.boardProviders,
                    baseThemes: baseThemes,
                    isEditing: selection != nil,
                    kindName: "piece"
                )

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 22) {
                        pieceColors
                            .frame(minWidth: 260, maxWidth: .infinity)

                        PieceThemePreview(draft: draft)
                            .frame(width: 196, height: 112)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        pieceColors
                            .frame(maxWidth: .infinity)

                        PieceThemePreview(draft: draft)
                            .frame(width: 196, height: 112)
                    }
                }

                GroupBox("Assets") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(draft.assets == nil
                            ? "Using assets from the base theme."
                            : "Six SVG roles are registered with this theme.")
                            .foregroundStyle(.secondary)

                        HStack {
                            Button("Import SVG Folder…", action: importSVGFolder)
                            if draft.assets != nil {
                                Button("Use Base Assets", role: .destructive) {
                                    draft.assets = nil
                                    importMessage = nil
                                }
                            }
                        }
                        if let importMessage {
                            Text(importMessage)
                                .font(.caption)
                                .foregroundStyle(
                                    importMessage.hasPrefix("Imported")
                                        ? Color.secondary
                                        : Color.red
                                )
                        }
                        Text("The folder must contain pawn.svg, knight.svg, bishop.svg, rook.svg, queen.svg, and king.svg. LibChess rejects scripts and external references.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }

                ThemeAdjustmentForm(
                    hue: $draft.hue,
                    saturation: $draft.saturation,
                    brightness: $draft.brightness
                )

                footer
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                footerText
                    .fixedSize(horizontal: true, vertical: false)
                Spacer()
                saveProgress
                saveButton
            }

            VStack(alignment: .leading, spacing: 10) {
                footerText
                HStack {
                    Spacer()
                    saveProgress
                    saveButton
                }
            }
        }
    }

    private var pieceColors: some View {
        GroupBox("Piece Colors") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                colorRow("White pieces", color: $draft.whitePiece)
                colorRow("Black pieces", color: $draft.blackPiece)
                colorRow("Promoted marker", color: $draft.promotedMarker)
            }
            .padding(6)
        }
    }

    private var footerText: some View {
        Text("SVG validation and color transforms remain in the portable LibChess layer.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var saveProgress: some View {
        if store.isSavingBoardCustomization {
            ProgressView()
                .controlSize(.small)
        }
    }

    private var saveButton: some View {
        Button(selection == nil ? "Add Theme" : "Save Changes") {
            store.registerCustomPieceTheme(draft.theme)
        }
            .buttonStyle(.borderedProminent)
            .disabled(!draft.isValid || store.isSavingBoardCustomization)
    }

    private var customThemes: [(key: ThemeKey, theme: CustomPieceTheme)] {
        store.boardCustomization.pieceThemes
            .map { (ThemeKey(provider: $0.provider, id: $0.id), $0) }
            .sorted { $0.theme.displayName.localizedStandardCompare($1.theme.displayName) == .orderedAscending }
    }

    private var baseThemes: [ThemeChoice] {
        guard let descriptor = store.boardProviders.first(where: { $0.id == draft.provider }) else {
            return []
        }
        let customIDs = Set(
            store.boardCustomization.pieceThemes
                .filter { $0.provider == draft.provider }
                .map(\.id)
        )
        return descriptor.pieceThemes
            .filter { !customIDs.contains($0.id) }
            .map { ThemeChoice(id: $0.id, displayName: $0.displayName) }
    }

    private func startNewTheme() {
        selection = nil
        importMessage = nil
        let provider = store.boardProviders.first
        let palette = store.boardPresentation?.pieces.palette
        draft = PieceThemeDraft(
            provider: provider?.id ?? "libchess",
            identifier: nextIdentifier(prefix: "custom-pieces", existing: Set(customThemes.map(\.key.id))),
            baseTheme: provider?.defaultPieceTheme ?? "system-solid",
            palette: palette
        )
    }

    private func removeSelectedTheme() {
        guard let selection else {
            return
        }
        store.removeCustomPieceTheme(provider: selection.provider, theme: selection.id)
        self.selection = nil
    }

    private func importSVGFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Chess Piece SVG Folder"
        panel.prompt = "Import"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else {
            return
        }

        do {
            var assets: [PieceRole: String] = [:]
            for role in PieceRole.allCases {
                let url = directory.appendingPathComponent("\(role.rawValue).svg")
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                guard data.count <= 65_536, let value = String(data: data, encoding: .utf8) else {
                    throw ThemeImportError.invalidSVG(role.rawValue)
                }
                assets[role] = value
            }
            draft.assets = assets
            importMessage = "Imported \(directory.lastPathComponent)."
        } catch {
            importMessage = "Could not import the complete SVG set: \(error.localizedDescription)"
        }
    }
}

private struct ThemeEditorLayout<Controls: View, Editor: View>: View {
    let title: String
    let subtitle: String
    let controls: Controls
    let editor: Editor

    init(
        title: String,
        subtitle: String,
        @ViewBuilder controls: () -> Controls,
        @ViewBuilder editor: () -> Editor
    ) {
        self.title = title
        self.subtitle = subtitle
        self.controls = controls()
        self.editor = editor()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()
            controls
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
            Divider()
            editor
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(title)
    }
}

private struct ThemeIdentityForm: View {
    @Binding var name: String
    @Binding var identifier: String
    @Binding var provider: String
    @Binding var baseTheme: String
    let providers: [BoardProviderDescriptor]
    let baseThemes: [ThemeChoice]
    let isEditing: Bool
    let kindName: String

    var body: some View {
        GroupBox("Identity") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                GridRow {
                    Text("Name")
                    TextField("Theme name", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Identifier")
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("stable-identifier", text: $identifier)
                            .textFieldStyle(.roundedBorder)
                            .disabled(isEditing)
                        Text("Lowercase letters, numbers, and hyphens; fixed after creation.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text("Provider")
                    Picker("", selection: $provider) {
                        ForEach(providers) { descriptor in
                            Text(descriptor.displayName).tag(descriptor.id)
                        }
                    }
                    .labelsHidden()
                    .disabled(isEditing)
                }
                GridRow {
                    Text("Base \(kindName)")
                    Picker("", selection: $baseTheme) {
                        ForEach(baseThemes) { theme in
                            Text(theme.displayName).tag(theme.id)
                        }
                    }
                    .labelsHidden()
                }
            }
            .padding(6)
        }
    }

}

private struct ThemeAdjustmentForm: View {
    @Binding var hue: Double
    @Binding var saturation: Double
    @Binding var brightness: Double

    var body: some View {
        GroupBox("Color Adjustment") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                sliderRow("Hue", value: $hue, range: -180 ... 180, suffix: "°")
                sliderRow("Saturation", value: $saturation, range: -100 ... 100, suffix: "%")
                sliderRow("Brightness", value: $brightness, range: -100 ... 100, suffix: "%")
            }
            .padding(6)
        }
    }

    private func sliderRow(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String
    ) -> some View {
        GridRow {
            Text(title)
                .frame(width: 82, alignment: .leading)
            Slider(value: value, in: range, step: 1)
            Text("\(Int(value.wrappedValue))\(suffix)")
                .monospacedDigit()
                .frame(width: 50, alignment: .trailing)
        }
    }
}

private struct BoardPalettePreview: View {
    let draft: BoardThemeDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Palette")
                .font(.headline)
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(0 ..< 8, id: \.self) { rank in
                    GridRow {
                        ForEach(0 ..< 8, id: \.self) { file in
                            Rectangle()
                                .fill((rank + file).isMultiple(of: 2)
                                    ? draft.lightSquare
                                    : draft.darkSquare)
                                .overlay {
                                    if rank == 4, file == 4 {
                                        draft.lastMove
                                    } else if rank == 3, file == 3 {
                                        draft.selection
                                    }
                                }
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
        }
    }
}

private struct PieceThemePreview: View {
    let draft: PieceThemeDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Assets")
                .font(.headline)
            HStack(spacing: 6) {
                ForEach(PieceRole.allCases) { role in
                    piece(role)
                        .frame(width: 24, height: 34)
                }
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func piece(_ role: PieceRole) -> some View {
        if let svg = draft.assets?[role],
           let data = svg.data(using: .utf8),
           let image = NSImage(data: data)
        {
            Image(nsImage: image)
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .foregroundStyle(draft.blackPiece)
        } else {
            Text(role.previewGlyph)
                .font(.system(size: 28, design: .serif))
                .foregroundStyle(draft.blackPiece)
        }
    }
}

private struct BoardThemeDraft: Equatable {
    var provider: String
    var identifier: String
    var name: String
    var baseTheme: String
    var lightSquare: Color
    var darkSquare: Color
    var lastMove: Color
    var selection: Color
    var legalMove: Color
    var hue: Double
    var saturation: Double
    var brightness: Double

    static let placeholder = BoardThemeDraft(
        provider: "",
        identifier: "",
        baseTheme: "",
        palette: nil
    )

    init(provider: String, identifier: String, baseTheme: String, palette: BoardPalette?) {
        self.provider = provider
        self.identifier = identifier
        name = "My Board"
        self.baseTheme = baseTheme
        lightSquare = Color(palette?.lightSquare ?? RgbaColor(red: 212, green: 196, blue: 166))
        darkSquare = Color(palette?.darkSquare ?? RgbaColor(red: 107, green: 133, blue: 89))
        lastMove = Color(palette?.lastMove ?? RgbaColor(red: 255, green: 204, blue: 0, alpha: 107))
        selection = Color(palette?.selection ?? RgbaColor(red: 10, green: 132, blue: 255, alpha: 122))
        legalMove = Color(palette?.legalMove ?? RgbaColor(red: 0, green: 0, blue: 0, alpha: 84))
        hue = 0
        saturation = 0
        brightness = 0
    }

    init(theme: CustomBoardTheme, fallback: BoardPalette?) {
        provider = theme.provider
        identifier = theme.id
        name = theme.displayName
        baseTheme = theme.baseTheme
        lightSquare = Color(theme.colors.lightSquare ?? fallback?.lightSquare ?? RgbaColor(red: 212, green: 196, blue: 166))
        darkSquare = Color(theme.colors.darkSquare ?? fallback?.darkSquare ?? RgbaColor(red: 107, green: 133, blue: 89))
        lastMove = Color(theme.colors.lastMove ?? fallback?.lastMove ?? RgbaColor(red: 255, green: 204, blue: 0, alpha: 107))
        selection = Color(theme.colors.selection ?? fallback?.selection ?? RgbaColor(red: 10, green: 132, blue: 255, alpha: 122))
        legalMove = Color(theme.colors.legalMove ?? fallback?.legalMove ?? RgbaColor(red: 0, green: 0, blue: 0, alpha: 84))
        hue = Double(theme.adjustment.hueDegrees)
        saturation = Double(theme.adjustment.saturationPercent)
        brightness = Double(theme.adjustment.brightnessPercent)
    }

    var isValid: Bool {
        !provider.isEmpty && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && identifier.isStableThemeIdentifier && !baseTheme.isEmpty
    }

    var theme: CustomBoardTheme {
        CustomBoardTheme(
            provider: provider,
            id: identifier,
            displayName: name.trimmingCharacters(in: .whitespacesAndNewlines),
            baseTheme: baseTheme,
            adjustment: ThemeColorAdjustment(
                hueDegrees: Int16(hue),
                saturationPercent: Int8(saturation),
                brightnessPercent: Int8(brightness)
            ),
            colors: BoardColorOverrides(
                lightSquare: lightSquare.rgba,
                darkSquare: darkSquare.rgba,
                lastMove: lastMove.rgba,
                selection: selection.rgba,
                legalMove: legalMove.rgba
            )
        )
    }
}

private struct PieceThemeDraft: Equatable {
    var provider: String
    var identifier: String
    var name: String
    var baseTheme: String
    var whitePiece: Color
    var blackPiece: Color
    var promotedMarker: Color
    var hue: Double
    var saturation: Double
    var brightness: Double
    var assets: [PieceRole: String]?

    static let placeholder = PieceThemeDraft(
        provider: "",
        identifier: "",
        baseTheme: "",
        palette: nil
    )

    init(provider: String, identifier: String, baseTheme: String, palette: PiecePalette?) {
        self.provider = provider
        self.identifier = identifier
        name = "My Pieces"
        self.baseTheme = baseTheme
        whitePiece = Color(palette?.whitePiece ?? RgbaColor(red: 255, green: 255, blue: 255))
        blackPiece = Color(palette?.blackPiece ?? RgbaColor(red: 23, green: 23, blue: 20))
        promotedMarker = Color(palette?.promotedMarker ?? RgbaColor(red: 255, green: 204, blue: 0))
        hue = 0
        saturation = 0
        brightness = 0
        assets = nil
    }

    init(theme: CustomPieceTheme, fallback: PiecePalette?) {
        provider = theme.provider
        identifier = theme.id
        name = theme.displayName
        baseTheme = theme.baseTheme
        whitePiece = Color(theme.colors.whitePiece ?? fallback?.whitePiece ?? RgbaColor(red: 255, green: 255, blue: 255))
        blackPiece = Color(theme.colors.blackPiece ?? fallback?.blackPiece ?? RgbaColor(red: 23, green: 23, blue: 20))
        promotedMarker = Color(theme.colors.promotedMarker ?? fallback?.promotedMarker ?? RgbaColor(red: 255, green: 204, blue: 0))
        hue = Double(theme.adjustment.hueDegrees)
        saturation = Double(theme.adjustment.saturationPercent)
        brightness = Double(theme.adjustment.brightnessPercent)
        assets = theme.assets.map { value in
            Dictionary(uniqueKeysWithValues: value.pieces.map { ($0.role, $0.asset.value) })
        }
    }

    var isValid: Bool {
        !provider.isEmpty && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && identifier.isStableThemeIdentifier && !baseTheme.isEmpty
            && (assets == nil || assets?.count == PieceRole.allCases.count)
    }

    var theme: CustomPieceTheme {
        CustomPieceTheme(
            provider: provider,
            id: identifier,
            displayName: name.trimmingCharacters(in: .whitespacesAndNewlines),
            baseTheme: baseTheme,
            adjustment: ThemeColorAdjustment(
                hueDegrees: Int16(hue),
                saturationPercent: Int8(saturation),
                brightnessPercent: Int8(brightness)
            ),
            colors: PieceColorOverrides(
                whitePiece: whitePiece.rgba,
                blackPiece: blackPiece.rgba,
                promotedMarker: promotedMarker.rgba
            ),
            assets: assets.map { values in
                CustomPieceAssets(
                    pieces: PieceRole.allCases.compactMap { role in
                        values[role].map {
                            CustomPieceAsset(
                                role: role,
                                asset: BoardAsset(kind: .svg, value: $0, tintable: true)
                            )
                        }
                    }
                )
            }
        )
    }
}

private struct ThemeKey: Hashable {
    let provider: String
    let id: String
}

private struct ThemeChoice: Hashable, Identifiable {
    let id: String
    let displayName: String
}

private enum ThemeImportError: LocalizedError {
    case invalidSVG(String)

    var errorDescription: String? {
        switch self {
        case let .invalidSVG(role):
            "\(role).svg is not a UTF-8 SVG smaller than 64 KiB."
        }
    }
}

private func colorRow(_ title: String, color: Binding<Color>) -> some View {
    GridRow {
        Text(title)
        ColorPicker("", selection: color, supportsOpacity: true)
            .labelsHidden()
    }
}

private func nextIdentifier(prefix: String, existing: Set<String>) -> String {
    if !existing.contains(prefix) {
        return prefix
    }
    var suffix = 2
    while existing.contains("\(prefix)-\(suffix)") {
        suffix += 1
    }
    return "\(prefix)-\(suffix)"
}

private extension String {
    var isStableThemeIdentifier: Bool {
        !isEmpty && count <= 64
            && utf8.allSatisfy {
                $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == 45)
            }
    }
}

private extension UInt8 {
    var isASCII: Bool { self < 128 }
    var isLowercase: Bool { (97 ... 122).contains(self) }
    var isNumber: Bool { (48 ... 57).contains(self) }
}

private extension Color {
    init(_ value: RgbaColor) {
        self.init(
            .sRGB,
            red: Double(value.red) / 255,
            green: Double(value.green) / 255,
            blue: Double(value.blue) / 255,
            opacity: Double(value.alpha) / 255
        )
    }

    var rgba: RgbaColor {
        let converted = NSColor(self).usingColorSpace(.sRGB) ?? NSColor(self)
        return RgbaColor(
            red: converted.redComponent.byte,
            green: converted.greenComponent.byte,
            blue: converted.blueComponent.byte,
            alpha: converted.alphaComponent.byte
        )
    }
}

private extension CGFloat {
    var byte: UInt8 {
        UInt8((clamped(to: 0 ... 1) * 255).rounded())
    }

    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private extension PieceRole {
    var previewGlyph: String {
        switch self {
        case .pawn: "♟"
        case .knight: "♞"
        case .bishop: "♝"
        case .rook: "♜"
        case .queen: "♛"
        case .king: "♚"
        }
    }
}
