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
        self.hidesOnDeactivate = false
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.animationBehavior = .none
        self.isMovableByWindowBackground = false
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
            if char == "," {
                SettingsWindowController.shared.showWindow()
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
            if char == "," {
                SettingsWindowController.shared.showWindow()
                return true
            }
            if char == "f" && event.modifierFlags.contains(.shift) {
                FullScreenChatWindowController.shared.showWindow()
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

/// Custom drag handle that also supports dragging the window from any empty/non-interactive area
/// inside the chat scroll view or bottom bar.
/// Supports:
/// - Smooth window dragging (with axis locking on `⌘ Command` and magnetic snapping to default origin)
/// - Automatic window dragging when clicking & dragging on empty background areas of the panel
public struct WindowDragHandle: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> DraggableNSView {
        DraggableNSView()
    }

    public func updateNSView(_ nsView: DraggableNSView, context: Context) {}

    public final class DraggableNSView: NSView {
        public override var mouseDownCanMoveWindow: Bool {
            false
        }

        public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        public override func mouseDown(with event: NSEvent) {
            guard let window = self.window else { return }
            Self.runWindowDragLoop(for: window)
        }

        @MainActor
        public static func runWindowDragLoop(for window: NSWindow) {
            let initialMouseLocation = NSEvent.mouseLocation
            let initialWindowOrigin = window.frame.origin
            var lockedAxis: AxisLock? = nil

            let defaultOrigin = PanelController.shared.computeDefaultBottomAnchor()
            let magnetThreshold: CGFloat = 24.0
            let commandSnapThreshold: CGFloat = 64.0
            var wasSnappedX = (abs(initialWindowOrigin.x - defaultOrigin.x) < 1.0)
            var wasSnappedY = (abs(initialWindowOrigin.y - defaultOrigin.y) < 1.0)
            var wasAtExactDefault = wasSnappedX && wasSnappedY

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
                if window.frame.origin != newOrigin {
                    window.setFrameOrigin(newOrigin)
                    PanelController.shared.updateAnchoredBottomOrigin(newOrigin)
                }
            }
        }

        private enum AxisLock {
            case horizontal // Y is locked, moves along X
            case vertical   // X is locked, moves along Y
        }
    }
}

@MainActor
public final class PanelController: NSObject, NSWindowDelegate {
    public static let shared = PanelController()

    public static let panelWidth: CGFloat = 520
    public static let collapsedHeight: CGFloat = 128
    /// Once active with messages, the window is a 1:1 square (520 x 520)
    public static let maxExpandedHeight: CGFloat = 520

    private var panel: FloatingPanel?
    public let focusTrigger = PassthroughSubject<Void, Never>()

    /// Fixed bottom-left anchor point on the screen so the panel ALWAYS grows strictly from bottom-to-top
    /// without ever jumping up or down when sending a message or starting a new chat.
    private var anchoredBottomOrigin: NSPoint?
    private var isUpdatingFrame: Bool = false
    private var globalMouseMonitor: Any?
    private var outsideMouseDownPoint: NSPoint?
    private var didDragOutside: Bool = false
    private let fieldEditor = SparkBarFieldEditor()

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
        setupOutsideClickMonitor()
    }

    private func setupOutsideClickMonitor() {
        guard globalMouseMonitor == nil else { return }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        ) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self = self, let panel = self.panel, panel.isVisible else { return }
                let mouseLoc = NSEvent.mouseLocation
                switch event.type {
                case .leftMouseDown, .rightMouseDown:
                    self.outsideMouseDownPoint = mouseLoc
                    self.didDragOutside = false
                case .leftMouseDragged:
                    if let start = self.outsideMouseDownPoint {
                        let dist = hypot(mouseLoc.x - start.x, mouseLoc.y - start.y)
                        if dist > 4 {
                            self.didDragOutside = true
                        }
                    } else {
                        self.didDragOutside = true
                    }
                case .leftMouseUp, .rightMouseUp:
                    defer {
                        self.outsideMouseDownPoint = nil
                        self.didDragOutside = false
                    }
                    // Never hide if the user was dragging (e.g. dragging an image into SparkBar)
                    if self.didDragOutside { return }
                    let vm = ChatViewModel.shared
                    // Never hide while streaming/running tools (e.g. when macOS pops up a folder permission dialog),
                    // or when file picker is open, or when pinned
                    if SettingsStore.shared.pinWindowOnBlur || vm.isPickingFile || vm.isStreaming || vm.activeToolStatus != nil {
                        return
                    }
                    if !NSMouseInRect(mouseLoc, panel.frame, false) {
                        self.hidePanel()
                    }
                default:
                    break
                }
            }
        }
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
            return Self.collapsedHeight + 98
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
        // Dismissal on outside click is handled on mouse-up in `setupOutsideClickMonitor()`
        // so that dragging files from Finder/Safari or clicking macOS TCC permission dialogs never hides the window.
    }

    public func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        fieldEditor.isFieldEditor = true
        return fieldEditor
    }
}

