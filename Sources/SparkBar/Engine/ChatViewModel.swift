import Foundation
import Combine

@MainActor
public final class ChatViewModel: ObservableObject {
    public static let shared = ChatViewModel()

    @Published public var messages: [ChatMessage] = []
    @Published public var inputText: String = ""
    @Published public var isStreaming: Bool = false
    @Published public var activeToolStatus: String? = nil
    @Published public var errorMessage: String? = nil
    @Published public var showSettings: Bool = false

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

        let userMsg = ChatMessage(role: .user, content: prompt)
        messages.append(userMsg)
        isStreaming = true

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
    }

    public func clearConversation() {
        stopGeneration()
        messages.removeAll()
        errorMessage = nil
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
            let effort: String? = settings.supportedEffortLevelsForCurrentModel.isEmpty ? nil : settings.reasoningEffort

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

                if !result.toolCalls.isEmpty {
                    messages[assistantIndex].toolCalls = result.toolCalls

                    for call in result.toolCalls {
                        if Task.isCancelled { break }
                        activeToolStatus = "Running \(call.name)..."
                        let record = await ToolExecutor.execute(call)
                        messages[assistantIndex].toolRecords.append(record)

                        let toolResultMsg = ChatMessage(
                            role: .tool,
                            content: record.output,
                            toolCallId: call.id,
                            toolName: call.name
                        )
                        messages.append(toolResultMsg)
                    }
                    activeToolStatus = nil
                    continue
                } else {
                    break
                }
            } catch is CancellationError {
                break
            } catch {
                if assistantIndex < messages.count && messages[assistantIndex].content.isEmpty {
                    messages.remove(at: assistantIndex)
                }
                errorMessage = error.localizedDescription
                break
            }
        }

        activeToolStatus = nil
        isStreaming = false
    }
}
