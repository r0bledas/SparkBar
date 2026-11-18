import AppKit
import SwiftUI
import Combine

/// Borderless, static-size, non-activating floating panel that mimics macOS Spotlight & ChatGPT Option+Space bar.
public final class FloatingPanel: NSPanel {
    public var onEscapePressed: (() -> Void)?
    public var onNewChatPressed: (() -> Void)?
    public var onToggleHistoryPressed: (() -> Void)?

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.animationBehavior = .none
        self.isMovableByWindowBackground = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
    }

    public override var canBecomeKey: Bool {
        true
    }

    public override var canBecomeMain: Bool {
        true
    }

    public override func cancelOperation(_ sender: Any?) {
        onEscapePressed?()
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape key
            onEscapePressed?()
            return
        }
        if event.modifierFlags.contains(.command) {
            let char = event.charactersIgnoringModifiers?.lowercased()
            if char == "w" {
                onEscapePressed?()
                return
            }
            if char == "n" {
                onNewChatPressed?()
                return
            }
            if char == "y" {
                onToggleHistoryPressed?()
                return
            }
        }
        super.keyDown(with: event)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            let char = event.charactersIgnoringModifiers?.lowercased()
            if char == "w" {
                onEscapePressed?()
                return true
            }
            if char == "n" {
                onNewChatPressed?()
                return true
            }
            if char == "y" {
                onToggleHistoryPressed?()
                return true
            }
            if char == "v" {
                if ChatViewModel.shared.checkAndAttachPasteboardImage() {
                    return true
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Custom drag handle placed in the empty space of the bottom bar.
/// Supports:
/// - Smooth window dragging
/// - Holding `⌘ Command` while dragging to lock/align movement to the X or Y axis (or snap directly to the default X/Y axes)
/// - Automatic magnetic snapping toward the default position (`defaultOrigin.x`, `defaultOrigin.y`, or both)
public struct WindowDragHandle: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> DraggableNSView {
        DraggableNSView()
    }

    public func updateNSView(_ nsView: DraggableNSView, context: Context) {}

    public final class DraggableNSView: NSView {
        private var initialMouseLocation: NSPoint = .zero
        private var initialWindowOrigin: NSPoint = .zero
        private var lockedAxis: AxisLock? = nil

        private enum AxisLock {
            case horizontal // Y is locked, moves along X
            case vertical   // X is locked, moves along Y
        }

        public override func mouseDown(with event: NSEvent) {
            guard let window = self.window else { return }
            initialMouseLocation = NSEvent.mouseLocation
            initialWindowOrigin = window.frame.origin
            lockedAxis = nil

            let defaultOrigin = PanelController.shared.computeDefaultBottomAnchor()
            let magnetThreshold: CGFloat = 24.0
            let commandSnapThreshold: CGFloat = 64.0
            var wasSnappedX = false
            var wasSnappedY = false
            var wasAtExactDefault = false

            // Track mouse dragging & modifier flags in real time
            while let nextEvent = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .flagsChanged]) {
                if nextEvent.type == .leftMouseUp {
                    break
                }

                let currentMouse = NSEvent.mouseLocation
                let dx = currentMouse.x - initialMouseLocation.x
                let dy = currentMouse.y - initialMouseLocation.y

                var proposedX = initialWindowOrigin.x + dx
                var proposedY = initialWindowOrigin.y + dy

                let isCommandDown = nextEvent.modifierFlags.contains(.command)

                if isCommandDown {
                    // Determine dominant drag axis if not already locked
                    if lockedAxis == nil && (abs(dx) > 4 || abs(dy) > 4) {
                        lockedAxis = abs(dx) >= abs(dy) ? .horizontal : .vertical
                    }

                    // If near the default X or Y axis while holding Command, snap directly onto the default axis line
                    if abs(proposedX - defaultOrigin.x) < commandSnapThreshold {
                        proposedX = defaultOrigin.x
                    } else if lockedAxis == .vertical {
                        proposedX = initialWindowOrigin.x
                    }

                    if abs(proposedY - defaultOrigin.y) < commandSnapThreshold {
                        proposedY = defaultOrigin.y
                    } else if lockedAxis == .horizontal {
                        proposedY = initialWindowOrigin.y
                    }
                } else {
                    lockedAxis = nil
                }

                // Magnetic attraction toward the default position (X axis, Y axis, or exact default origin)
                let nearDefaultX = abs(proposedX - defaultOrigin.x) < magnetThreshold
                let nearDefaultY = abs(proposedY - defaultOrigin.y) < magnetThreshold

                if nearDefaultX {
                    proposedX = defaultOrigin.x
                }
                if nearDefaultY {
                    proposedY = defaultOrigin.y
                }

                let isSnappedX = (proposedX == defaultOrigin.x)
                let isSnappedY = (proposedY == defaultOrigin.y)
                let isAtExactDefault = isSnappedX && isSnappedY

                if isAtExactDefault && !wasAtExactDefault {
                    // Strong tactile bump when magneting onto the exact default origin
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                } else if (isSnappedX && !wasSnappedX) || (isSnappedY && !wasSnappedY) {
                    // Crisp alignment tick when crossing onto either the X or Y axis
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }

                wasSnappedX = isSnappedX
                wasSnappedY = isSnappedY
                wasAtExactDefault = isAtExactDefault

                let newOrigin = NSPoint(x: round(proposedX), y: round(proposedY))
                window.setFrameOrigin(newOrigin)
                PanelController.shared.updateAnchoredBottomOrigin(newOrigin)
            }
        }
    }
}

