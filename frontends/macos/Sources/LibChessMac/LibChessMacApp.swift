import AppKit
import LibChessKit
import SwiftUI

extension Notification.Name {
    static let showNewGame = Notification.Name("org.libchess.macos.show-new-game")
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
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = LibChessStore()
    private var window: NSWindow?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let application = notification.object as? NSApplication ?? NSApplication.shared
        application.mainMenu = makeMainMenu(for: application)

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
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        self.window = window
        store.refreshSavedCredentialAvailability()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if store.handleOpenURL(url) {
                window?.makeKeyAndOrderFront(nil)
                return
            }
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        if !flag {
            window?.makeKeyAndOrderFront(nil)
        }
        return true
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
        window?.makeKeyAndOrderFront(sender)
    }

    @objc private func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let settingsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            settingsWindow.title = "LibChess Settings"
            settingsWindow.toolbarStyle = .preference
            settingsWindow.contentMinSize = NSSize(width: 640, height: 500)
            settingsWindow.isReleasedWhenClosed = false
            settingsWindow.contentView = NSHostingView(
                rootView: SettingsView()
                    .environmentObject(store)
                    .frame(minWidth: 640, minHeight: 500)
            )
            settingsWindow.center()
            self.settingsWindow = settingsWindow
        }
        settingsWindow?.makeKeyAndOrderFront(sender)
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
