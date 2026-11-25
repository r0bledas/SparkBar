import SwiftUI
import AppKit
import UniformTypeIdentifiers

public struct FloatingPromptView: View {
    @ObservedObject private var viewModel = ChatViewModel.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var conversationStore = ConversationStore.shared
    @FocusState private var isInputFocused: Bool
    @State private var expandedToolIds: Set<UUID> = []
    @State private var expandedReasoningIds: Set<UUID> = []
    @State private var copiedMessageId: UUID? = nil
    @State private var copiedToolCommandId: UUID? = nil
    @State private var copiedToolOutputId: UUID? = nil
    @State private var isUserScrolledUp: Bool = false
    @State private var scrollToBottomTrigger: Int = 0
    @State private var scrollWheelMonitor: Any? = nil
    @State private var mouseHoverMonitor: Any? = nil
    @State private var isHoveringTopQuarter: Bool = false
    @State private var historySearchText: String = ""
    @State private var isDropTargeted: Bool = false

    public init() {}

    private var hasActiveChatArea: Bool {
        !visibleMessages.isEmpty || viewModel.errorMessage != nil || viewModel.activeToolStatus != nil || viewModel.showHistory
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 1. Top Conversation / History Area (Only appears when messages exist or History is toggled — collapsed bar stays minimal)
            if hasActiveChatArea {
                // Dedicated top window drag bar (outside the ScrollView, identical to bottomControlBar's drag handle)
                WindowDragHandle()
                    .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20)
                    .overlay(
                        Capsule()
                            .fill(Color.primary.opacity(0.22))
                            .frame(width: 38, height: 4.5)
                            .allowsHitTesting(false)
                    )

                if viewModel.showHistory {
                    historyBrowserArea
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    conversationArea
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Divider()
                    .opacity(0.45)
            }

            // Attached images preview bar (if any)
            if !viewModel.attachedImages.isEmpty {
                attachedImagesPreviewBar
                    .frame(height: 64)
                    .zIndex(999)
                Divider()
                    .opacity(0.35)
            }

            // Deferred model-switch notice banner (shown when switching models mid-turn)
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
                .padding(.horizontal, 18)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.08))
                Divider()
                    .opacity(0.3)
            }

            // 2. Prompt Input Box ("Ask anything or run a task…")
            promptInputBar
                .frame(height: 50)

            Divider()
                .opacity(0.45)

            // 3. Bottom Control Bar (Attachment | Model | Reasoning Effort | Tools | Clear & Settings)
            bottomControlBar
                .frame(height: 38)
        }
        .frame(width: PanelController.panelWidth - 16)
        .background(
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow, state: .active)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color.primary.opacity(0.16), lineWidth: isDropTargeted ? 2 : 1)
                .allowsHitTesting(false)
        )
        // Cornered circular Maximize (top-left) & Hide (top-right) buttons — revealed only when cursor is in the top 1/4 of the expanded window
        .overlay(alignment: .top) {
            if hasActiveChatArea && isHoveringTopQuarter {
                HStack {
                    Button {
                        FullScreenChatWindowController.shared.showWindow()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.primary.opacity(0.88))
                            .frame(width: 26, height: 26)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.75)
                            )
                            .shadow(color: .black.opacity(0.26), radius: 4, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                    .help("Open in Full-Screen Window (⌘⇧F)")
                    .accessibilityLabel("Open Full-Screen Window")

                    Spacer()

                    Button {
                        PanelController.shared.hidePanel()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.primary.opacity(0.88))
                            .frame(width: 26, height: 26)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.75)
                            )
                            .shadow(color: .black.opacity(0.26), radius: 4, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                    .help("Hide SparkBar (Esc)")
                    .accessibilityLabel("Hide SparkBar")
                }
                .padding(.top, 10)
                .padding(.horizontal, 10)
                .transition(.opacity)
            }
        }
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

                        // Downward speech-bubble pointer triangle anchored over the center of the 44pt thumbnail (x = 17..27)
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
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            handleDroppedItems(providers: providers)
        }
        .onAppear {
            isInputFocused = true
            PanelController.shared.syncPanelHeight(hasMessages: hasActiveChatArea)
            setupScrollMonitor()
            setupTopQuarterHoverMonitor()
        }
        .onDisappear {
            if let monitor = scrollWheelMonitor {
                NSEvent.removeMonitor(monitor)
                scrollWheelMonitor = nil
            }
            if let hoverMon = mouseHoverMonitor {
                NSEvent.removeMonitor(hoverMon)
                mouseHoverMonitor = nil
            }
        }
        .onChange(of: hasActiveChatArea) { _, active in
            if !active {
                isUserScrolledUp = false
                isHoveringTopQuarter = false
            }
            PanelController.shared.syncPanelHeight(hasMessages: active)
        }
        .onChange(of: viewModel.attachedImages.count) { _, _ in
            PanelController.shared.syncPanelHeight(hasMessages: hasActiveChatArea)
        }
        .onReceive(PanelController.shared.focusTrigger) { _ in
            isInputFocused = true
        }
    }

    private func setupScrollMonitor() {
        guard scrollWheelMonitor == nil else { return }
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            if event.scrollingDeltaY > 2.0 {
                // User scrolled upward away from the live bottom stream
                if !isUserScrolledUp {
                    isUserScrolledUp = true
                }
            }
            return event
        }
    }

    private func setupTopQuarterHoverMonitor() {
        guard mouseHoverMonitor == nil else { return }
        mouseHoverMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseEntered, .mouseExited]) { event in
            guard let win = event.window, win is FloatingPanel else {
                if isHoveringTopQuarter { isHoveringTopQuarter = false }
                return event
            }
            let h = win.frame.height
            let w = win.frame.width
            let loc = event.locationInWindow
            let inTopQuarter = (event.type != .mouseExited)
                && loc.x >= 0 && loc.x <= w
                && loc.y >= h * 0.75 && loc.y <= h
            if isHoveringTopQuarter != inTopQuarter {
                withAnimation(.easeInOut(duration: 0.14)) {
                    isHoveringTopQuarter = inTopQuarter
                }
            }
            return event
        }
    }

    // MARK: - Prompt Input Bar (Directly above Bottom Control Bar)

    private var attachedImagesPreviewBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(viewModel.attachedImages) { img in
                    AttachedImageThumbnailView(image: img) {
                        viewModel.removeAttachedImage(id: img.id)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
        }
        .scrollClipDisabled()
        .frame(maxWidth: .infinity, alignment: .leading)
        .zIndex(50)
    }

    private var promptInputBar: some View {
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
            .accessibilityLabel("Prompt Input")

            if viewModel.isStreaming {
                Button {
                    viewModel.stopGeneration()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.red)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Stop generating")
                .accessibilityLabel("Stop generating")
            } else {
                let canSend = !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !viewModel.attachedImages.isEmpty
                Button {
                    viewModel.sendCurrentPrompt()
                } label: {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(
                            canSend ? Color.accentColor : Color.secondary.opacity(0.35)
                        )
                }
                .buttonStyle(.plain)
                .fixedSize()
                .disabled(!canSend)
                .help("Send prompt (Return)")
                .accessibilityLabel("Send prompt")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    // MARK: - Chronological Conversation & Tool Stream Area

    private var conversationArea: some View {
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
                                    // White vertical connector line aligned after 2x the corner-rounding inset (12pt * 2 = 24pt)
                                    HStack(spacing: 0) {
                                        Rectangle()
                                            .fill(Color.white.opacity(0.38))
                                            .frame(width: 2, height: 14)
                                            .padding(.leading, 24)
                                        Spacer()
                                    }
                                } else {
                                    Spacer()
                                        .frame(height: 12)
                                }
                            }
                        }

                        if let toolStatus = viewModel.activeToolStatus {
                            if let last = items.last, isBotChainItem(last) {
                                HStack(spacing: 0) {
                                    Rectangle()
                                        .fill(Color.white.opacity(0.38))
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
                            .id("tool_status_indicator")
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
                            .id("error_banner")
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("stream_bottom_anchor")
                            .onAppear {
                                // When the bottom anchor becomes visible again, hide the floating arrow
                                isUserScrolledUp = false
                            }
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 6)
                    .padding(.bottom, 14)
                }

                // Centered floating down-arrow button above the "Ask anything" bar when user scrolls up
                if isUserScrolledUp {
                    Button {
                        isUserScrolledUp = false
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo("stream_bottom_anchor", anchor: .bottom)
                        }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: 28, height: 28)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.white.opacity(0.25), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.28), radius: 5, x: 0, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                    .help("Scroll to bottom")
                }
            }
            .onChange(of: viewModel.messages.last?.content) { _, _ in
                guard !isUserScrolledUp else { return }
                proxy.scrollTo("stream_bottom_anchor", anchor: .bottom)
            }
            .onChange(of: visibleMessages.count) { _, _ in
                if viewModel.messages.last?.role == .user {
                    isUserScrolledUp = false
                }
                guard !isUserScrolledUp else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("stream_bottom_anchor", anchor: .bottom)
                }
            }
            .onReceive(viewModel.scrollToMessageTrigger) { targetId in
                isUserScrolledUp = false
                proxy.scrollTo(targetId, anchor: .top)
            }
        }
    }

    private func isBotChainItem(_ msg: ChatMessage) -> Bool {
        msg.role == .assistant || msg.role == .tool
    }

    /// Chronological items to display in the stream:
    /// - User messages
    /// - Separate Tool execution messages (in exact chronological order, outside assistant text bubbles)
    /// - Assistant messages that actually have content, reasoning, or are currently the active streaming placeholder
    private var visibleMessages: [ChatMessage] {
        let all = viewModel.messages
        return all.enumerated().compactMap { index, msg in
            switch msg.role {
            case .user:
                return msg
            case .tool:
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

    @ViewBuilder
    private func messageRow(for message: ChatMessage) -> some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                if !message.attachedImages.isEmpty {
                    HStack(spacing: 8) {
                        Spacer(minLength: 60)
                        ForEach(message.attachedImages) { img in
                            if let data = Data(base64Encoded: img.base64Data),
                               let nsImg = NSImage(data: data) {
                                Image(nsImage: nsImg)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 140)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5)
                                    )
                                    .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
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
                        Spacer(minLength: 60)
                        Text(message.content)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background(Color.accentColor.opacity(0.88), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .textSelection(.enabled)
                    }
                }
            }

        case .tool:
            // Standalone chronological tool call block (completely separate from the assistant text bubble)
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
                // Reasoning chain (if present)
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

                // Assistant Markdown Response
                if !message.content.isEmpty {
                    MarkdownMessageView(text: message.content)
                        .equatable()

                    // Harder, more noticeable separator between the bot's content and the Copy Answer action bar
                    Rectangle()
                        .fill(Color.white.opacity(0.28))
                        .frame(height: 1.5)
                        .padding(.vertical, 4)

                    HStack(spacing: 12) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.content, forType: .string)
                            copiedMessageId = message.id
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                if copiedMessageId == message.id {
                                    copiedMessageId = nil
                                }
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
                        .accessibilityLabel("Copy assistant answer")
                    }
                } else if viewModel.isStreaming && message.id == viewModel.messages.last?.id && viewModel.activeToolStatus == nil {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Thinking…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

        case .system:
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color.primary.opacity(0.18))
                    .frame(height: 1)
                Text(message.content)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Rectangle()
                    .fill(Color.primary.opacity(0.18))
                    .frame(height: 1)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func toolRecordBadge(_ record: ToolExecutionRecord) -> some View {
        let isExpanded = expandedToolIds.contains(record.id)
        let commandText = Self.formattedToolCommand(for: record)

        VStack(alignment: .leading, spacing: 0) {
            // 1. Existing Command Badge Box — expands IN-PLACE to reveal the full command when clicked
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

            // 2. Connector line + Output box when expanded
            if isExpanded {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.white.opacity(0.38))
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
                    .frame(maxHeight: 140)
                }
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
            }
        }
    }

    private static func iconName(for record: ToolExecutionRecord) -> String {
        if record.isError { return "xmark.octagon.fill" }
        let name = record.toolName.lowercased()
        if name.contains("search") || name.contains("web") || name.contains("url") {
            return "globe"
        }
        if name.contains("file") || name.contains("dir") || name.contains("grep") || name.contains("find") {
            return "doc.text"
        }
        if name.contains("clipboard") {
            return "doc.on.clipboard"
        }
        if name.contains("pdf") {
            return "doc.richtext"
        }
        return "apple.terminal"
    }

    private static func displayToolTitle(for record: ToolExecutionRecord) -> String {
        switch record.toolName.lowercased() {
        case "web_search", "search_web":
            return "Searched:"
        case "fetch_url", "read_url_content":
            return "Viewed:"
        default:
            return record.toolName
        }
    }

    private static func formattedToolCommand(for record: ToolExecutionRecord) -> String {
        if let data = record.arguments.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            switch record.toolName.lowercased() {
            case "run_command":
                if let cmd = (obj["command"] as? String) ?? (obj["CommandLine"] as? String), !cmd.isEmpty {
                    return cmd
                }
            case "web_search", "search_web":
                if let query = (obj["query"] as? String) ?? (obj["Query"] as? String), !query.isEmpty {
                    return query
                }
            case "fetch_url", "read_url_content":
                if let url = (obj["url"] as? String) ?? (obj["Url"] as? String), !url.isEmpty {
                    return url
                }
            default:
                break
            }
        }
        return record.arguments
    }

    // MARK: - Bottom Control & Model / Reasoning Effort Bar

    private var bottomControlBar: some View {
        HStack(spacing: 10) {
            // Attachment icon on the left of the model selector (ultra-compact width)
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
            .help("Attach image or screenshot (or paste with ⌘V)")
            .accessibilityLabel("Attach image")

            // Separator between Attachment icon and Model selector
            Divider()
                .frame(height: 13)
                .opacity(0.6)

            // Optional AI Provider Picker (Only shown if enabled in Settings)
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
                .help("Select AI Provider")
            }

            // Dynamic Model Dropdown (Shows clean API name e.g. DeepSeek-V4.1-Flash, DeepSeek-V4-Pro)
            Menu {
                if settings.availableModels.isEmpty {
                    Button("Refresh Models from API…") {
                        Task {
                            await settings.refreshModelsForCurrentProvider()
                        }
                    }
                } else {
                    ForEach(settings.availableModels) { modelInfo in
                        Button {
                            let oldLabel = currentModelBarLabel
                            viewModel.handleModelSwitch(from: oldLabel, to: modelInfo.displayLabel, newModelId: modelInfo.id)
                        } label: {
                            HStack {
                                Text(modelInfo.displayLabel)
                                if settings.currentModel == modelInfo.id {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                    Divider()
                    Button("Refresh Models from API") {
                        Task {
                            await settings.refreshModelsForCurrentProvider()
                        }
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
            .help("Select Model (dynamically loaded from API)")

            // Dynamic Thinking Effort Dropdown (Hierarchical: None, Default, Divider, then API levels low / high / max)
            let dynamicLevels = settings.dynamicModelEffortLevelsOnly

            if !dynamicLevels.isEmpty {
                // Visual Separator between Model and Thinking Effort
                Divider()
                    .frame(height: 13)
                    .opacity(0.6)

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
                .help("Select Thinking Effort")
            }

            // Visual Separator before the consolidated Tools icon
            Divider()
                .frame(height: 13)
                .opacity(0.6)

            // Single consolidated Tools icon button (controls Tools + Web Search together)
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
            .accessibilityLabel("Toggle Tools")

            // Empty space in the bottom bar acts as a drag handle to move the window
            WindowDragHandle()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

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
                    .fixedSize()
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .keyboardShortcut("k", modifiers: [.command])
                .help("Save to log & start new chat (⌘N / ⌘K)")
            }

            Button {
                viewModel.toggleHistory()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(viewModel.showHistory ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(
                        (viewModel.showHistory ? Color.accentColor.opacity(0.16) : Color.clear),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .fixedSize()
            .keyboardShortcut("y", modifiers: [.command])
            .help("Conversation History & Logs (⌘Y)")
            .accessibilityLabel("Conversation History")

            Button {
                SettingsWindowController.shared.showWindow()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .keyboardShortcut(",", modifiers: [.command])
            .help("Settings & API Keys (⌘,)")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(height: 38)
        .background(WindowDragHandle())
    }

    // MARK: - Conversation History & Log Browser

    private var filteredHistorySessions: [ConversationSession] {
        let q = historySearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return conversationStore.sessions }
        return conversationStore.sessions.filter { session in
            if session.title.lowercased().contains(q) { return true }
            return session.messages.contains { $0.content.lowercased().contains(q) }
        }
    }

    private var historyBrowserArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header & Actions
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text("History")
                    .font(.system(size: 13.5, weight: .semibold))

                Text("(\(conversationStore.sessions.count))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                WindowDragHandle()
                    .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 24)

                Button {
                    conversationStore.openLogsFolderInFinder()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 10.5))
                        Text("Logs Folder")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Open Markdown conversation logs in Finder")

                Button {
                    viewModel.startNewConversation()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 10.5, weight: .bold))
                        Text("New Chat")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Start a new conversation (⌘N)")
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)

            // Search / Filter Input
            HStack(spacing: 8) {
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
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 18)

            // Session List
            if filteredHistorySessions.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "tray")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text(historySearchText.isEmpty ? "No saved conversations yet." : "No conversations match \"\(historySearchText)\".")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(filteredHistorySessions) { session in
                            let isCurrent = session.id == viewModel.currentSessionId && !viewModel.messages.isEmpty
                            HStack(alignment: .top, spacing: 10) {
                                Button {
                                    viewModel.loadSession(session)
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 6) {
                                            if isCurrent {
                                                Circle()
                                                    .fill(Color.accentColor)
                                                    .frame(width: 6, height: 6)
                                            }
                                            Text(session.title)
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            Spacer()
                                            Text(Self.formatRelativeDate(session.updatedAt))
                                                .font(.system(size: 10.5, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                        }

                                        Text(session.previewSnippet)
                                            .font(.system(size: 11.5))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)

                                        HStack(spacing: 8) {
                                            Text("\(session.userAndAssistantMessageCount) msgs")
                                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                            if !session.model.isEmpty {
                                                Text(session.model)
                                                    .font(.system(size: 10, design: .monospaced))
                                                    .foregroundStyle(.secondary)
                                                    .padding(.horizontal, 5)
                                                    .padding(.vertical, 1)
                                                    .background(Color.primary.opacity(0.06), in: Capsule())
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    conversationStore.deleteSession(id: session.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .padding(6)
                                }
                                .buttonStyle(.plain)
                                .help("Delete this conversation")
                            }
                            .padding(10)
                            .background(
                                (isCurrent ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045)),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(isCurrent ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.07), lineWidth: 0.5)
                            )
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private static func formatRelativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private var currentModelBarLabel: String {
        if let info = settings.currentModelInfo {
            return info.displayLabel
        }
        if !settings.currentModel.isEmpty {
            return settings.currentModel
        }
        return settings.isFetchingModels ? "Loading models…" : "Select Model"
    }

    private var hasValidKeyForCurrentProvider: Bool {
        if !settings.selectedProvider.requiresAPIKey { return true }
        return !settings.apiKey(for: settings.selectedProvider).isEmpty
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
                PanelController.shared.showPanel()
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
                            PanelController.shared.showPanel()
                        }
                    }
                }
                handled = true
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data = data else { return }
                    DispatchQueue.main.async {
                        viewModel.attachImage(data: data, mimeType: "image/png", fileName: "Dropped_Image.png")
                        PanelController.shared.showPanel()
                    }
                }
                handled = true
            }
        }
        return handled
    }
}

