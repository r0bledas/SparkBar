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
    @State private var isUserScrolledUp: Bool = false
    @State private var scrollToBottomTrigger: Int = 0
    @State private var scrollWheelMonitor: Any? = nil
    @State private var historySearchText: String = ""
    @State private var isDropTargeted: Bool = false

    public init() {}

    private var hasActiveChatArea: Bool {
        !visibleMessages.isEmpty || viewModel.errorMessage != nil || viewModel.activeToolStatus != nil || viewModel.showHistory
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 1. Top Conversation / History Area (Appears above the prompt input when messages exist or History is toggled)
            if hasActiveChatArea {
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
                Divider()
                    .opacity(0.35)
            }

            // 2. Prompt Input Box ("Ask anything or run a task…")
            promptInputBar
                .frame(height: 50)

            Divider()
                .opacity(0.45)

            // 3. Bottom Control Bar (Model | Reasoning Effort | Tools & Web | Clear & Settings)
            bottomControlBar
                .frame(height: 38)
        }
        .background(
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow, state: .active)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isDropTargeted ? Color.accentColor : Color.primary.opacity(0.16), lineWidth: isDropTargeted ? 2 : 1)
        )
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            handleDroppedItems(providers: providers)
        }
        .sheet(isPresented: $viewModel.showSettings) {
            SettingsSheetView()
        }
        .onAppear {
            isInputFocused = true
            PanelController.shared.syncPanelHeight(hasMessages: hasActiveChatArea)
            setupScrollMonitor()
        }
        .onDisappear {
            if let monitor = scrollWheelMonitor {
                NSEvent.removeMonitor(monitor)
                scrollWheelMonitor = nil
            }
        }
        .onChange(of: hasActiveChatArea) { _, active in
            if !active {
                isUserScrolledUp = false
            }
            PanelController.shared.syncPanelHeight(hasMessages: active)
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

    // MARK: - Prompt Input Bar (Directly above Bottom Control Bar)

    private var attachedImagesPreviewBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.attachedImages) { img in
                    HStack(spacing: 6) {
                        if let data = Data(base64Encoded: img.base64Data),
                           let nsImg = NSImage(data: data) {
                            Image(nsImage: nsImg)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 26, height: 26)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        Text(img.fileName ?? "Image")
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                            .frame(maxWidth: 130, alignment: .leading)
                        Button {
                            viewModel.removeAttachedImage(id: img.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove image")
                    }
                    .padding(.leading, 4)
                    .padding(.trailing, 6)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 6)
        }
    }

    private var promptInputBar: some View {
        HStack(spacing: 11) {
            SparkBarLogoView(
                size: 21,
                isActive: viewModel.isStreaming || !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )

            // Photo attachment button
            Button {
                selectImageFromFilePicker()
            } label: {
                Image(systemName: "photo")
                    .font(.system(size: 14))
                    .foregroundStyle(viewModel.attachedImages.isEmpty ? Color.secondary.opacity(0.7) : Color.accentColor)
            }
            .buttonStyle(.plain)
            .help("Attach an image (or paste with ⌘V)")
            .accessibilityLabel("Attach image")

            TextField("Ask anything or run a task… (⌥Space)", text: $viewModel.inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 16.5, weight: .regular))
                .focused($isInputFocused)
                .onSubmit {
                    viewModel.sendCurrentPrompt()
                }
                .accessibilityLabel("Prompt Input")

            if !viewModel.inputText.isEmpty {
                Button {
                    viewModel.inputText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear input text")
            }

            if viewModel.isStreaming {
                Button {
                    viewModel.stopGeneration()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Stop generating")
                .accessibilityLabel("Stop generating")
            } else {
                Button {
                    viewModel.sendCurrentPrompt()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(
                            viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color.secondary.opacity(0.35)
                                : Color.accentColor
                        )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Send prompt (Return)")
                .accessibilityLabel("Send prompt")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Chronological Conversation & Tool Stream Area

    private var conversationArea: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Subtle top drag handle indicator
                        HStack {
                            Spacer()
                            Capsule()
                                .fill(Color.primary.opacity(0.18))
                                .frame(width: 36, height: 4)
                                .padding(.top, 4)
                                .padding(.bottom, 6)
                            Spacer()
                        }

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
                                        viewModel.showSettings = true
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
                    .padding(.vertical, 14)
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
                return nil
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
            EmptyView()
        }
    }

    @ViewBuilder
    private func toolRecordBadge(_ record: ToolExecutionRecord) -> some View {
        let isExpanded = expandedToolIds.contains(record.id)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if isExpanded {
                    expandedToolIds.remove(record.id)
                } else {
                    expandedToolIds.insert(record.id)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: record.isError ? "xmark.octagon.fill" : "terminal.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(record.isError ? Color.orange : Color.accentColor)
                    Text(record.toolName)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    Text(record.arguments)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Text("\(record.durationMs)ms")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)

            if isExpanded {
                ScrollView {
                    Text(record.output)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(maxHeight: 140)
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Bottom Control & Model / Reasoning Effort Bar

    private var bottomControlBar: some View {
        HStack(spacing: 10) {
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
                            settings.currentModel = modelInfo.id
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
                                Text(level.capitalized)
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

            // Visual Separator before the Tools & Web group
            Divider()
                .frame(height: 13)
                .opacity(0.6)

            // Tools & Web grouped together without a separator between them (fixedSize so they never wrap vertically)
            HStack(spacing: 6) {
                Button {
                    settings.enableTools.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: settings.enableTools ? "hammer.fill" : "hammer")
                            .font(.system(size: 10.5))
                        Text("Tools")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .fixedSize()
                    .foregroundStyle(settings.enableTools ? Color.accentColor : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        (settings.enableTools ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05)),
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Toggle autonomous tools (Web Search, Terminal, File I/O)")

                Button {
                    settings.enableWebSearchTool.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.system(size: 10.5))
                        Text("Web")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .fixedSize()
                    .foregroundStyle(settings.enableWebSearchTool ? Color.blue : Color.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        (settings.enableWebSearchTool ? Color.blue.opacity(0.14) : Color.primary.opacity(0.05)),
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .fixedSize()
                .help("Toggle live web search")
            }
            .fixedSize()

            // Empty space in the bottom bar acts as a drag handle to move the window
            WindowDragHandle()
                .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 24)

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
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 11.5, weight: .medium))
                    if !conversationStore.sessions.isEmpty {
                        Text("\(conversationStore.sessions.count)")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                }
                .fixedSize()
                .foregroundStyle(viewModel.showHistory ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 6)
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
                viewModel.showSettings = true
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
                Text("Past Conversations")
                    .font(.system(size: 13.5, weight: .semibold))

                Text("(\(conversationStore.sessions.count))")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Spacer()

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
                TextField("Search past conversations…", text: $historySearchText)
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
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                viewModel.attachImage(from: url)
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
