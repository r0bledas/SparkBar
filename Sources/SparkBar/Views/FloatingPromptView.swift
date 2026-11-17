import SwiftUI
import AppKit

public struct FloatingPromptView: View {
    @ObservedObject private var viewModel = ChatViewModel.shared
    @ObservedObject private var settings = SettingsStore.shared
    @FocusState private var isInputFocused: Bool
    @State private var expandedToolIds: Set<UUID> = []
    @State private var expandedReasoningIds: Set<UUID> = []
    @State private var copiedMessageId: UUID? = nil

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Top Spotlight Search / Prompt Input Bar
            promptInputBar

            // Conversation / Streaming Area (Expands smoothly when messages or errors exist)
            if !viewModel.messages.isEmpty || viewModel.errorMessage != nil {
                Divider()
                    .opacity(0.45)

                conversationArea
            }

            Divider()
                .opacity(0.45)

            // Bottom Compact Status & Control Bar
            bottomControlBar
        }
        .background(
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow, state: .active)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
        )
        .padding(8)
        .frame(width: 680)
        .frame(minHeight: viewModel.messages.isEmpty && viewModel.errorMessage == nil ? 120 : 440,
               maxHeight: 540)
        .sheet(isPresented: $viewModel.showSettings) {
            SettingsSheetView()
        }
        .onAppear {
            isInputFocused = true
        }
        .onReceive(PanelController.shared.focusTrigger) { _ in
            isInputFocused = true
        }
    }

    // MARK: - Top Prompt Input Bar

    private var promptInputBar: some View {
        HStack(spacing: 12) {
            Image(systemName: viewModel.isStreaming ? "sparkles" : "bolt.horizontal.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(viewModel.isStreaming ? Color.orange : Color.accentColor)
                .symbolEffect(.pulse, isActive: viewModel.isStreaming)
                .frame(width: 24, height: 24)

            TextField("Ask anything or run a task… (⌥Space)", text: $viewModel.inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .regular))
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
        .padding(.vertical, 15)
    }

    // MARK: - Conversation Stream Area

    private var conversationArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(visibleMessages) { msg in
                        messageRow(for: msg)
                            .id(msg.id)
                    }

                    if let toolStatus = viewModel.activeToolStatus {
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
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
            .onChange(of: viewModel.messages.last?.content) { _, _ in
                if let lastId = visibleMessages.last?.id {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                if let lastId = visibleMessages.last?.id {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(lastId, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var visibleMessages: [ChatMessage] {
        viewModel.messages.filter { $0.role == .user || $0.role == .assistant }
    }

    @ViewBuilder
    private func messageRow(for message: ChatMessage) -> some View {
        if message.role == .user {
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
        } else {
            VStack(alignment: .leading, spacing: 8) {
                // Reasoning chain (e.g. DeepSeek-R1)
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

                // Executed Tool Call Badges (Hermes / OpenCode agent visibility)
                if !message.toolRecords.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(message.toolRecords) { record in
                            toolRecordBadge(record)
                        }
                    }
                }

                // Assistant Markdown Response
                if !message.content.isEmpty {
                    MarkdownMessageView(text: message.content)

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
                    .padding(.top, 2)
                } else if viewModel.isStreaming && message.toolRecords.isEmpty {
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
                    Image(systemName: record.isError ? "xmark.octagon.fill" : "wrench.and.screwdriver.fill")
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
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
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
                .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    // MARK: - Bottom Control & Provider Bar

    private var bottomControlBar: some View {
        HStack(spacing: 12) {
            // Provider Quick Menu
            Menu {
                Section("AI Provider") {
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
                }
                Section("Suggested Models (\(settings.selectedProvider.displayName))") {
                    ForEach(settings.selectedProvider.suggestedModels, id: \.self) { preset in
                        Button {
                            settings.currentModel = preset
                        } label: {
                            HStack {
                                Text(preset)
                                if settings.currentModel == preset {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Circle()
                        .fill(hasValidKeyForCurrentProvider ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text("\(settings.selectedProvider.displayName) · \(settings.currentModel)")
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Select AI Provider & Model")

            // Tools Quick Toggle
            Button {
                settings.enableTools.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: settings.enableTools ? "hammer.fill" : "hammer")
                        .font(.system(size: 11))
                    Text(settings.enableTools ? "Tools On" : "Tools Off")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(settings.enableTools ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    (settings.enableTools ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05)),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
            .help("Toggle autonomous tools (Web Search, Terminal, File I/O)")

            // Web Search Quick Toggle
            Button {
                settings.enableWebSearchTool.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                        .font(.system(size: 11))
                    Text("Web")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(settings.enableWebSearchTool ? Color.blue : Color.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    (settings.enableWebSearchTool ? Color.blue.opacity(0.14) : Color.primary.opacity(0.05)),
                    in: Capsule()
                )
            }
            .buttonStyle(.plain)
            .help("Toggle live web search")

            Spacer()

            if !viewModel.messages.isEmpty {
                Button {
                    viewModel.clearConversation()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                        Text("Clear")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("k", modifiers: [.command])
                .help("Clear conversation (⌘K)")
            }

            Button {
                viewModel.showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: [.command])
            .help("Settings & API Keys (⌘,)")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private var hasValidKeyForCurrentProvider: Bool {
        if !settings.selectedProvider.requiresAPIKey { return true }
        return !settings.apiKey(for: settings.selectedProvider).isEmpty
    }
}
