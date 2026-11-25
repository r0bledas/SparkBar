import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Standalone native macOS full-screen / resizable chat window controller, completely separate from `FloatingPanel`.
@MainActor
public final class FullScreenChatWindowController: NSObject, NSWindowDelegate {
    public static let shared = FullScreenChatWindowController()

    private var window: NSWindow?

    private override init() {
        super.init()
    }

    public var isVisible: Bool {
        window?.isVisible ?? false
    }

    public func showWindow(enterFullScreen: Bool = false) {
        if window == nil {
            let hostingController = NSHostingController(rootView: FullScreenChatView())
            let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            let initialWidth = min(max(screenFrame.width * 0.78, 920), 1240)
            let initialHeight = min(max(screenFrame.height * 0.82, 640), 860)

            let win = FullScreenChatNSWindow(
                contentRect: NSRect(x: 0, y: 0, width: initialWidth, height: initialHeight),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.title = "SparkBar"
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true
            let toolbar = NSToolbar(identifier: "SparkBarFullScreenToolbar")
            toolbar.showsBaselineSeparator = false
            win.toolbar = toolbar
            win.toolbarStyle = .unified
            win.isMovableByWindowBackground = false
            win.minSize = NSSize(width: 780, height: 540)
            win.contentViewController = hostingController
            win.isReleasedWhenClosed = false
            win.level = .normal
            win.collectionBehavior = [.fullScreenPrimary, .moveToActiveSpace]
            win.delegate = self
            win.center()
            self.window = win
        }

        // Hide the floating panel when switching into the dedicated full-screen chat window
        PanelController.shared.hidePanel()
        ChatViewModel.shared.showHistory = false

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()

        if let lastUserMsgId = ChatViewModel.shared.messages.last(where: { $0.role == .user })?.id {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                ChatViewModel.shared.scrollToMessageTrigger.send(lastUserMsgId)
            }
        }

        if enterFullScreen, let win = window, !win.styleMask.contains(.fullScreen) {
            win.toggleFullScreen(nil)
        }
    }

    public func closeWindow() {
        window?.close()
    }

    public func windowWillClose(_ notification: Notification) {
        ChatViewModel.shared.persistCurrentSession()
    }
}