@MainActor
public final class PanelController: NSObject, NSWindowDelegate {
    public static let shared = PanelController()

    public static let panelWidth: CGFloat = 520
    public static let collapsedHeight: CGFloat = 110
    /// Once active with messages, the window is a 1:1 square (520 x 520)
    public static let maxExpandedHeight: CGFloat = 520

    private var panel: FloatingPanel?
    public let focusTrigger = PassthroughSubject<Void, Never>()

    /// Fixed bottom-left anchor point on the screen so the panel ALWAYS grows strictly from bottom-to-top
    /// without ever jumping up or down when sending a message or starting a new chat.
    private var anchoredBottomOrigin: NSPoint?
    private var isUpdatingFrame: Bool = false

    private override init() {
        super.init()
    }

    public func setupPanel<Content: View>(with rootView: Content) {
        let initialRect = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.collapsedHeight)
        let panel = FloatingPanel(contentRect: initialRect)
        panel.delegate = self
        panel.onEscapePressed = { [weak self] in
            if ChatViewModel.shared.showHistory {
                ChatViewModel.shared.toggleHistory()
            } else {
                self?.hidePanel()
            }
        }
        panel.onNewChatPressed = { [weak self] in
            ChatViewModel.shared.startNewConversation()
            self?.focusTrigger.send()
        }
        panel.onToggleHistoryPressed = {
            ChatViewModel.shared.toggleHistory()
        }

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.collapsedHeight)
        hostingView.autoresizingMask = [.width, .height]
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 16
        hostingView.layer?.masksToBounds = false
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        self.panel = panel
        panel.contentView = hostingView
    }

    public var isVisible: Bool {
        panel?.isVisible ?? false
    }

    public func togglePanel() {
        if isVisible && (panel?.isKeyWindow ?? false) {
            hidePanel()
        } else {
            showPanel()
        }
    }

    public func showPanel() {
        guard let panel = panel else { return }

        if anchoredBottomOrigin == nil {
            anchoredBottomOrigin = computeDefaultBottomAnchor()
        }

        let targetHeight = currentTargetHeight()
        applyAnchoredFrame(height: targetHeight, animate: false)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        focusTrigger.send()
    }

    public func hidePanel() {
        panel?.orderOut(nil)
    }

    public func updateAnchoredBottomOrigin(_ origin: NSPoint) {
        anchoredBottomOrigin = origin
    }

    /// Strictly resizes the panel from bottom-to-top by keeping `frame.origin.y` locked at `anchoredBottomOrigin.y`.
    public func syncPanelHeight(hasMessages: Bool) {
        let targetHeight = currentTargetHeight()
        applyAnchoredFrame(height: targetHeight, animate: false)
    }

    private func currentTargetHeight() -> CGFloat {
        let vm = ChatViewModel.shared
        let hasMessages = !vm.messages.isEmpty || vm.errorMessage != nil || vm.activeToolStatus != nil || vm.showHistory
        if hasMessages {
            return Self.maxExpandedHeight
        }
        if !vm.attachedImages.isEmpty {
            return Self.collapsedHeight + 39
        }
        return Self.collapsedHeight
    }

    private func applyAnchoredFrame(height: CGFloat, animate: Bool) {
        guard let panel = panel else { return }
        let anchor: NSPoint
        if panel.isVisible, anchoredBottomOrigin != nil {
            // Keep the bottom-left origin 100% stiff at the window's live bottom edge so it ONLY resizes upward
            anchor = panel.frame.origin
            anchoredBottomOrigin = anchor
        } else {
            anchor = anchoredBottomOrigin ?? computeDefaultBottomAnchor()
            anchoredBottomOrigin = anchor
        }

        let newFrame = NSRect(
            x: anchor.x,
            y: anchor.y,
            width: Self.panelWidth,
            height: height
        )

        isUpdatingFrame = true
        panel.contentView?.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: height)
        panel.setFrame(newFrame, display: true, animate: animate)
        panel.contentView?.needsLayout = true
        panel.contentView?.layoutSubtreeIfNeeded()
        isUpdatingFrame = false
    }

    public func computeDefaultBottomAnchor() -> NSPoint {
        let mouseLocation = NSEvent.mouseLocation
        let activeScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let screen = activeScreen else {
            return NSPoint(x: 300, y: 180)
        }

        let visibleFrame = screen.visibleFrame
        let x = round(visibleFrame.origin.x + (visibleFrame.width - Self.panelWidth) / 2.0)
        // Lock the bottom edge at 75% of the previous 0.22 height (0.22 * 0.75 = 0.165 above bottom of visible screen)
        let y = round(visibleFrame.origin.y + visibleFrame.height * 0.165)
        return NSPoint(x: x, y: y)
    }

    public func windowDidMove(_ notification: Notification) {
        guard !isUpdatingFrame, let panel = panel, panel.isVisible else { return }
        anchoredBottomOrigin = panel.frame.origin
    }

    public func windowDidResignKey(_ notification: Notification) {
        if !SettingsStore.shared.pinWindowOnBlur && !ChatViewModel.shared.showSettings {
            hidePanel()
        }
    }
}
