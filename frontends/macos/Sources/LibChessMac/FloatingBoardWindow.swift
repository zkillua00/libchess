import AppKit
import LibChessKit
import SwiftUI

struct FloatingBoardResizeEdges: OptionSet {
    let rawValue: UInt8

    static let top = Self(rawValue: 1 << 0)
    static let left = Self(rawValue: 1 << 1)
    static let bottom = Self(rawValue: 1 << 2)
    static let right = Self(rawValue: 1 << 3)

    var hasHorizontalEdge: Bool {
        contains(.left) || contains(.right)
    }

    var hasVerticalEdge: Bool {
        contains(.top) || contains(.bottom)
    }
}

enum FloatingBoardWindowMetrics {
    static let defaultExtent: CGFloat = 460
    static let minimumExtent: CGFloat = 240
    static let maximumExtent: CGFloat = 960

    static func resizeHitInset(for extent: CGFloat) -> CGFloat {
        min(24, max(18, extent * 0.045))
    }
}

private enum FloatingBoardPanelInteractionTarget {
    case move
    case resize(FloatingBoardResizeEdges)
}

@MainActor
final class FloatingBoardWindowCoordinator {
    private static let frameAutosaveName = "org.libchess.macos.floating-board-frame"

    private let store: LibChessStore
    private let showMainGame: (String) -> Void
    private let panel: FloatingBoardPanel
    private var currentGameID: String?
    private var hasPositionedPanel: Bool

    init(
        store: LibChessStore,
        showMainGame: @escaping (String) -> Void
    ) {
        self.store = store
        self.showMainGame = showMainGame

        let panel = FloatingBoardPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: FloatingBoardWindowMetrics.defaultExtent,
                height: FloatingBoardWindowMetrics.defaultExtent
            ),
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Floating Chessboard"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.canHide = false
        panel.isExcludedFromWindowsMenu = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentAspectRatio = NSSize(width: 1, height: 1)
        panel.minSize = NSSize(
            width: FloatingBoardWindowMetrics.minimumExtent,
            height: FloatingBoardWindowMetrics.minimumExtent
        )
        panel.maxSize = NSSize(
            width: FloatingBoardWindowMetrics.maximumExtent,
            height: FloatingBoardWindowMetrics.maximumExtent
        )
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .ignoresCycle,
        ]
        panel.animationBehavior = .utilityWindow
        panel.setAccessibilityTitle("Floating Chessboard")

        let restoredFrame = panel.setFrameUsingName(Self.frameAutosaveName)
        if restoredFrame {
            Self.squareRestoredFrame(of: panel)
        }
        panel.setFrameAutosaveName(Self.frameAutosaveName)

        self.panel = panel
        hasPositionedPanel = restoredFrame
        panel.interactionTargetProvider = { [weak self] location in
            self?.interactionTarget(at: location)
        }
    }

    func show(gameID: String, beside anchorWindow: NSWindow?) {
        guard let game = store.liveGame(gameID),
              game.state.isPlayable,
              store.boardPresentation != nil
        else {
            return
        }

        if currentGameID != gameID || panel.contentView == nil {
            let rootView = FloatingBoardView(
                gameID: gameID,
                closeWindow: { [weak self] in
                    self?.close()
                },
                showMainGame: { [weak self] gameID in
                    self?.showMainGame(gameID)
                }
            )
            .environmentObject(store)

            let hostingView = NSHostingView(rootView: rootView)
            hostingView.wantsLayer = true
            hostingView.layer?.backgroundColor = NSColor.clear.cgColor
            panel.contentView = hostingView
            currentGameID = gameID
        }

        if !hasPositionedPanel {
            positionPanel(beside: anchorWindow)
            hasPositionedPanel = true
        }

        panel.orderFrontRegardless()
        panel.invalidateShadow()
    }

    func close() {
        panel.cancelInteraction()
        panel.orderOut(nil)
        panel.contentView = nil
        currentGameID = nil
    }

    private func interactionTarget(
        at location: NSPoint
    ) -> FloatingBoardPanelInteractionTarget? {
        let resizeEdges = panel.resizeEdges(at: location)
        if !resizeEdges.isEmpty {
            return .resize(resizeEdges)
        }

        guard let gameID = currentGameID,
              let game = store.liveGame(gameID),
              let contentView = panel.contentView
        else {
            return nil
        }

        let bounds = contentView.bounds
        guard bounds.width > 0,
              bounds.height > 0,
              bounds.contains(location)
        else {
            return nil
        }

        let boardExtent = min(bounds.width, bounds.height)
        let squareExtent = boardExtent / 8
        let column = min(7, max(0, Int(location.x / squareExtent)))
        let rowFromTop = min(
            7,
            max(0, Int((boardExtent - location.y) / squareExtent))
        )
        let square = BoardPerspective.squares(for: game.playerColor)[rowFromTop * 8 + column]
        let squareIsEmpty = !store.displayedBoard(for: game).pieces.contains {
            $0.square == square
        }
        return squareIsEmpty ? .move : nil
    }

    private func positionPanel(beside anchorWindow: NSWindow?) {
        let screen = anchorWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else {
            panel.center()
            return
        }

        let extent = min(
            FloatingBoardWindowMetrics.defaultExtent,
            visibleFrame.width - 48,
            visibleFrame.height - 48
        )
        let margin: CGFloat = 24
        var origin = NSPoint(
            x: visibleFrame.maxX - extent - margin,
            y: visibleFrame.maxY - extent - margin
        )

        if let anchorWindow {
            let rightOrigin = anchorWindow.frame.maxX + margin
            let leftOrigin = anchorWindow.frame.minX - extent - margin
            if rightOrigin + extent <= visibleFrame.maxX - margin {
                origin.x = rightOrigin
            } else if leftOrigin >= visibleFrame.minX + margin {
                origin.x = leftOrigin
            }
            origin.y = min(
                max(anchorWindow.frame.maxY - extent, visibleFrame.minY + margin),
                visibleFrame.maxY - extent - margin
            )
        }

        panel.setFrame(
            NSRect(x: origin.x, y: origin.y, width: extent, height: extent),
            display: false
        )
    }

    private static func squareRestoredFrame(of panel: NSPanel) {
        let extent = min(
            FloatingBoardWindowMetrics.maximumExtent,
            max(
                FloatingBoardWindowMetrics.minimumExtent,
                min(panel.frame.width, panel.frame.height)
            )
        )
        panel.setFrame(
            NSRect(
                x: panel.frame.minX,
                y: panel.frame.minY,
                width: extent,
                height: extent
            ),
            display: false
        )
    }
}