/// Custom field editor for the prompt `TextField` that intercepts dragged screenshots and image files
/// (such as macOS bottom-right screenshot previews from `/var/folders/.../NSIRD_screencaptureui_...`)
/// and attaches them as images instead of pasting their file path into the text box.
public class SparkBarFieldEditor: NSTextView {
    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if Self.canHandleImageDrag(sender.draggingPasteboard) {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if Self.canHandleImageDrag(sender.draggingPasteboard) {
            return .copy
        }
        return super.draggingUpdated(sender)
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if Self.extractAndAttachImages(from: sender.draggingPasteboard) {
            return true
        }
        return super.performDragOperation(sender)
    }

    public override func paste(_ sender: Any?) {
        if ChatViewModel.shared.checkAndAttachPasteboardImage() {
            return
        }
        super.paste(sender)
    }

    public static func canHandleImageDrag(_ pb: NSPasteboard) -> Bool {
        if pb.data(forType: .png) != nil || pb.data(forType: .tiff) != nil {
            return true
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            for url in urls {
                let ext = url.pathExtension.lowercased()
                if ["png", "jpg", "jpeg", "webp", "gif", "heic", "tiff", "bmp"].contains(ext) || url.path.contains("screencaptureui") {
                    return true
                }
            }
        }
        return false
    }

    @MainActor
    public static func extractAndAttachImages(from pb: NSPasteboard) -> Bool {
        var attached = false

        // 1. Check file URLs first (including macOS screencaptureui temp files in /var/folders/...)
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            for url in urls {
                let ext = url.pathExtension.lowercased()
                if ["png", "jpg", "jpeg", "webp", "gif", "heic", "tiff", "bmp"].contains(ext),
                   FileManager.default.fileExists(atPath: url.path) {
                    ChatViewModel.shared.attachImage(from: url)
                    attached = true
                } else if url.path.contains("screencaptureui") {
                    // If macOS gave the temp folder path, find any image file inside it
                    if let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                        for item in items where ["png", "jpg", "jpeg", "tiff", "heic"].contains(item.pathExtension.lowercased()) {
                            ChatViewModel.shared.attachImage(from: item)
                            attached = true
                        }
                    }
                }
            }
            if attached {
                PanelController.shared.showPanel()
                return true
            }
        }

        // 2. Check raw PNG / TIFF bitmap data on the dragging pasteboard (used by macOS bottom-right screenshot preview before file flush)
        if let pngData = pb.data(forType: .png) {
            ChatViewModel.shared.attachImage(data: pngData, mimeType: "image/png", fileName: "Screenshot.png")
            PanelController.shared.showPanel()
            return true
        }
        if let tiffData = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiffData),
           let png = rep.representation(using: .png, properties: [:]) {
            ChatViewModel.shared.attachImage(data: png, mimeType: "image/png", fileName: "Screenshot.png")
            PanelController.shared.showPanel()
            return true
        }

        return false
    }
}