/// Compact thumbnail-only preview for an attached image:
/// - Instantly shows a top-right `×` remove badge on hover.
/// - Instantly pops up a comment-style speech bubble above the thumbnail stating the filename on hover, on the top layer.
struct AttachedImageThumbnailView: View {
    let image: AttachedImage
    let onRemove: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Thumbnail Preview (44 x 44) — static appearance with zero darkening or border animation on hover
            Group {
                if let data = Data(base64Encoded: image.base64Data),
                   let nsImg = NSImage(data: data) {
                    Image(nsImage: nsImg)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 44, height: 44)
                        .overlay(
                            Image(systemName: "photo")
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                        )
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            )

            // Instant top-right 'X' remove button on hover
            if isHovered {
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.black.opacity(0.82))
                        .font(.system(size: 15))
                        .shadow(color: .black.opacity(0.35), radius: 2, x: 0, y: 1)
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
                .zIndex(10)
                .accessibilityLabel("Remove attached image")
            }
        }
        .anchorPreference(key: HoveredImageTooltipAnchorKey.self, value: .bounds) { anchor in
            isHovered ? HoveredImageTooltipData(fileName: image.fileName ?? "", bounds: anchor) : nil
        }
        .zIndex(isHovered ? 999 : 0)
        .animation(nil, value: isHovered)
        .onHover { hovering in
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                isHovered = hovering
            }
        }
    }
}

