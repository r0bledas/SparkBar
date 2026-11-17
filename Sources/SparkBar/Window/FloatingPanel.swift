import AppKit
import SwiftUI
import Combine

/// Borderless, resizable, non-activating floating panel that mimics macOS Spotlight & ChatGPT Option+Space bar.
public final class FloatingPanel: NSPanel {
    public var onEscapePressed: (() -> Void)?
    public var onCommandWPressed: (() -> Void)?

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .titled, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        // Disable full-window background dragging so text selection in chat works without dragging the window;
        // dragging is handled explicitly by the empty space in the bottom control bar.
        self.isMovableByWindowBackground = false
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.minSize = NSSize(width: 380, height: 110)
        self.maxSize = NSSize(width: 1200, height: 900)

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
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            onCommandWPressed?()
            return
        }
        super.keyDown(with: event)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            let char = event.charactersIgnoringModifiers?.lowercased()
            if char == "w" {
                onCommandWPressed?()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Transparent AppKit view placed in the empty space of the bottom bar that initiates native window dragging on click-and-hold.
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

    /// 30% narrower than the original 680pt width -> 476pt
    public static let defaultWidth: CGFloat = 476
    public static let defaultCollapsedHeight: CGFloat = 114
    public static let defaultExpandedHeight: CGFloat = 420

    private var panel: FloatingPanel?
    public let focusTrigger = PassthroughSubject<Void, Never>()

    /// Tracks whether the user has manually moved or resized the panel in the current session.
    /// Preserved across click-away hides (`⌥ + Space` restores it), and reset when closed with `⌘ + W`.
    private var hasCustomFrame: Bool = false
    private var savedCustomFrame: NSRect?
    private var isProgrammaticFrameChange: Bool = false

    private override init() {
        super.init()
    }

    public func setupPanel<Content: View>(with rootView: Content) {
        let initialRect = NSRect(x: 0, y: 0, width: Self.defaultWidth, height: Self.defaultCollapsedHeight)
        let panel = FloatingPanel(contentRect: initialRect)
        panel.delegate = self

        // Escape hides the panel while preserving custom size/position
        panel.onEscapePressed = { [weak self] in
            self?.hidePanel()
        }

        // Command-W closes the panel AND resets size/position back to default
        panel.onCommandWPressed = { [weak self] in
            self?.closeAndResetPanel()
        }

        let hostingView = NSHostingView(rootView: rootView)
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

        isProgrammaticFrameChange = true
        if hasCustomFrame, let customRect = savedCustomFrame {
            panel.setFrame(customRect, display: true)
        } else {
            let defaultRect = computeDefaultFrame(for: panel)
            panel.setFrame(defaultRect, display: true)
        }
        isProgrammaticFrameChange = false

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        focusTrigger.send()
    }

    /// Hides the panel (e.g. when clicking away or pressing Option+Space). Preserves any user-resized or moved frame.
    public func hidePanel() {
        if let panel = panel, hasCustomFrame {
            savedCustomFrame = panel.frame
        }
        panel?.orderOut(nil)
    }

    /// Triggered by `⌘ + W`: hides the panel and resets its size & position back to default for the next launch.
    public func closeAndResetPanel() {
        hasCustomFrame = false
        savedCustomFrame = nil
        panel?.orderOut(nil)
        if let panel = panel {
            isProgrammaticFrameChange = true
            let defaultRect = computeDefaultFrame(for: panel)
            panel.setFrame(defaultRect, display: false)
            isProgrammaticFrameChange = false
        }
    }

    /// Expands or collapses the default panel height when messages appear/clear, unless the user manually resized it.
    public func updateHeightForConversationIfNeeded(hasMessages: Bool) {
        guard let panel = panel, !hasCustomFrame else { return }
        let targetHeight = hasMessages ? Self.defaultExpandedHeight : Self.defaultCollapsedHeight
        if abs(panel.frame.height - targetHeight) > 2 {
            isProgrammaticFrameChange = true
            var frame = panel.frame
            frame.size.height = targetHeight
            panel.setFrame(frame, display: true, animate: true)
            isProgrammaticFrameChange = false
        }
    }

    private func computeDefaultFrame(for panel: NSPanel) -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        let activeScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        let hasMessages = !ChatViewModel.shared.messages.isEmpty || ChatViewModel.shared.errorMessage != nil
        let targetWidth = Self.defaultWidth
        let targetHeight = hasMessages ? Self.defaultExpandedHeight : Self.defaultCollapsedHeight

        guard let screen = activeScreen else {
            return NSRect(x: 200, y: 200, width: targetWidth, height: targetHeight)
        }

        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.origin.x + (visibleFrame.width - targetWidth) / 2.0
        // Position near the middle-bottom of the screen (not completely at the bottom)
        let y = visibleFrame.origin.y + visibleFrame.height * 0.25 - (targetHeight / 2.0)
        let clampedY = max(visibleFrame.origin.y + 80, min(y, visibleFrame.maxY - targetHeight - 40))

        return NSRect(x: x, y: clampedY, width: targetWidth, height: targetHeight)
    }

    public func windowDidResize(_ notification: Notification) {
        guard !isProgrammaticFrameChange, let panel = panel, panel.isVisible else { return }
        hasCustomFrame = true
        savedCustomFrame = panel.frame
    }

    public func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticFrameChange, let panel = panel, panel.isVisible else { return }
        hasCustomFrame = true
        savedCustomFrame = panel.frame
    }

    public func windowDidResignKey(_ notification: Notification) {
        if !SettingsStore.shared.pinWindowOnBlur && !ChatViewModel.shared.showSettings {
            hidePanel()
        }
    }
}
