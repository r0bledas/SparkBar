import Foundation
import Combine

@MainActor
public final class ChatViewModel: ObservableObject {
    public static let shared = ChatViewModel()

    @Published public var currentSessionId: UUID = UUID()
    @Published public var messages: [ChatMessage] = []
    @Published public var inputText: String = ""
    @Published public var isStreaming: Bool = false
    @Published public var activeToolStatus: String? = nil
    @Published public var errorMessage: String? = nil
    @Published public var showSettings: Bool = false
    @Published public var showHistory: Bool = false

    private let client = LLMStreamingClient()
    private var currentTask: Task<Void, Never>?

    public init() {}

    public func sendCurrentPrompt() {
        let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        inputText = ""
        sendPrompt(prompt)
    }

    public func sendPrompt(_ prompt: String) {
        currentTask?.cancel()
        errorMessage = nil
        showHistory = false

        let userMsg = ChatMessage(role: .user, content: prompt)
        messages.append(userMsg)
        persistCurrentSession()

        isStreaming = true
        PanelController.shared.syncPanelHeight(hasMessages: true)

        currentTask = Task { [weak self] in
            guard let self = self else { return }
            await self.runAgentLoop()
        }
    }

    public func stopGeneration() {
        currentTask?.cancel()
        currentTask = nil
        isStreaming = false
        activeToolStatus = nil
        persistCurrentSession()
    }

    /// Archives the current conversation into `ConversationStore` and starts a fresh empty chat (`⌘N` / `New Chat`).
    public func startNewConversation() {
        stopGeneration()
        persistCurrentSession()
        currentSessionId = UUID()
        messages.removeAll()
        errorMessage = nil
        showHistory = false
        ConversationStore.shared.activeSessionId = nil
        PanelController.shared.syncPanelHeight(hasMessages: false)
    }

    /// Backwards-compatible alias used by shortcuts/menus: archives current conversation and resets the bar.
    public func clearConversation() {
        startNewConversation()
    }

    /// Restores a saved conversation from `ConversationStore` so the user can review or continue it.
    public func loadSession(_ session: ConversationSession) {
        stopGeneration()
        persistCurrentSession()
        currentSessionId = session.id
        messages = session.messages
        errorMessage = nil
        showHistory = false
        ConversationStore.shared.activeSessionId = session.id
        PanelController.shared.syncPanelHeight(hasMessages: !messages.isEmpty)
    }

    public func toggleHistory() {
        showHistory.toggle()
        let shouldExpand = !messages.isEmpty || errorMessage != nil || activeToolStatus != nil || showHistory
        PanelController.shared.syncPanelHeight(hasMessages: shouldExpand)
    }

    public func persistCurrentSession() {
        let meaningfulMessages = messages.filter { msg in
            switch msg.role {
            case .user, .tool:
                return true
            case .assistant:
                return !msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !(msg.reasoningContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !(msg.toolCalls ?? []).isEmpty
            case .system:
                return false
            }
        }
        guard !meaningfulMessages.isEmpty else { return }
        let settings = SettingsStore.shared
        ConversationStore.shared.upsertSession(
            id: currentSessionId,
            messages: meaningfulMessages,
            provider: settings.selectedProvider.rawValue,
            model: settings.currentModel
        )
    }

    private func runAgentLoop() async {
        let settings = SettingsStore.shared
        let maxToolTurns = 6
        var turnCount = 0

        while turnCount < maxToolTurns {
            turnCount += 1
            if Task.isCancelled { break }

            let assistantPlaceholder = ChatMessage(role: .assistant, content: "")
            messages.append(assistantPlaceholder)
            let assistantIndex = messages.count - 1

            let historySnapshot = Array(messages.dropLast())
            let provider = settings.selectedProvider
            let model = settings.currentModel
            let baseURL = settings.currentBaseURL
            let apiKey = settings.apiKey(for: provider)
            let effort: String? = settings.effectiveReasoningEffortForAPI

            do {
                let result = try await client.streamTurn(
                    messages: historySnapshot,
                    provider: provider,
                    model: model,
                    baseURL: baseURL,
                    apiKey: apiKey,
                    systemPrompt: settings.effectiveSystemPrompt(),
                    temperature: settings.temperature,
                    reasoningEffort: effort,
                    enableServerSideSearch: settings.enableServerSideSearch
                ) { [weak self] partialContent, partialReasoning in
                    guard let self = self, assistantIndex < self.messages.count else { return }
                    self.messages[assistantIndex].content = partialContent
                    if !partialReasoning.isEmpty {
                        self.messages[assistantIndex].reasoningContent = partialReasoning
                    }
                }

                if Task.isCancelled { break }

                messages[assistantIndex].content = result.content
                if !result.reasoningContent.isEmpty {
                    messages[assistantIndex].reasoningContent = result.reasoningContent
                }
                persistCurrentSession()

                if !result.toolCalls.isEmpty {
                    messages[assistantIndex].toolCalls = result.toolCalls

                    for call in result.toolCalls {
                        if Task.isCancelled { break }
                        activeToolStatus = "Running \(call.name)..."
                        let record = await ToolExecutor.execute(call)

                        let toolResultMsg = ChatMessage(
                            role: .tool,
                            content: record.output,
                            toolCallId: call.id,
                            toolName: call.name,
                            toolRecords: [record]
                        )
                        messages.append(toolResultMsg)
                        persistCurrentSession()
                    }
                    activeToolStatus = nil
                    continue
                } else {
                    break
                }
            } catch is CancellationError {
                persistCurrentSession()
                break
            } catch {
                if assistantIndex < messages.count && messages[assistantIndex].content.isEmpty {
                    messages.remove(at: assistantIndex)
                }
                errorMessage = error.localizedDescription
                persistCurrentSession()
                break
            }
        }

        activeToolStatus = nil
        isStreaming = false
        persistCurrentSession()
    }
}