struct HoveredImageTooltipData {
    let fileName: String
    let bounds: Anchor<CGRect>
}

struct HoveredImageTooltipAnchorKey: PreferenceKey {
    static var defaultValue: HoveredImageTooltipData? = nil
    static func reduce(value: inout HoveredImageTooltipData?, nextValue: () -> HoveredImageTooltipData?) {
        if let next = nextValue() {
            value = next
        }
    }
}

struct SpeechBubblePointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct SpeechBubblePointerStroke: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

/// Multi-line wrapping text input view backed by `SparkBarFieldEditor` inside a fixed-height `NSScrollView`.
/// Wraps text by lines so the typing caret is never hidden horizontally, auto-scrolls vertically,
/// submits on `Return`, and inserts a newline on `Shift + Return`.
struct WrappingPromptTextView: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = PromptWrappingNSTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = onSubmit
        textView.placeholderString = placeholder
        textView.drawsBackground = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 16.5, weight: .regular)
        textView.textColor = NSColor.labelColor
        textView.insertionPointColor = NSColor.controlAccentColor
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? PromptWrappingNSTextView else { return }
        textView.onSubmit = onSubmit
        if textView.string != text {
            textView.string = text
            textView.needsDisplay = true
            textView.scrollRangeToVisible(textView.selectedRange())
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: WrappingPromptTextView

        init(_ parent: WrappingPromptTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if parent.text != tv.string {
                parent.text = tv.string
            }
            tv.needsDisplay = true
            tv.scrollRangeToVisible(tv.selectedRange())
        }
    }
}

private final class PromptWrappingNSTextView: SparkBarFieldEditor {
    var onSubmit: (() -> Void)?
    var placeholderString: String = ""

    override func keyDown(with event: NSEvent) {
        // Return / Enter without Shift submits the prompt
        if (event.keyCode == 36 || event.keyCode == 76) && !event.modifierFlags.contains(.shift) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
        scrollRangeToVisible(selectedRange())
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty && !placeholderString.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16.5, weight: .regular),
                .foregroundColor: NSColor.placeholderTextColor
            ]
            let inset = textContainerInset
            let rect = NSRect(
                x: inset.width + 1,
                y: inset.height,
                width: bounds.width - inset.width * 2,
                height: bounds.height - inset.height * 2
            )
            (placeholderString as NSString).draw(in: rect, withAttributes: attrs)
        }
    }
}
