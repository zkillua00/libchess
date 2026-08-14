import AppKit
import Combine
import LibChessKit
import SwiftUI

extension Notification.Name {
    static let showNewGame = Notification.Name("org.libchess.macos.show-new-game")
    static let showGame = Notification.Name("org.libchess.macos.show-game")
    static let showFloatingBoard = Notification.Name("org.libchess.macos.show-floating-board")
}

@main
@MainActor
enum LibChessMacApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()

        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.finishLaunching()
        application.run()
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let store = LibChessStore()
    private var launcherPanel: NSPanel?
    private var workspaceWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var settingsWindowCoordinator: SettingsWindowCoordinator?
    private var floatingBoardWindowCoordinator: FloatingBoardWindowCoordinator?
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let application = notification.object as? NSApplication ?? NSApplication.shared
        application.mainMenu = makeMainMenu(for: application)
        floatingBoardWindowCoordinator = FloatingBoardWindowCoordinator(
            store: store,
            showMainGame: { [weak self] gameID in
                self?.showGameInMainWindow(gameID)
            }
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(showFloatingBoard(_:)),
            name: .showFloatingBoard,
            object: nil
        )
        observeWorkspaceReadiness()
        synchronizeWindows()
        application.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        floatingBoardWindowCoordinator?.close()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if store.handleOpenURL(url) {
                showLauncher()
                application.activate(ignoringOtherApps: true)
                return
            }
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows _: Bool
    ) -> Bool {
        if workspaceIsReady {
            showWorkspace()
        } else {
            showLauncher()
        }
        return true
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(showNewGame(_:)) {
            return workspaceIsReady
        }
        if menuItem.action == #selector(showFocusedGameInFloatingWindow(_:)) {
            guard let gameID = store.focusedGameID,
                  let game = store.liveGame(gameID)
            else {
                return false
            }
            return game.state.isPlayable && store.boardPresentation != nil
        }
        return true
    }

    private var workspaceIsReady: Bool {
        store.connectionState == .connected
            && store.selectedBackend?.id == store.account?.provider
    }

    private func observeWorkspaceReadiness() {
        Publishers.CombineLatest3(
            store.$connectionState,
            store.$selectedBackend,
            store.$account
        )
        .sink { [weak self] connectionState, selectedBackend, account in
            self?.synchronizeWindows(
                workspaceReady: connectionState == .connected
                    && selectedBackend?.id == account?.provider
            )
        }
        .store(in: &subscriptions)
    }

    private func synchronizeWindows() {
        synchronizeWindows(workspaceReady: workspaceIsReady)
    }

    private func synchronizeWindows(workspaceReady: Bool) {
        if workspaceReady {
            showWorkspace()
        } else {
            workspaceWindow?.orderOut(nil)
            floatingBoardWindowCoordinator?.close()
            showLauncher()
        }
    }

    private func showLauncher() {
        let panel = launcherPanel ?? makeLauncherPanel()
        launcherPanel = panel
        if panel.isVisible {
            panel.makeKey()
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func makeLauncherPanel() -> NSPanel {
        let size = NSSize(width: 760, height: 470)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Welcome to LibChess"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = true
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentMinSize = size
        panel.contentMaxSize = size
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.contentView = NSHostingView(
            rootView: BackendLauncherView()
                .environmentObject(store)
                .frame(width: size.width, height: size.height)
        )
        return panel
    }

    private func showWorkspace() {
        launcherPanel?.orderOut(nil)

        let window = workspaceWindow ?? makeWorkspaceWindow()
        workspaceWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWorkspaceWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_120, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "LibChess"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.contentMinSize = NSSize(width: 760, height: 520)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: ContentView()
                .environmentObject(store)
                .frame(minWidth: 760, minHeight: 520)
        )
        window.center()
        return window
    }

    private func makeMainMenu(for application: NSApplication) -> NSMenu {
        let mainMenu = NSMenu()

        let applicationMenuItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "LibChess")
        applicationMenu.addItem(
            item(
                "About LibChess",
                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:))
            )
        )
        applicationMenu.addItem(
            item(
                "Settings…",
                action: #selector(showSettings(_:)),
                key: ",",
                target: self
            )
        )
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            item("Hide LibChess", action: #selector(NSApplication.hide(_:)), key: "h")
        )
        applicationMenu.addItem(
            item(
                "Hide Others",
                action: #selector(NSApplication.hideOtherApplications(_:)),
                key: "h",
                modifiers: [.command, .option]
            )
        )
        applicationMenu.addItem(
            item("Show All", action: #selector(NSApplication.unhideAllApplications(_:)))
        )
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            item("Quit LibChess", action: #selector(NSApplication.terminate(_:)), key: "q")
        )
        applicationMenuItem.submenu = applicationMenu
        mainMenu.addItem(applicationMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(
            item(
                "New Game",
                action: #selector(showNewGame(_:)),
                key: "n",
                target: self
            )
        )
        fileMenu.addItem(.separator())
        fileMenu.addItem(
            item("Close Window", action: #selector(NSWindow.performClose(_:)), key: "w")
        )
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(item("Undo", action: Selector(("undo:")), key: "z"))
        editMenu.addItem(
            item(
                "Redo",
                action: Selector(("redo:")),
                key: "z",
                modifiers: [.command, .shift]
            )
        )
        editMenu.addItem(.separator())
        editMenu.addItem(item("Cut", action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(item("Copy", action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(item("Paste", action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(item("Select All", action: #selector(NSText.selectAll(_:)), key: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(
            item(
                "Toggle Sidebar",
                action: #selector(NSSplitViewController.toggleSidebar(_:)),
                key: "s",
                modifiers: [.command, .control]
            )
        )
        viewMenu.addItem(.separator())
        viewMenu.addItem(
            item(
                "Increase Board Size",
                action: #selector(increaseBoardSize(_:)),
                key: "+",
                target: self
            )
        )
        viewMenu.addItem(
            item(
                "Decrease Board Size",
                action: #selector(decreaseBoardSize(_:)),
                key: "-",
                target: self
            )
        )
        viewMenu.addItem(
            item(
                "Default Board Size",
                action: #selector(resetBoardSize(_:)),
                key: "0",
                target: self
            )
        )
        viewMenu.addItem(.separator())
        viewMenu.addItem(
            item(
                "Show Floating Board",
                action: #selector(showFocusedGameInFloatingWindow(_:)),
                key: "b",
                modifiers: [.command, .control],
                target: self
            )
        )
        viewMenu.addItem(.separator())
        viewMenu.addItem(
            item(
                "Enter Full Screen",
                action: #selector(NSWindow.toggleFullScreen(_:)),
                key: "f",
                modifiers: [.command, .control]
            )
        )
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            item("Minimize", action: #selector(NSWindow.performMiniaturize(_:)), key: "m")
        )
        windowMenu.addItem(item("Zoom", action: #selector(NSWindow.performZoom(_:))))
        windowMenu.addItem(.separator())
        windowMenu.addItem(
            item("Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)))
        )
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        application.windowsMenu = windowMenu

        return mainMenu
    }

    @objc private func showNewGame(_ sender: Any?) {
        NotificationCenter.default.post(name: .showNewGame, object: nil)
        workspaceWindow?.makeKeyAndOrderFront(sender)
    }

    @objc private func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let settingsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 920, height: 700),
                styleMask: [
                    .titled,
                    .closable,
                    .miniaturizable,
                    .resizable,
                    .fullSizeContentView,
                ],
                backing: .buffered,
                defer: false
            )
            settingsWindow.title = "LibChess Settings"
            settingsWindow.titleVisibility = .hidden
            settingsWindow.titlebarAppearsTransparent = true
            settingsWindow.titlebarSeparatorStyle = .none
            settingsWindow.toolbarStyle = .unified
            settingsWindow.isReleasedWhenClosed = false
            let coordinator = SettingsWindowCoordinator(store: store)
            settingsWindow.contentView = coordinator.contentView
            settingsWindow.setContentSize(NSSize(width: 920, height: 700))
            settingsWindow.minSize = NSSize(width: 720, height: 520)
            settingsWindow.center()
            settingsWindowCoordinator = coordinator
            self.settingsWindow = settingsWindow
        }
        settingsWindow?.makeKeyAndOrderFront(sender)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func showFloatingBoard(_ notification: Notification) {
        guard let gameID = notification.object as? String else {
            return
        }
        presentFloatingBoard(for: gameID)
    }

    @objc private func showFocusedGameInFloatingWindow(_ sender: Any?) {
        guard let gameID = store.focusedGameID else {
            return
        }
        presentFloatingBoard(for: gameID)
    }

    private func presentFloatingBoard(for gameID: String) {
        floatingBoardWindowCoordinator?.show(
            gameID: gameID,
            beside: workspaceWindow
        )
    }

    private func showGameInMainWindow(_ gameID: String) {
        NotificationCenter.default.post(name: .showGame, object: gameID)
        workspaceWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @objc private func increaseBoardSize(_ sender: Any?) {
        adjustBoardZoom(by: 1)
    }

    @objc private func decreaseBoardSize(_ sender: Any?) {
        adjustBoardZoom(by: -1)
    }

    @objc private func resetBoardSize(_ sender: Any?) {
        guard let presentation = store.boardPresentation,
              let defaultPreset = presentation.zoom.defaultValue
        else {
            return
        }
        setBoardZoom(defaultPreset)
    }

    private func adjustBoardZoom(by offset: Int) {
        guard let presentation = store.boardPresentation else {
            return
        }
        let savedID = UserDefaults.standard.string(forKey: BoardPreferenceKey.zoomPreset) ?? ""
        guard let current = presentation.zoom.preset(id: savedID)
            ?? presentation.zoom.defaultValue
            ?? presentation.zoom.presets.first
        else {
            return
        }
        setBoardZoom(presentation.zoom.adjacent(to: current, offset: offset))
    }

    private func setBoardZoom(_ preset: BoardZoomPreset) {
        UserDefaults.standard.set(preset.id, forKey: BoardPreferenceKey.zoomPreset)
    }

    private func item(
        _ title: String,
        action: Selector,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [.command],
        target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }
}
