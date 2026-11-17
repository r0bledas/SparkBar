import AppKit
import SwiftUI
import Combine

/// Borderless, static-size, non-activating floating panel that mimics macOS Spotlight & ChatGPT Option+Space bar.
public final class FloatingPanel: NSPanel {
    public var onEscapePressed: (() -> Void)?
    public var onNewChatPressed: (() -> Void)?

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.isMovableByWindowBackground = false
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true

        // Hide traffic light window buttons
        self.standardWindowButton(.closeButton)?.isHidden = true
        self.standardWindowButton(.miniaturizeButton)?.isHidden = true
        self.standardWindowButton(.zoomButton)?.isHidden = true
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
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Transparent AppKit view placed in the empty space of the bottom bar that allows moving the window by dragging.
public struct WindowDragHandle: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> DraggableNSView {
        DraggableNSView()
    }

    public func updateNSView(_ nsView: DraggableNSView, context: Context) {}

    public final class DraggableNSView: NSView {
        public override var mouseDownCanMoveWindow: Bool { true }

        public override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }
}

@MainActor
public final class PanelController: NSObject, NSWindowDelegate {
    public static let shared = PanelController()

    public static let panelWidth: CGFloat = 540
    public static let collapsedHeight: CGFloat = 110
    /// Maximum height follows a 1.2:1 aspect ratio relative to width (540 / 1.2 = 450pt)
    public static let maxExpandedHeight: CGFloat = 450

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
            self?.hidePanel()
        }
        panel.onNewChatPressed = { [weak self] in
            ChatViewModel.shared.clearConversation()
            self?.focusTrigger.send()
        }

        let hostingView = NSHostingView(rootView: rootView)
        // Prevent NSHostingView from expanding the window downward on its own!
        // PanelController exclusively controls window frame so `origin.y` (the bottom edge) is 100% locked.
        hostingView.sizingOptions = []
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        self.panel = panel
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

    /// Strictly resizes the panel from bottom-to-top by keeping `frame.origin.y` locked at `anchoredBottomOrigin.y`.
    public func syncPanelHeight(hasMessages: Bool) {
        let targetHeight = hasMessages ? Self.maxExpandedHeight : Self.collapsedHeight
        applyAnchoredFrame(height: targetHeight, animate: false)
    }

    private func currentTargetHeight() -> CGFloat {
        let vm = ChatViewModel.shared
        let hasMessages = !vm.messages.isEmpty || vm.errorMessage != nil || vm.activeToolStatus != nil
        return hasMessages ? Self.maxExpandedHeight : Self.collapsedHeight
    }

    private func applyAnchoredFrame(height: CGFloat, animate: Bool) {
        guard let panel = panel else { return }
        let anchor = anchoredBottomOrigin ?? computeDefaultBottomAnchor()
        anchoredBottomOrigin = anchor

        let newFrame = NSRect(
            x: anchor.x,
            y: anchor.y,
            width: Self.panelWidth,
            height: height
        )

        if panel.frame != newFrame {
            isUpdatingFrame = true
            panel.setFrame(newFrame, display: true, animate: animate)
            isUpdatingFrame = false
        }
    }

    private func computeDefaultBottomAnchor() -> NSPoint {
        let mouseLocation = NSEvent.mouseLocation
        let activeScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let screen = activeScreen else {
            return NSPoint(x: 300, y: 180)
        }

        let visibleFrame = screen.visibleFrame
        let x = round(visibleFrame.origin.x + (visibleFrame.width - Self.panelWidth) / 2.0)
        // Lock the bottom edge near the middle-bottom of the screen (22% above bottom of visible screen)
        let y = round(visibleFrame.origin.y + visibleFrame.height * 0.22)
        return NSPoint(x: x, y: y)
    }

    public func windowDidMove(_ notification: Notification) {
        guard !isUpdatingFrame, let panel = panel, panel.isVisible else { return }
        // If the user drags the window via the bottom bar, update the locked bottom-left anchor to the new spot
        anchoredBottomOrigin = panel.frame.origin
    }

    public func windowDidResignKey(_ notification: Notification) {
        if !SettingsStore.shared.pinWindowOnBlur && !ChatViewModel.shared.showSettings {
            hidePanel()
        }
    }
}