@MainActor
private final class FloatingBoardPanel: NSPanel {
    private struct PendingInteraction {
        let target: FloatingBoardPanelInteractionTarget
        let initialMouseLocation: NSPoint
        let initialFrame: NSRect
        var hasStarted: Bool
    }

    var interactionTargetProvider: ((NSPoint) -> FloatingBoardPanelInteractionTarget?)?
    private var pendingInteraction: PendingInteraction?

    private static let dragThreshold: CGFloat = 3

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if let target = interactionTargetProvider?(event.locationInWindow) {
                pendingInteraction = PendingInteraction(
                    target: target,
                    initialMouseLocation: NSEvent.mouseLocation,
                    initialFrame: frame,
                    hasStarted: false
                )
            } else {
                pendingInteraction = nil
            }
            super.sendEvent(event)
        case .leftMouseDragged:
            guard var interaction = pendingInteraction else {
                super.sendEvent(event)
                return
            }

            let mouseLocation = NSEvent.mouseLocation
            let translation = CGSize(
                width: mouseLocation.x - interaction.initialMouseLocation.x,
                height: mouseLocation.y - interaction.initialMouseLocation.y
            )

            if !interaction.hasStarted {
                let distance = hypot(translation.width, translation.height)
                guard distance >= Self.dragThreshold else {
                    super.sendEvent(event)
                    return
                }
                interaction.hasStarted = true
                pendingInteraction = interaction
                if case .move = interaction.target {
                    NSCursor.closedHand.set()
                }
            }

