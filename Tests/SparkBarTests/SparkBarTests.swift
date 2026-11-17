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

    func testMarkdownAndASCIITableParsing() {
        let md = """
        Here is a Markdown table:

        | Model | Speed |
        | --- | --- |
        | DeepSeek-V4.1-Flash | Fast |
        | DeepSeek-V4-Pro | Deep |

        And an ASCII box table:

        +-------+-------+
        | Col A | Col B |
        +-------+-------+
        | 100   | 200   |
        +-------+-------+
        """

        let blocks = MarkdownMessageView.parseBlocks(from: md)
        let hasTable = blocks.contains { block in
            if case .table(_, let headers, let rows, _) = block {
                return headers == ["Model", "Speed"] && rows.count == 2
            }
            return false
        }
        let hasASCII = blocks.contains { block in
            if case .asciiArt(_, let content) = block {
                return content.contains("+-------+-------+")
            }
            return false
        }
        XCTAssertTrue(hasTable, "Expected Markdown pipe table to be parsed")
        XCTAssertTrue(hasASCII, "Expected ASCII box table to be parsed")
    }

    func testLaTeXAndMarkdownRichBlocks() {
        let md = """
        # Heading One
        ---
        > Quoted insight
        $$
        \\frac{\\alpha + \\beta}{\\sqrt{x^2 + 1}} \\leq \\infty
        $$
        Inline math $E = mc^2$ and $\\pi \\approx 3.14$.
        """

        let blocks = MarkdownMessageView.parseBlocks(from: md)
        let hasHeading = blocks.contains { if case .heading(_, 1, "Heading One") = $0 { return true }; return false }
        let hasRule = blocks.contains { if case .horizontalRule = $0 { return true }; return false }
        let hasQuote = blocks.contains { if case .blockquote(_, let q) = $0 { return q.contains("Quoted") }; return false }
        let hasMath = blocks.contains { if case .mathBlock = $0 { return true }; return false }

        XCTAssertTrue(hasHeading)
        XCTAssertTrue(hasRule)
        XCTAssertTrue(hasQuote)
        XCTAssertTrue(hasMath)

        let converted = MarkdownMessageView.convertInlineLaTeXInText("Formula: $E = mc^2$ and $\\alpha_1 \\neq \\beta_2$")
        XCTAssertTrue(converted.contains("²"))
        XCTAssertTrue(converted.contains("α₁"))
        XCTAssertTrue(converted.contains("≠"))
    }

    @MainActor
    func testWebSearchToolReturnsRealResults() async {
        let call = ToolCallRequest(
            id: "call_web_1",
            name: "web_search",
            arguments: #"{"query":"Apple Inc latest news"}"#
        )
        let record = await ToolExecutor.execute(call)
        XCTAssertFalse(record.isError, "Expected web_search to succeed, got: \(record.output)")
        XCTAssertFalse(record.output.contains("No web search results found"), "Got empty search results: \(record.output)")
        XCTAssertTrue(record.output.contains("URL:"), "Expected structured URLs in web_search output, got: \(record.output)")
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
    func testEnvironmentManifestAndPersistentShellAndPDF() async {
        // 1. Verify Environment Manifest captures login PATH & Homebrew
        let manifest = EnvironmentProbe.shared.currentManifest()
        XCTAssertTrue(manifest.capturedPath.contains("/opt/homebrew/bin") || manifest.capturedPath.contains("/usr/local/bin"))
        let promptSummary = manifest.toSystemPromptSummary(
            sessionWorkspace: JobManager.shared.workspaceDirectory,
            currentCwd: JobManager.shared.currentWorkingDirectory
        )
        XCTAssertTrue(promptSummary.contains("Host Environment Manifest"))

        // 2. Verify persistent working directory across run_command calls
        let ws = JobManager.shared.workspaceDirectory
        _ = await ToolExecutor.execute(ToolCallRequest(
            id: "call_cd",
            name: "run_command",
            arguments: #"{"command":"cd '\#(ws)'"}"#
        ))
        let pwdRec = await ToolExecutor.execute(ToolCallRequest(
            id: "call_pwd",
            name: "run_command",
            arguments: #"{"command":"pwd"}"#
        ))
        XCTAssertFalse(pwdRec.isError)
        XCTAssertEqual(pwdRec.output.trimmingCharacters(in: .whitespacesAndNewlines), ws)

        // 3. Verify 1-call render_pdf + PDFKit verification
        let pdfOut = (ws as NSString).appendingPathComponent("test_render.pdf")
        let pdfRec = await ToolExecutor.execute(ToolCallRequest(
            id: "call_pdf",
            name: "render_pdf",
            arguments: #"{"output_path":"\#(pdfOut)","html":"<h1>SparkBar PDF Test</h1><p>Generated in 1 call via WebKit + PDFKit.</p>"}"#
        ))
        XCTAssertFalse(pdfRec.isError, "PDF render failed: \(pdfRec.output)")
        XCTAssertTrue(pdfRec.output.contains("valid_pdf: true"))
        XCTAssertTrue(pdfRec.output.contains("page_count: 1"))
        try? FileManager.default.removeItem(atPath: pdfOut)
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

    @MainActor
    func testConversationStorePersistenceAndLogs() {
        let store = ConversationStore.shared
        let testId = UUID()
        let msgs = [
            ChatMessage(role: .user, content: "Test conversation persistence in SparkBar"),
            ChatMessage(role: .assistant, content: "Persisted and logged to Markdown.")
        ]

        store.upsertSession(id: testId, messages: msgs, provider: "deepseek", model: "deepseek-chat")
        XCTAssertTrue(store.sessions.contains(where: { $0.id == testId }))

        if let saved = store.sessions.first(where: { $0.id == testId }) {
            XCTAssertEqual(saved.title, "Test conversation persistence in SparkBar")
            XCTAssertEqual(saved.messages.count, 2)
        }

        store.deleteSession(id: testId)
        XCTAssertFalse(store.sessions.contains(where: { $0.id == testId }))
    }
}