/// Custom `NSWindow` subclass supporting native macOS titlebar double-click to expand/zoom,
/// `⌘V` image pasting, and standard SparkBar shortcuts (`⌘N`, `⌘,`).
private final class FullScreenChatNSWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        // Native macOS double-click on the titlebar / top bar expands (zooms) the window
        if event.type == .leftMouseUp && event.clickCount == 2 {
            let titlebarHeight: CGFloat = 38
            if event.locationInWindow.y >= frame.height - titlebarHeight {
                // Only zoom if not clicking an interactive control (button / text field)
                let hit = contentView?.hitTest(event.locationInWindow)
                if !(hit is NSControl) {
                    performZoom(nil)
                    return
                }
            }
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            let char = event.charactersIgnoringModifiers?.lowercased()
            if char == "n" {
                ChatViewModel.shared.startNewConversation()
                return true
            }
            if char == "," {
                SettingsWindowController.shared.showWindow()
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

/// Full-screen / full-size native macOS SparkBar window with an integrated History sidebar and spacious chat canvas.
public struct FullScreenChatView: View {
    @ObservedObject private var viewModel = ChatViewModel.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var conversationStore = ConversationStore.shared

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var historySearchText: String = ""
    @State private var hoveredSessionId: UUID? = nil
    @State private var expandedToolIds: Set<UUID> = []
    @State private var expandedReasoningIds: Set<UUID> = []
    @State private var copiedMessageId: UUID? = nil
    @State private var copiedToolCommandId: UUID? = nil
    @State private var copiedToolOutputId: UUID? = nil
    @State private var isUserScrolledUp: Bool = false
    @State private var isDropTargeted: Bool = false

    public init() {}

    private var filteredSessions: [ConversationSession] {
        let q = historySearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return conversationStore.sessions }
        return conversationStore.sessions.filter { session in
            if session.title.lowercased().contains(q) { return true }
            return session.messages.contains { $0.content.lowercased().contains(q) }
        }
    }

    private var visibleMessages: [ChatMessage] {
        let all = viewModel.messages
        return all.enumerated().compactMap { index, msg in
            switch msg.role {
            case .user, .tool:
                return msg
            case .assistant:
                let hasText = !msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let hasReasoning = !(msg.reasoningContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let isLastStreaming = viewModel.isStreaming && index == all.count - 1 && viewModel.activeToolStatus == nil
                return (hasText || hasReasoning || isLastStreaming) ? msg : nil
            case .system:
                return msg.content.hasPrefix("Switched to:") ? msg : nil
            }
        }
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarView
                .navigationSplitViewColumnWidth(min: 220, ideal: 268, max: 340)
        } detail: {
            detailChatPane
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 780, minHeight: 540)
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            handleDroppedItems(providers: providers)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .strokeBorder(Color.accentColor.opacity(isDropTargeted ? 0.75 : 0), lineWidth: 3)
                .allowsHitTesting(false)
        )
    }

    // MARK: - Integrated History Sidebar

    private var sidebarView: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Text("History")
                    .font(.system(size: 14, weight: .semibold))
                Text("(\(conversationStore.sessions.count))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    viewModel.startNewConversation()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 26, height: 26)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .help("New Chat (⌘N)")
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 10)

            // Search Bar
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                TextField("Search history…", text: $historySearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                if !historySearchText.isEmpty {
                    Button {
                        historySearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            Divider()
                .opacity(0.4)

            // Session List
            if filteredSessions.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary.opacity(0.7))
                    Text(historySearchText.isEmpty ? "No conversations yet" : "No matches")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredSessions) { session in
                            let isCurrent = session.id == viewModel.currentSessionId && !viewModel.messages.isEmpty
                            let isHovered = hoveredSessionId == session.id

                            HStack(alignment: .center, spacing: 8) {
                                Button {
                                    viewModel.loadSession(session)
                                } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 5) {
                                            if isCurrent {
                                                Circle()
                                                    .fill(Color.accentColor)
                                                    .frame(width: 6, height: 6)
                                            }
                                            Text(session.title)
                                                .font(.system(size: 12.5, weight: isCurrent ? .semibold : .medium))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Spacer(minLength: 4)
                                            Text(Self.formatRelativeDate(session.updatedAt))
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                        }

                                        HStack(spacing: 6) {
                                            Text(session.previewSnippet)
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                            Spacer(minLength: 2)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if isHovered || isCurrent {
                                    Button {
                                        conversationStore.deleteSession(id: session.id)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 22, height: 22)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .help("Delete conversation")
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                isCurrent
                                    ? Color.accentColor.opacity(0.15)
                                    : (isHovered ? Color.primary.opacity(0.055) : Color.clear),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .onHover { hovering in
                                hoveredSessionId = hovering ? session.id : (hoveredSessionId == session.id ? nil : hoveredSessionId)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
            }

            Divider()
                .opacity(0.4)

            // Sidebar Footer
            HStack(spacing: 10) {
                Button {
                    conversationStore.openLogsFolderInFinder()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                        Text("Logs Folder")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open Markdown conversation logs in Finder")

                Spacer()

                Button {
                    SettingsWindowController.shared.showWindow()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Main Chat Detail Pane

    private var detailChatPane: some View {
        VStack(spacing: 0) {
            if visibleMessages.isEmpty && viewModel.errorMessage == nil && viewModel.activeToolStatus == nil {
                emptyStateView
            } else {
                chatStreamView
            }

            // Bottom Composer Card
            composerContainer
                .padding(.horizontal, 24)
                .padding(.bottom, 18)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlayPreferenceValue(HoveredImageTooltipAnchorKey.self) { item in
            GeometryReader { geo in
                if let item = item, !item.fileName.isEmpty {
                    let thumbRect = geo[item.bounds]
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item.fileName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 240)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color(nsColor: .windowBackgroundColor))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.75)
                                    )
                            )

                        SpeechBubblePointer()
                            .fill(Color(nsColor: .windowBackgroundColor))
                            .frame(width: 10, height: 5)
                            .overlay(
                                SpeechBubblePointerStroke()
                                    .stroke(Color.white.opacity(0.28), lineWidth: 0.75)
                            )
                            .padding(.leading, 17)
                            .offset(y: -0.5)
                    }
                    .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 2)
                    .fixedSize()
                    .offset(x: thumbRect.minX, y: thumbRect.minY - 34)
                    .allowsHitTesting(false)
                }
            }
            .allowsHitTesting(false)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
               let nsImg = NSImage(contentsOf: iconURL) {
                Image(nsImage: nsImg)
                    .resizable()
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)
            }
            Text("SparkBar")
                .font(.system(size: 20, weight: .semibold))
            Text("Select a conversation from History or start a new chat below.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chatStreamView: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        let items = visibleMessages
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, msg in
                            messageRow(for: msg)
                                .id(msg.id)

                            if index < items.count - 1 {
                                let nextMsg = items[index + 1]
                                if isBotChainItem(msg) && isBotChainItem(nextMsg) {
                                    HStack(spacing: 0) {
                                        Rectangle()
                                            .fill(Color.primary.opacity(0.26))
                                            .frame(width: 2, height: 14)
                                            .padding(.leading, 24)
                                        Spacer()
                                    }
                                } else {
                                    Spacer().frame(height: 14)
                                }
                            }
                        }

                        if let toolStatus = viewModel.activeToolStatus {
                            if let last = items.last, isBotChainItem(last) {
                                HStack(spacing: 0) {
                                    Rectangle()
                                        .fill(Color.primary.opacity(0.26))
                                        .frame(width: 2, height: 14)
                                        .padding(.leading, 24)
                                    Spacer()
                                }
                            } else if !items.isEmpty {
                                Spacer().frame(height: 12)
                            }

                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(toolStatus)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                            .id("fs_tool_status_indicator")
                        }

                        if let error = viewModel.errorMessage {
                            Spacer().frame(height: 12)
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(error)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(.primary)
                                        .textSelection(.enabled)
                                    Button("Open Settings") {
                                        SettingsWindowController.shared.showWindow()
                                    }
                                    .controlSize(.small)
                                }
                                Spacer()
                            }
                            .padding(12)
                            .background(Color.red.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .id("fs_error_banner")
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("fs_stream_bottom_anchor")
                            .onAppear {
                                isUserScrolledUp = false
                            }
                    }
                    .frame(maxWidth: 780)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                }

                if isUserScrolledUp {
                    Button {
                        isUserScrolledUp = false
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo("fs_stream_bottom_anchor", anchor: .bottom)
                        }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: 30, height: 30)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.28), radius: 5, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 12)
                    .help("Scroll to bottom")
                }
            }
            .onChange(of: viewModel.messages.last?.content) { _, _ in
                guard !isUserScrolledUp else { return }
                proxy.scrollTo("fs_stream_bottom_anchor", anchor: .bottom)
            }
            .onChange(of: visibleMessages.count) { _, _ in
                if viewModel.messages.last?.role == .user {
                    isUserScrolledUp = false
                }
                guard !isUserScrolledUp else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("fs_stream_bottom_anchor", anchor: .bottom)
                }
            }
            .onReceive(viewModel.scrollToMessageTrigger) { targetId in
                isUserScrolledUp = false
                proxy.scrollTo(targetId, anchor: .top)
            }
        }
    }

    // MARK: - Composer Card

    private var composerContainer: some View {
        VStack(spacing: 0) {
            if !viewModel.attachedImages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(viewModel.attachedImages) { img in
                            AttachedImageThumbnailView(image: img) {
                                viewModel.removeAttachedImage(id: img.id)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .scrollClipDisabled()
                .frame(height: 64)
                .frame(maxWidth: .infinity, alignment: .leading)
                .zIndex(999)

                Divider().opacity(0.35)
            }

            if let switchBanner = viewModel.pendingModelSwitchBanner {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color.accentColor)
                    Text(switchBanner)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.08))
                Divider().opacity(0.3)
            }

            // Input Row
            HStack(spacing: 12) {
                WrappingPromptTextView(
                    text: $viewModel.inputText,
                    placeholder: "Ask anything or run a task… (⌥ + Space)",
                    onSubmit: {
                        viewModel.sendCurrentPrompt()
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .black, location: 0.14),
                            .init(color: .black, location: 0.86),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                if viewModel.isStreaming {
                    Button {
                        viewModel.stopGeneration()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Stop generating")
                } else {
                    let canSend = !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !viewModel.attachedImages.isEmpty
                    Button {
                        viewModel.sendCurrentPrompt()
                    } label: {
                        Image(systemName: "arrow.right.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .disabled(!canSend)
                    .help("Send prompt (Return)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(height: 54)

            Divider().opacity(0.35)

            // Bottom Control Row
            HStack(spacing: 10) {
                Button {
                    selectImageFromFilePicker()
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(viewModel.attachedImages.isEmpty ? Color.secondary : Color.accentColor)
                        .frame(width: 16, height: 18)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Attach image or screenshot (⌘V)")

                Divider().frame(height: 13).opacity(0.6)

                if settings.showProviderInMainBar {
                    Menu {
                        ForEach(LLMProviderType.allCases) { provider in
                            Button {
                                settings.selectedProvider = provider
                            } label: {
                                HStack {
                                    Text(provider.displayName)
                                    if settings.selectedProvider == provider {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(hasValidKeyForCurrentProvider ? Color.green : Color.orange)
                                .frame(width: 7, height: 7)
                            Text(settings.selectedProvider.displayName)
                                .font(.system(size: 11.5, weight: .semibold))
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                Menu {
                    if settings.availableModels.isEmpty {
                        Button("Refresh Models…") {
                            Task { await settings.refreshModelsForCurrentProvider() }
                        }
                    } else {
                        ForEach(settings.availableModels) { modelInfo in
                            Button {
                                let oldLabel = currentModelBarLabel
                                viewModel.handleModelSwitch(from: oldLabel, to: modelInfo.displayLabel, newModelId: modelInfo.id)
                            } label: {
                                HStack {
                                    Text(modelInfo.displayLabel)
                                    if settings.currentModelInfo?.id == modelInfo.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                        Divider()
                        Button("Refresh Models") {
                            Task { await settings.refreshModelsForCurrentProvider() }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        if !settings.showProviderInMainBar {
                            Circle()
                                .fill(hasValidKeyForCurrentProvider ? Color.green : Color.orange)
                                .frame(width: 7, height: 7)
                        }
                        Text(currentModelBarLabel)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                let dynamicLevels = settings.dynamicModelEffortLevelsOnly
                if !dynamicLevels.isEmpty {
                    Divider().frame(height: 13).opacity(0.6)

                    Menu {
                        if settings.currentModelInfo?.effortVariantModelIds == nil {
                            Button {
                                settings.reasoningEffort = "none"
                            } label: {
                                HStack {
                                    Text("None")
                                    if settings.reasoningEffort.lowercased() == "none" {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }

                        Button {
                            settings.reasoningEffort = "default"
                        } label: {
                            HStack {
                                Text(settings.effortDisplayLabel(for: "default"))
                                if settings.reasoningEffort.lowercased() == "default" {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }

                        Divider()

                        ForEach(dynamicLevels, id: \.self) { level in
                            Button {
                                settings.reasoningEffort = level
                            } label: {
                                HStack {
                                    Text(settings.effortDisplayLabel(for: level))
                                    if settings.reasoningEffort.lowercased() == level.lowercased() {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Text(settings.effortDisplayLabel(for: settings.reasoningEffort))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                Divider().frame(height: 13).opacity(0.6)

                Button {
                    settings.enableTools.toggle()
                    settings.enableWebSearchTool = settings.enableTools
                } label: {
                    Image(systemName: settings.enableTools ? "hammer.fill" : "hammer")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(settings.enableTools ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            (settings.enableTools ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05)),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Toggle autonomous tools & web search")

                Spacer()

                if !viewModel.messages.isEmpty {
                    Button {
                        viewModel.startNewConversation()
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus.bubble")
                                .font(.system(size: 11))
                            Text("New")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("New Chat (⌘N)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(height: 36)
        }
        .frame(maxWidth: 780)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                .allowsHitTesting(false)
        )
    }

    // MARK: - Message & Tool Row Rendering

    private func isBotChainItem(_ msg: ChatMessage) -> Bool {
        msg.role == .assistant || msg.role == .tool
    }

    @ViewBuilder
    private func messageRow(for message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                if !message.attachedImages.isEmpty {
                    HStack(spacing: 8) {
                        Spacer(minLength: 80)
                        ForEach(message.attachedImages) { img in
                            if let data = Data(base64Encoded: img.base64Data),
                               let nsImg = NSImage(data: data) {
                                Image(nsImage: nsImg)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 180)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
                                    )
                                    .onTapGesture {
                                        if let p = img.localFilePath {
                                            NSWorkspace.shared.open(URL(fileURLWithPath: p))
                                        }
                                    }
                            }
                        }
                    }
                }

                if !message.content.isEmpty {
                    HStack {
                        Spacer(minLength: 80)
                        Text(message.content)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Color.accentColor.opacity(0.88), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .textSelection(.enabled)
                    }
                }
            }

        case .tool:
            if let record = message.toolRecords.first {
                toolRecordBadge(record)
            } else {
                toolRecordBadge(
                    ToolExecutionRecord(
                        id: message.id,
                        toolCallId: message.toolCallId ?? "",
                        toolName: message.toolName ?? "tool",
                        arguments: "",
                        output: message.content,
                        durationMs: 0,
                        isError: false
                    )
                )
            }

        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if let reasoning = message.reasoningContent, !reasoning.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            if expandedReasoningIds.contains(message.id) {
                                expandedReasoningIds.remove(message.id)
                            } else {
                                expandedReasoningIds.insert(message.id)
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: expandedReasoningIds.contains(message.id) ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("Thought Process")
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)

                        if expandedReasoningIds.contains(message.id) {
                            Text(reasoning)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(10)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                                .textSelection(.enabled)
                        }
                    }
                }

                if !message.content.isEmpty {
                    MarkdownMessageView(text: message.content)
                        .equatable()

                    Rectangle()
                        .fill(Color.primary.opacity(0.14))
                        .frame(height: 1)
                        .padding(.vertical, 4)

                    HStack(spacing: 12) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.content, forType: .string)
                            copiedMessageId = message.id
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                if copiedMessageId == message.id { copiedMessageId = nil }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: copiedMessageId == message.id ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 10))
                                Text(copiedMessageId == message.id ? "Copied" : "Copy Answer")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                } else if viewModel.isStreaming && message.id == viewModel.messages.last?.id && viewModel.activeToolStatus == nil {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Thinking…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        case .system:
            HStack(spacing: 8) {
                Rectangle().fill(Color.primary.opacity(0.18)).frame(height: 1)
                Text(message.content)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Rectangle().fill(Color.primary.opacity(0.18)).frame(height: 1)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func toolRecordBadge(_ record: ToolExecutionRecord) -> some View {
        let isExpanded = expandedToolIds.contains(record.id)
        let commandText = Self.formattedToolCommand(for: record)

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Button {
                        if isExpanded {
                            expandedToolIds.remove(record.id)
                        } else {
                            expandedToolIds.insert(record.id)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: Self.iconName(for: record))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(record.isError ? Color.orange : Color.accentColor)
                            Text(Self.displayToolTitle(for: record))
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                            if !isExpanded {
                                Text(commandText)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            Spacer(minLength: 4)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if isExpanded {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(commandText, forType: .string)
                            copiedToolCommandId = record.id
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                if copiedToolCommandId == record.id { copiedToolCommandId = nil }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: copiedToolCommandId == record.id ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 9.5))
                                Text(copiedToolCommandId == record.id ? "Copied" : "Copy")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(copiedToolCommandId == record.id ? Color.green : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        if isExpanded {
                            expandedToolIds.remove(record.id)
                        } else {
                            expandedToolIds.insert(record.id)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("\(record.durationMs)ms")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if isExpanded {
                    Text(commandText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary.opacity(0.92))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )

            if isExpanded {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.26))
                        .frame(width: 2, height: 12)
                        .padding(.leading, 24)
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Output")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(record.output, forType: .string)
                            copiedToolOutputId = record.id
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                if copiedToolOutputId == record.id { copiedToolOutputId = nil }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: copiedToolOutputId == record.id ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 9.5))
                                Text(copiedToolOutputId == record.id ? "Copied" : "Copy")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(copiedToolOutputId == record.id ? Color.green : Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 6)

                    ScrollView {
                        Text(record.output.isEmpty ? "(no output)" : record.output)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 7)
                    }
                    .frame(maxHeight: 200)
                }
                .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
            }
        }
    }

    // MARK: - Helpers

    private var currentModelBarLabel: String {
        if let info = settings.currentModelInfo { return info.displayLabel }
        if !settings.currentModel.isEmpty { return settings.currentModel }
        return settings.isFetchingModels ? "Loading models…" : "Select Model"
    }

    private var hasValidKeyForCurrentProvider: Bool {
        if !settings.selectedProvider.requiresAPIKey { return true }
        return !settings.apiKey(for: settings.selectedProvider).isEmpty
    }

    private static func formatRelativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private static func iconName(for record: ToolExecutionRecord) -> String {
        if record.isError { return "xmark.octagon.fill" }
        let name = record.toolName.lowercased()
        if name.contains("search") || name.contains("web") || name.contains("url") { return "globe" }
        if name.contains("file") || name.contains("dir") || name.contains("grep") || name.contains("find") { return "doc.text" }
        if name.contains("clipboard") { return "doc.on.clipboard" }
        if name.contains("pdf") { return "doc.richtext" }
        return "apple.terminal"
    }

    private static func displayToolTitle(for record: ToolExecutionRecord) -> String {
        switch record.toolName.lowercased() {
        case "web_search", "search_web": return "Searched:"
        case "fetch_url", "read_url_content": return "Viewed:"
        default: return record.toolName
        }
    }

    private static func formattedToolCommand(for record: ToolExecutionRecord) -> String {
        if let data = record.arguments.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            switch record.toolName.lowercased() {
            case "run_command":
                if let cmd = (obj["command"] as? String) ?? (obj["CommandLine"] as? String), !cmd.isEmpty { return cmd }
            case "web_search", "search_web":
                if let query = (obj["query"] as? String) ?? (obj["Query"] as? String), !query.isEmpty { return query }
            case "fetch_url", "read_url_content":
                if let url = (obj["url"] as? String) ?? (obj["Url"] as? String), !url.isEmpty { return url }
            default:
                break
            }
        }
        return record.arguments
    }

    private func selectImageFromFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .png, .jpeg, .webP, .gif, .tiff]
        viewModel.isPickingFile = true
        panel.begin { response in
            Task { @MainActor in
                viewModel.isPickingFile = false
                guard response == .OK else { return }
                for url in panel.urls {
                    viewModel.attachImage(from: url)
                }
            }
        }
    }

    private func handleDroppedItems(providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url = url else { return }
                    let ext = url.pathExtension.lowercased()
                    if ["png", "jpg", "jpeg", "webp", "gif", "heic", "tiff", "bmp"].contains(ext) {
                        DispatchQueue.main.async {
                            viewModel.attachImage(from: url)
                        }
                    }
                }
                handled = true
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data = data else { return }
                    DispatchQueue.main.async {
                        viewModel.attachImage(data: data, mimeType: "image/png", fileName: "Dropped_Image.png")
                    }
                }
                handled = true
            }
        }
        return handled
    }
}
