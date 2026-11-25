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

    @MainActor
    func testImageSupportAndVisionOCRAndMarkdownImageParsing() {
        // 1. Verify AttachedImage serialization
        let img = AttachedImage(base64Data: "aGVsbG8=", mimeType: "image/png", fileName: "test.png")
        let msg = ChatMessage(role: .user, content: "Look at this", attachedImages: [img])
        let data = try! JSONEncoder().encode(msg)
        let decoded = try! JSONDecoder().decode(ChatMessage.self, from: data)
        XCTAssertEqual(decoded.attachedImages.count, 1)
        XCTAssertEqual(decoded.attachedImages.first?.fileName, "test.png")

        // 2. Verify Markdown image syntax parsing
        let md = "Here is an image:\n\n![SparkBar Icon](https://example.com/icon.png)\n\nNice!"
        let blocks = MarkdownMessageView.parseBlocks(from: md)
        XCTAssertTrue(blocks.contains(where: { block in
            if case .image(_, let alt, let url) = block {
                return alt == "SparkBar Icon" && url == "https://example.com/icon.png"
            }
            return false
        }))

        // 3. Verify Vision OCR execution on synthetic bitmap
        let size = CGSize(width: 240, height: 60)
        let nsImg = NSImage(size: size)
        nsImg.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let text = "VISION_OCR_TEST" as NSString
        text.draw(at: NSPoint(x: 10, y: 15), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 22), .foregroundColor: NSColor.black])
        nsImg.unlockFocus()
        if let cg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let ocr = VisionOCRHelper.recognizeText(from: cg)
            XCTAssertTrue(ocr.contains("VISION") || ocr.contains("OCR"), "OCR got: \(ocr)")
        }

        // 4. Verify ChatViewModel attach and remove
        let vm = ChatViewModel.shared
        vm.attachImage(data: "fake_png_data".data(using: .utf8)!, mimeType: "image/png", fileName: "unit_test.png")
        XCTAssertEqual(vm.attachedImages.last?.fileName, "unit_test.png")
        let idToRemove = vm.attachedImages.last!.id
        vm.removeAttachedImage(id: idToRemove)
        XCTAssertFalse(vm.attachedImages.contains(where: { $0.id == idToRemove }))
    }

    func testAGYCLIRunnerParsingAndLiveDiscovery() async throws {
        // 1. Verify `agy models` parser groups same base model + (<Variant>) into clean models with effort/variant mapping
        let sampleModels = """
        \r⠋ Fetching available models...\r⠙ Fetching available models...\rgemini-4-neon-high              Gemini 4 Neon (High)
        gemini-4-neon-xhigh             Gemini 4 Neon (XHigh)
        gemini-4-neon-medium            Gemini 4 Neon (Medium)
        gemini-4-neon-low               Gemini 4 Neon (Low)
        gemini-pro-orchestrator-neon    Orchestrator (Neon)
        gemini-pro-orchestrator-g1-pro  Orchestrator (Argon)
        claude-sonnet-5-5-medium        Claude Sonnet 5.5 (Medium)
        gpt-oss-120b-medium             GPT-OSS 120B (Medium)
        """
        let parsedModels = AGYCLIRunner.parseModelsOutput(sampleModels)
        XCTAssertEqual(parsedModels.count, 4)

        let neon = parsedModels[0]
        XCTAssertEqual(neon.displayLabel, "Gemini 4 Neon")
        XCTAssertEqual(neon.supportedEffortLevels, ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(neon.defaultEffortLevel, "medium")
        XCTAssertEqual(neon.resolvedModelId(forEffort: "xhigh"), "gemini-4-neon-xhigh")
        XCTAssertEqual(neon.resolvedModelId(forEffort: "low"), "gemini-4-neon-low")
        XCTAssertEqual(neon.resolvedModelId(forEffort: "default"), "gemini-4-neon-medium")

        let orch = parsedModels[1]
        XCTAssertEqual(orch.displayLabel, "Orchestrator")
        XCTAssertEqual(orch.supportedEffortLevels, ["neon", "argon"])
        XCTAssertEqual(orch.resolvedModelId(forEffort: "argon"), "gemini-pro-orchestrator-g1-pro")
        XCTAssertEqual(orch.resolvedModelId(forEffort: "neon"), "gemini-pro-orchestrator-neon")

        XCTAssertEqual(parsedModels[2].displayLabel, "Claude Sonnet 5.5")
        XCTAssertEqual(parsedModels[3].displayLabel, "GPT-OSS 120B")

        // 2. Verify NDJSON stream parser for init, text_delta, tool ACTIVE/DONE, and result
        let initLine = #"{"event":"init","conversation_id":"conv-123"}"#
        if case .initialized(let convId) = AGYCLIRunner.parseNDJSONLine(initLine) {
            XCTAssertEqual(convId, "conv-123")
        } else {
            XCTFail("Failed to parse init event")
        }

        let deltaLine = #"{"event":"step_update","step_update":{"step_index":1,"state":"ACTIVE","step_type":"agent_response","text_delta":"Hello!"}}"#
        if case .textDelta(let idx, let delta) = AGYCLIRunner.parseNDJSONLine(deltaLine) {
            XCTAssertEqual(idx, 1)
            XCTAssertEqual(delta, "Hello!")
        } else {
            XCTFail("Failed to parse text_delta event")
        }

        let toolDoneLine = #"{"event":"step_update","step_update":{"step_index":2,"state":"DONE","step_type":"tool","tool_name":"run_command","duration_seconds":0.08,"tool_info":{"name":"run_command","parameters":{"CommandLine":"echo hi"},"output":"hi\n"}}}"#
        if case .toolCompleted(let idx, let record) = AGYCLIRunner.parseNDJSONLine(toolDoneLine) {
            XCTAssertEqual(idx, 2)
            XCTAssertEqual(record.toolName, "run_command")
            XCTAssertEqual(record.durationMs, 80)
            XCTAssertTrue(record.arguments.contains("echo hi"))
            XCTAssertEqual(record.output, "hi\n")
        } else {
            XCTFail("Failed to parse tool DONE event")
        }

        // 3. Verify live `agy models` discovery if binary is present in sandbox
        if AGYCLIRunner.resolveBinaryPath() != nil {
            let liveModels = try await AGYCLIRunner.fetchAvailableModels()
            XCTAssertFalse(liveModels.isEmpty, "Expected live agy models list to be non-empty")
        }
    }

    @MainActor
    func testLocalAPIServerParsingAndLiveEndpoints() async throws {
        // 1. Verify HTTP/1.1 parser handles GET, incomplete body, and complete POST JSON
        let rawGet = Data("GET /v1/models?foo=bar HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
        if case .complete(let req) = LocalAPIServer.tryParseHTTPRequest(rawGet) {
            XCTAssertEqual(req.method, "GET")
            XCTAssertEqual(req.path, "/v1/models")
            XCTAssertTrue(req.body.isEmpty)
        } else {
            XCTFail("Expected complete GET request")
        }

        let partialPost = Data("POST /v1/chat/completions HTTP/1.1\r\nContent-Length: 20\r\n\r\n{\"a\":1}".utf8)
        if case .incomplete = LocalAPIServer.tryParseHTTPRequest(partialPost) {
            // expected
        } else {
            XCTFail("Expected incomplete POST request when body is shorter than Content-Length")
        }

        // 2. Verify message extraction (system + string + block arrays)
        let rawMsgs: [[String: Any]] = [
            ["role": "system", "content": "Be concise."],
            ["role": "user", "content": [["type": "text", "text": "Hello"], ["type": "text", "text": "World"]]]
        ]
        let extracted = LocalAPIServer.extractOpenAIMessages(rawMsgs)
        XCTAssertEqual(extracted.system, "Be concise.")
        XCTAssertEqual(extracted.messages.count, 1)
        XCTAssertEqual(extracted.messages[0].content, "Hello\nWorld")

        // 3. Start a live loopback server on a test port and verify OpenAI, Anthropic, and Ollama routes
        let server = LocalAPIServer()
        let testPort = 19435
        server.start(port: testPort)
        defer { server.stop() }

        // Wait briefly for NWListener to become ready
        for _ in 0..<25 {
            if server.isRunning { break }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        XCTAssertTrue(server.isRunning, "LocalAPIServer failed to start: \(server.lastError ?? "unknown")")

        // GET /health
        let (healthData, healthResp) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(testPort)/health")!)
        XCTAssertEqual((healthResp as? HTTPURLResponse)?.statusCode, 200)
        let healthJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: healthData) as? [String: Any])
        XCTAssertEqual(healthJSON["status"] as? String, "ok")
        XCTAssertEqual(healthJSON["beta"] as? Bool, true)

        // GET /v1/models (OpenAI)
        let (modelsData, modelsResp) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(testPort)/v1/models")!)
        XCTAssertEqual((modelsResp as? HTTPURLResponse)?.statusCode, 200)
        let modelsJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: modelsData) as? [String: Any])
        XCTAssertEqual(modelsJSON["object"] as? String, "list")
        let modelList = try XCTUnwrap(modelsJSON["data"] as? [[String: Any]])
        XCTAssertFalse(modelList.isEmpty)

        // GET /api/tags (Ollama)
        let (tagsData, tagsResp) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(testPort)/api/tags")!)
        XCTAssertEqual((tagsResp as? HTTPURLResponse)?.statusCode, 200)
        let tagsJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: tagsData) as? [String: Any])
        let ollamaModels = try XCTUnwrap(tagsJSON["models"] as? [[String: Any]])
        XCTAssertFalse(ollamaModels.isEmpty)

        // POST /v1/messages invalid JSON (Anthropic error envelope)
        var badAnthropicReq = URLRequest(url: URL(string: "http://127.0.0.1:\(testPort)/v1/messages")!)
        badAnthropicReq.httpMethod = "POST"
        badAnthropicReq.httpBody = Data("not-json".utf8)
        let (errData, errResp) = try await URLSession.shared.data(for: badAnthropicReq)
        XCTAssertEqual((errResp as? HTTPURLResponse)?.statusCode, 400)
        let errJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: errData) as? [String: Any])
        XCTAssertEqual(errJSON["type"] as? String, "error")
    }
}
