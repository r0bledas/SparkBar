import AppKit
import SwiftUI

/// Borderless, non-activating floating panel that mimics macOS Spotlight & ChatGPT Option+Space bar.
public final class FloatingPanel: NSPanel {
    public var onEscapePressed: (() -> Void)?

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
        self.isMovableByWindowBackground = true
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
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            onEscapePressed?()
            return
        }
        super.keyDown(with: event)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            onEscapePressed?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
public final class PanelController: NSObject, NSWindowDelegate {
    public static let shared = PanelController()

    private var panel: FloatingPanel?
    public let focusTrigger = PassthroughSubject<Void, Never>()

    private override init() {
        super.init()
    }

    public func setupPanel<Content: View>(with rootView: Content) {
        let initialRect = NSRect(x: 0, y: 0, width: 680, height: 480)
        let panel = FloatingPanel(contentRect: initialRect)
        panel.delegate = self
        panel.onEscapePressed = { [weak self] in
            self?.hidePanel()
        }

        let hostingView = NSHostingView(rootView: rootView)
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

        positionPanelOnActiveScreen(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        focusTrigger.send()
    }

    public func hidePanel() {
        panel?.orderOut(nil)
    }

    private func positionPanelOnActiveScreen(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let activeScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let screen = activeScreen else { return }
        let visibleFrame = screen.visibleFrame
        let panelSize = panel.frame.size

        let x = visibleFrame.origin.x + (visibleFrame.width - panelSize.width) / 2.0
        // Position near the middle-bottom of the screen (not completely at the bottom)
        let y = visibleFrame.origin.y + visibleFrame.height * 0.25 - (panelSize.height / 2.0)

        let clampedY = max(visibleFrame.origin.y + 80, min(y, visibleFrame.maxY - panelSize.height - 40))
        panel.setFrameOrigin(NSPoint(x: x, y: clampedY))
    }

    public func windowDidResignKey(_ notification: Notification) {
        if !SettingsStore.shared.pinWindowOnBlur && !ChatViewModel.shared.showSettings {
            hidePanel()
        }
    }
}

import Combine
