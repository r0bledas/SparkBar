import XCTest
@testable import SparkBar

final class SparkBarTests: XCTestCase {
    func testOpenAISSEContentAndReasoningParsing() {
        var content = ""
        var reasoning = ""
        var toolCalls: [Int: (id: String, name: String, arguments: String)] = [:]
        var finishReason: String?

        let line1 = #"data: {"choices":[{"delta":{"reasoning_content":"Step 1... "},"finish_reason":null}]}"#
        let done1 = LLMStreamingClient.parseOpenAISSELine(
            line1,
            accumulatedContent: &content,
            accumulatedReasoning: &reasoning,
            toolCallsByIndex: &toolCalls,
            finishReason: &finishReason
        )
        XCTAssertFalse(done1)
        XCTAssertEqual(reasoning, "Step 1... ")

        let line2 = #"data: {"choices":[{"delta":{"content":"Hello world!"},"finish_reason":"stop"}]}"#
        let done2 = LLMStreamingClient.parseOpenAISSELine(
            line2,
            accumulatedContent: &content,
            accumulatedReasoning: &reasoning,
            toolCallsByIndex: &toolCalls,
            finishReason: &finishReason
        )
        XCTAssertFalse(done2)
        XCTAssertEqual(content, "Hello world!")
        XCTAssertEqual(finishReason, "stop")

        let done3 = LLMStreamingClient.parseOpenAISSELine(
            "data: [DONE]",
            accumulatedContent: &content,
            accumulatedReasoning: &reasoning,
            toolCallsByIndex: &toolCalls,
            finishReason: &finishReason
        )
        XCTAssertTrue(done3)
    }

    func testOpenAISSEToolCallStreamingParsing() {
        var content = ""
        var reasoning = ""
        var toolCalls: [Int: (id: String, name: String, arguments: String)] = [:]
        var finishReason: String?

        let chunk1 = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_abc123","type":"function","function":{"name":"web_search","arguments":"{\"qu"}}]},"finish_reason":null}]}"#
        let chunk2 = #"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ery\":\"SwiftUI NSPanel\"}"}}]},"finish_reason":"tool_calls"}]}"#

        _ = LLMStreamingClient.parseOpenAISSELine(
            chunk1,
            accumulatedContent: &content,
            accumulatedReasoning: &reasoning,
            toolCallsByIndex: &toolCalls,
            finishReason: &finishReason
        )
        _ = LLMStreamingClient.parseOpenAISSELine(
            chunk2,
            accumulatedContent: &content,
            accumulatedReasoning: &reasoning,
            toolCallsByIndex: &toolCalls,
            finishReason: &finishReason
        )

        XCTAssertEqual(finishReason, "tool_calls")
        XCTAssertEqual(toolCalls[0]?.id, "call_abc123")
        XCTAssertEqual(toolCalls[0]?.name, "web_search")
        XCTAssertEqual(toolCalls[0]?.arguments, #"{"query":"SwiftUI NSPanel"}"#)
    }

    func testMarkdownCodeBlockParser() {
        let md = """
        Here is some Swift code:

        ```swift
        let x = 42
        print(x)
        ```

        And a conclusion paragraph.
        """

        let blocks = MarkdownMessageView.parseBlocks(from: md)
        XCTAssertEqual(blocks.count, 3)

        if case .code(_, let lang, let code) = blocks[1] {
            XCTAssertEqual(lang, "swift")
            XCTAssertTrue(code.contains("let x = 42"))
        } else {
            XCTFail("Expected second block to be code")
        }
    }

    func testToolExecutorRunCommandAndFileIO() async {
        let tempPath = "/tmp/sparkbar_unit_test_\(UUID().uuidString).txt"
        let writeCall = ToolCallRequest(
            id: "call_1",
            name: "write_file",
            arguments: #"{"path":"\#(tempPath)","content":"SparkBar Test Content"}"#
        )
        let writeRecord = await ToolExecutor.execute(writeCall)
        XCTAssertFalse(writeRecord.isError)

        let readCall = ToolCallRequest(
            id: "call_2",
            name: "read_file",
            arguments: #"{"path":"\#(tempPath)"}"#
        )
        let readRecord = await ToolExecutor.execute(readCall)
        XCTAssertFalse(readRecord.isError)
        XCTAssertEqual(readRecord.output, "SparkBar Test Content")

        try? FileManager.default.removeItem(atPath: tempPath)

        let cmdCall = ToolCallRequest(
            id: "call_3",
            name: "run_command",
            arguments: #"{"command":"echo $((21 * 2))"}"#
        )
        let cmdRecord = await ToolExecutor.execute(cmdCall)
        XCTAssertFalse(cmdRecord.isError)
        XCTAssertEqual(cmdRecord.output.trimmingCharacters(in: .whitespacesAndNewlines), "42")
    }

    @MainActor
    func testLiveDeepSeekDynamicModelDiscoveryAndStreaming() async throws {
        _ = SettingsStore.shared // triggers bootstrap
        let key = KeychainHelper.loadKey(for: LLMProviderType.deepseek.rawValue)
        guard !key.isEmpty else { return }

        // 1. Dynamically discover models from GET /v1/models (Zero hardcoding)
        let models = try await LLMStreamingClient.fetchRemoteModels(
            baseURL: LLMProviderType.deepseek.defaultBaseURL,
            apiKey: key,
            provider: .deepseek
        )
        XCTAssertFalse(models.isEmpty, "Expected dynamic models from DeepSeek API")
        let firstModel = models[0]
        XCTAssertFalse(firstModel.id.isEmpty)
        XCTAssertFalse(firstModel.supportedEffortLevels.isEmpty)

        // 2. Stream a turn using the dynamically discovered model and reasoning effort
        let client = LLMStreamingClient()
        let userMsg = ChatMessage(role: .user, content: "Reply with the exact string SPARKBAR_OK and nothing else.")
        var streamed = ""

        let result = try await client.streamTurn(
            messages: [userMsg],
            provider: .deepseek,
            model: firstModel.id,
            baseURL: LLMProviderType.deepseek.defaultBaseURL,
            apiKey: key,
            systemPrompt: "You are a helpful assistant.",
            temperature: 0.0,
            reasoningEffort: firstModel.supportedEffortLevels.first ?? "low",
            enableServerSideSearch: false
        ) { partial, _ in
            streamed = partial
        }

        XCTAssertTrue(result.content.contains("SPARKBAR_OK"), "Got: \(result.content)")
        XCTAssertFalse(streamed.isEmpty)
    }
}