            apply(interaction, translation: translation)
        case .leftMouseUp:
            let consumedWindowInteraction = pendingInteraction?.hasStarted == true
            pendingInteraction = nil
            if !consumedWindowInteraction {
                super.sendEvent(event)
            }
            updateCursor(at: event.locationInWindow)
        case .mouseMoved:
            super.sendEvent(event)
            updateCursor(at: event.locationInWindow)
        case .mouseExited:
            super.sendEvent(event)
            NSCursor.arrow.set()
        default:
            super.sendEvent(event)
        }
    }

    func cancelInteraction() {
        pendingInteraction = nil
    }

    private func apply(
        _ interaction: PendingInteraction,
        translation: CGSize
    ) {
        switch interaction.target {
        case .move:
            setFrameOrigin(
                NSPoint(
                    x: interaction.initialFrame.minX + translation.width,
                    y: interaction.initialFrame.minY + translation.height
                )
            )
        case let .resize(edges):
            resize(
                from: interaction.initialFrame,
                edges: edges,
                translation: translation
            )
        }
    }

    private func resize(
        from initialFrame: NSRect,
        edges: FloatingBoardResizeEdges,
        translation: CGSize
    ) {
        var proposedExtents: [CGFloat] = []

        if edges.contains(.left) {
            proposedExtents.append(initialFrame.width - translation.width)
        } else if edges.contains(.right) {
            proposedExtents.append(initialFrame.width + translation.width)
        }

        if edges.contains(.bottom) {
            proposedExtents.append(initialFrame.height - translation.height)
        } else if edges.contains(.top) {
            proposedExtents.append(initialFrame.height + translation.height)
        }

        guard let proposedExtent = proposedExtents.max(by: {
            abs($0 - initialFrame.width) < abs($1 - initialFrame.width)
        }) else {
            return
        }

        let extent = min(
            FloatingBoardWindowMetrics.maximumExtent,
            max(FloatingBoardWindowMetrics.minimumExtent, proposedExtent)
        )

        let originX: CGFloat
        if edges.contains(.left) {
            originX = initialFrame.maxX - extent
        } else if edges.contains(.right) {
            originX = initialFrame.minX
        } else {
            originX = initialFrame.midX - extent / 2
        }

        let originY: CGFloat
        if edges.contains(.bottom) {
            originY = initialFrame.maxY - extent
        } else if edges.contains(.top) {
            originY = initialFrame.minY
        } else {
            originY = initialFrame.midY - extent / 2
        }

        setFrame(
            NSRect(x: originX, y: originY, width: extent, height: extent),
            display: true
        )
    }

    private func updateCursor(at location: NSPoint) {
        let edges = resizeEdges(at: location)
        guard !edges.isEmpty else {
            if case .move = interactionTargetProvider?(location) {
                NSCursor.openHand.set()
            } else {
                NSCursor.arrow.set()
            }
            return
        }

        if #available(macOS 15, *), let position = frameResizePosition(for: edges) {
            NSCursor.frameResize(position: position, directions: .all).set()
        } else if edges.hasHorizontalEdge && !edges.hasVerticalEdge {
            NSCursor.resizeLeftRight.set()
        } else if edges.hasVerticalEdge && !edges.hasHorizontalEdge {
            NSCursor.resizeUpDown.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    func resizeEdges(at location: NSPoint) -> FloatingBoardResizeEdges {
        let inset = FloatingBoardWindowMetrics.resizeHitInset(for: min(frame.width, frame.height))
        var edges: FloatingBoardResizeEdges = []

        if location.x <= inset {
            edges.insert(.left)
        } else if location.x >= frame.width - inset {
            edges.insert(.right)
        }

        if location.y <= inset {
            edges.insert(.bottom)
        } else if location.y >= frame.height - inset {
            edges.insert(.top)
        }

        return edges
    }

    @available(macOS 15, *)
    private func frameResizePosition(
        for edges: FloatingBoardResizeEdges
    ) -> NSCursor.FrameResizePosition? {
        switch edges {
        case [.top, .left]: .topLeft
        case [.top, .right]: .topRight
        case [.bottom, .left]: .bottomLeft
        case [.bottom, .right]: .bottomRight
        case [.top]: .top
        case [.left]: .left
        case [.bottom]: .bottom
        case [.right]: .right
        default: nil
        }
    }
}
