import Foundation
import Network

/// Lightweight, zero-dependency local HTTP/1.1 API server (Beta) bound strictly to `127.0.0.1`.
/// Exposes OpenAI (`/v1/models`, `/v1/chat/completions`), Anthropic (`/v1/messages`),
/// and Ollama (`/api/tags`, `/api/version`, `/api/show`, `/api/chat`, `/api/generate`) endpoints
/// backed by SparkBar's currently configured LLM provider (including zero-API-key Google Antigravity AGY).
@MainActor
public final class LocalAPIServer: ObservableObject {
    public static let shared = LocalAPIServer()

    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var activePort: Int = 11435
    @Published public private(set) var lastError: String? = nil
    @Published public private(set) var totalRequestsServed: Int = 0

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.sparkbar.localapi", qos: .userInitiated)

    public init() {}

    public var baseURLString: String {
        "http://127.0.0.1:\(activePort)"
    }

    public func start(port: Int) {
        stop()

        guard port >= 1024 && port <= 65535, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            lastError = "Port must be between 1024 and 65535."
            isRunning = false
            return
        }

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)

            let newListener = try NWListener(using: params)
            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.activePort = Int(newListener.port?.rawValue ?? UInt16(port))
                        self.lastError = nil
                    case .failed(let err):
                        self.isRunning = false
                        self.lastError = err.localizedDescription
                        newListener.cancel()
                        if self.listener === newListener {
                            self.listener = nil
                        }
                    case .cancelled:
                        if self.listener === newListener {
                            self.isRunning = false
                            self.listener = nil
                        }
                    default:
                        break
                    }
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection: connection)
            }

            self.listener = newListener
            self.activePort = port
            self.lastError = nil
            newListener.start(queue: queue)
        } catch {
            self.isRunning = false
            self.lastError = error.localizedDescription
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Connection Handling

    private nonisolated func accept(connection: NWConnection) {
        connection.start(queue: queue)
        let buffer = ConnectionBuffer()
        receiveNext(on: connection, buffer: buffer)
    }

    private nonisolated func receiveNext(on connection: NWConnection, buffer: ConnectionBuffer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self = self else {
                connection.cancel()
                return
            }

            if let data = data, !data.isEmpty {
                buffer.data.append(data)
            }

            if buffer.data.count > 20 * 1024 * 1024 {
                self.sendJSONResponse(
                    on: connection,
                    statusCode: 413,
                    statusText: "Payload Too Large",
                    object: ["error": ["message": "Request body exceeds 20 MB limit."]]
                )
                return
            }

            switch Self.tryParseHTTPRequest(buffer.data) {
            case .complete(let request):
                Task { @MainActor in
                    self.totalRequestsServed += 1
                    await self.handleRequest(request, on: connection)
                }
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receiveNext(on: connection, buffer: buffer)
                }
            case .invalid(let reason):
                self.sendJSONResponse(
                    on: connection,
                    statusCode: 400,
                    statusText: "Bad Request",
                    object: ["error": ["message": reason]]
                )
            }
        }
    }

    // MARK: - HTTP/1.1 Parser

    public struct HTTPRequest: Sendable {
        public let method: String
        public let path: String
        public let headers: [String: String]
        public let body: Data
    }

    public enum HTTPParseResult: Sendable {
        case incomplete
        case complete(HTTPRequest)
        case invalid(String)
    }

    public nonisolated static func tryParseHTTPRequest(_ data: Data) -> HTTPParseResult {
        let delimiter = Data([0x0D, 0x0A, 0x0D, 0x0A]) // \r\n\r\n
        guard let headerRange = data.range(of: delimiter) else {
            return .incomplete
        }

        let headerData = data.subdata(in: data.startIndex..<headerRange.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return .invalid("Invalid UTF-8 in HTTP headers.")
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            return .invalid("Empty HTTP request line.")
        }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            return .invalid("Malformed HTTP request line.")
        }

        let method = String(parts[0]).uppercased()
        let rawTarget = String(parts[1])
        let path = rawTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawTarget

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIdx = line.firstIndex(of: ":") else { continue }
            let key = line[..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
            let val = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
            headers[key] = val
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        let availableBodyCount = data.count - bodyStart
        if availableBodyCount < contentLength {
            return .incomplete
        }

        let body: Data
        if contentLength > 0 {
            body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        } else {
            body = Data()
        }

        return .complete(HTTPRequest(method: method, path: path, headers: headers, body: body))
    }

    // MARK: - Router

    private func handleRequest(_ request: HTTPRequest, on connection: NWConnection) async {
        // Normalize trailing slash (keep "/" intact)
        var path = request.path
        if path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }

        if request.method == "OPTIONS" {
            sendEmptyResponse(on: connection, statusCode: 204, statusText: "No Content")
            return
        }

        switch (request.method, path) {
        case ("GET", "/"), ("GET", "/health"):
            let payload: [String: Any] = [
                "status": "ok",
                "service": "SparkBar Local API",
                "beta": true,
                "provider": SettingsStore.shared.selectedProvider.rawValue,
                "active_model": resolvedModelId(requested: nil),
                "endpoints": [
                    "openai": ["GET /v1/models", "POST /v1/chat/completions"],
                    "anthropic": ["POST /v1/messages"],
                    "ollama": ["GET /api/tags", "GET /api/version", "POST /api/chat", "POST /api/generate"]
                ]
            ]
            sendJSONResponse(on: connection, statusCode: 200, statusText: "OK", object: payload)

        // OpenAI-compatible
        case ("GET", "/v1/models"), ("GET", "/models"):
            sendJSONResponse(on: connection, statusCode: 200, statusText: "OK", object: buildOpenAIModelsPayload())

        case ("POST", "/v1/chat/completions"), ("POST", "/chat/completions"):
            await handleOpenAIChatCompletions(request, on: connection)

        // Anthropic-compatible
        case ("POST", "/v1/messages"), ("POST", "/messages"):
            await handleAnthropicMessages(request, on: connection)

        // Ollama-compatible
        case ("GET", "/api/tags"):
            sendJSONResponse(on: connection, statusCode: 200, statusText: "OK", object: buildOllamaTagsPayload())

        case ("GET", "/api/version"):
            sendJSONResponse(
                on: connection,
                statusCode: 200,
                statusText: "OK",
                object: ["version": "sparkbar-\(GitHubUpdater.shared.installedVersion)"]
            )

        case ("POST", "/api/show"):
            let json = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
            let reqModel = (json["name"] as? String) ?? (json["model"] as? String)
            let resolved = resolvedModelId(requested: reqModel)
            sendJSONResponse(
                on: connection,
                statusCode: 200,
                statusText: "OK",
                object: [
                    "modelfile": "# SparkBar Local API (Beta)\nFROM \(resolved)",
                    "parameters": "",
                    "template": "{{ .Prompt }}",
                    "details": [
                        "family": "sparkbar",
                        "format": "api",
                        "parameter_size": "cloud",
                        "quantization_level": "none"
                    ]
                ]
            )

        case ("POST", "/api/chat"):
            await handleOllamaChat(request, on: connection)

        case ("POST", "/api/generate"):
            await handleOllamaGenerate(request, on: connection)

        default:
            sendJSONResponse(
                on: connection,
                statusCode: 404,
                statusText: "Not Found",
                object: [
                    "error": [
                        "message": "Unsupported endpoint: \(request.method) \(request.path)",
                        "type": "invalid_request_error"
                    ]
                ]
            )
        }
    }

    // MARK: - Model List Builders

    public func exposedModelEntries() -> [(id: String, ownedBy: String)] {
        let settings = SettingsStore.shared
        var entries: [(id: String, ownedBy: String)] = []
        var seen: Set<String> = []

        for model in settings.availableModels {
            let owner = model.ownedBy ?? settings.selectedProvider.rawValue
            if seen.insert(model.id).inserted {
                entries.append((id: model.id, ownedBy: owner))
            }
            if let variants = model.effortVariantModelIds {
                for variantId in variants.values.sorted() where seen.insert(variantId).inserted {
                    entries.append((id: variantId, ownedBy: owner))
                }
            }
        }

        if entries.isEmpty {
            let fallback = settings.effectiveModelIdForExecution.isEmpty ? "sparkbar-default" : settings.effectiveModelIdForExecution
            entries.append((id: fallback, ownedBy: settings.selectedProvider.rawValue))
        }
        return entries
    }

    public func buildOpenAIModelsPayload() -> [String: Any] {
        let now = Int(Date().timeIntervalSince1970)
        let dataList: [[String: Any]] = exposedModelEntries().map { item in
            [
                "id": item.id,
                "object": "model",
                "created": now,
                "owned_by": item.ownedBy
            ]
        }
        return [
            "object": "list",
            "data": dataList
        ]
    }

    public func buildOllamaTagsPayload() -> [String: Any] {
        let iso = Self.iso8601Timestamp()
        let models: [[String: Any]] = exposedModelEntries().map { item in
            [
                "name": item.id,
                "model": item.id,
                "modified_at": iso,
                "size": 0,
                "digest": "sparkbar-\(item.ownedBy)",
                "details": [
                    "parent_model": "",
                    "format": "api",
                    "family": item.ownedBy,
                    "families": [item.ownedBy],
                    "parameter_size": "cloud",
                    "quantization_level": "none"
                ]
            ]
        }
        return ["models": models]
    }

    public func resolvedModelId(requested: String?) -> String {
        let settings = SettingsStore.shared
        let trimmed = (requested ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = settings.effectiveModelIdForExecution.isEmpty ? "sparkbar-default" : settings.effectiveModelIdForExecution

        if trimmed.isEmpty || trimmed.lowercased() == "default" || trimmed.lowercased() == "sparkbar" {
            return fallback
        }

        // Exact ID or effort-variant match
        for m in settings.availableModels {
            if m.id == trimmed {
                return m.id
            }
            if let variants = m.effortVariantModelIds, variants.values.contains(trimmed) {
                return trimmed
            }
            if m.displayLabel.caseInsensitiveCompare(trimmed) == .orderedSame {
                return m.id
            }
        }

        // For AGY or when availableModels is populated, fall back to SparkBar's active model
        // so generic clients configured with e.g. "gpt-4o" or "claude-3-5-sonnet" work seamlessly.
        if settings.selectedProvider == .antigravity || !settings.availableModels.isEmpty {
            return fallback
        }
        return trimmed
    }

    // MARK: - OpenAI /v1/chat/completions

    private func handleOpenAIChatCompletions(_ request: HTTPRequest, on connection: NWConnection) async {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            sendJSONResponse(
                on: connection,
                statusCode: 400,
                statusText: "Bad Request",
                object: ["error": ["message": "Invalid JSON body.", "type": "invalid_request_error"]]
            )
            return
        }

        let requestedModel = json["model"] as? String
        let modelId = resolvedModelId(requested: requestedModel)
        let stream = (json["stream"] as? Bool) ?? false
        let temperature = (json["temperature"] as? Double) ?? SettingsStore.shared.temperature
        let rawMessages = (json["messages"] as? [[String: Any]]) ?? []
        let (systemPrompt, chatMessages) = Self.extractOpenAIMessages(rawMessages)

        guard !chatMessages.isEmpty else {
            sendJSONResponse(
                on: connection,
                statusCode: 400,
                statusText: "Bad Request",
                object: ["error": ["message": "Field `messages` must contain at least one message.", "type": "invalid_request_error"]]
            )
            return
        }

        let completionId = "chatcmpl-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20))"
        let created = Int(Date().timeIntervalSince1970)

        if stream {
            sendStreamHeaders(on: connection, contentType: "text/event-stream; charset=utf-8")

            // Initial role chunk
            let roleChunk: [String: Any] = [
                "id": completionId,
                "object": "chat.completion.chunk",
                "created": created,
                "model": modelId,
                "choices": [[
                    "index": 0,
                    "delta": ["role": "assistant", "content": ""],
                    "finish_reason": NSNull()
                ]]
            ]
            sendSSEData(on: connection, object: roleChunk)

            do {
                _ = try await executeBackend(
                    systemPrompt: systemPrompt,
                    messages: chatMessages,
                    model: modelId,
                    temperature: temperature
                ) { delta in
                    let chunk: [String: Any] = [
                        "id": completionId,
                        "object": "chat.completion.chunk",
                        "created": created,
                        "model": modelId,
                        "choices": [[
                            "index": 0,
                            "delta": ["content": delta],
                            "finish_reason": NSNull()
                        ]]
                    ]
                    self.sendSSEData(on: connection, object: chunk)
                }

                let stopChunk: [String: Any] = [
                    "id": completionId,
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": modelId,
                    "choices": [[
                        "index": 0,
                        "delta": [:],
                        "finish_reason": "stop"
                    ]]
                ]
                sendSSEData(on: connection, object: stopChunk)
                sendRawAndClose(on: connection, string: "data: [DONE]\n\n")
            } catch {
                let errChunk: [String: Any] = [
                    "error": ["message": error.localizedDescription, "type": "server_error"]
                ]
                sendSSEData(on: connection, object: errChunk)
                sendRawAndClose(on: connection, string: "data: [DONE]\n\n")
            }
        } else {
            do {
                let fullText = try await executeBackend(
                    systemPrompt: systemPrompt,
                    messages: chatMessages,
                    model: modelId,
                    temperature: temperature,
                    onDelta: nil
                )
                let response: [String: Any] = [
                    "id": completionId,
                    "object": "chat.completion",
                    "created": created,
                    "model": modelId,
                    "choices": [[
                        "index": 0,
                        "message": [
                            "role": "assistant",
                            "content": fullText
                        ],
                        "finish_reason": "stop"
                    ]],
                    "usage": [
                        "prompt_tokens": 0,
                        "completion_tokens": max(1, fullText.count / 4),
                        "total_tokens": max(1, fullText.count / 4)
                    ]
                ]
                sendJSONResponse(on: connection, statusCode: 200, statusText: "OK", object: response)
            } catch {
                sendJSONResponse(
                    on: connection,
                    statusCode: 500,
                    statusText: "Internal Server Error",
                    object: ["error": ["message": error.localizedDescription, "type": "server_error"]]
                )
            }
        }
    }

    // MARK: - Anthropic /v1/messages

    private func handleAnthropicMessages(_ request: HTTPRequest, on connection: NWConnection) async {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            sendJSONResponse(
                on: connection,
                statusCode: 400,
                statusText: "Bad Request",
                object: ["type": "error", "error": ["type": "invalid_request_error", "message": "Invalid JSON body."]]
            )
            return
        }

        let requestedModel = json["model"] as? String
        let modelId = resolvedModelId(requested: requestedModel)
        let stream = (json["stream"] as? Bool) ?? false
        let temperature = (json["temperature"] as? Double) ?? SettingsStore.shared.temperature

        var systemPrompt = ""
        if let sysStr = json["system"] as? String {
            systemPrompt = sysStr
        } else if let sysBlocks = json["system"] as? [[String: Any]] {
            systemPrompt = sysBlocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }

        let rawMessages = (json["messages"] as? [[String: Any]]) ?? []
        let (_, chatMessages) = Self.extractOpenAIMessages(rawMessages)

        guard !chatMessages.isEmpty else {
            sendJSONResponse(
                on: connection,
                statusCode: 400,
                statusText: "Bad Request",
                object: ["type": "error", "error": ["type": "invalid_request_error", "message": "Field `messages` must not be empty."]]
            )
            return
        }

        let messageId = "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20))"

        if stream {
            sendStreamHeaders(on: connection, contentType: "text/event-stream; charset=utf-8")

            let messageStart: [String: Any] = [
                "type": "message_start",
                "message": [
                    "id": messageId,
                    "type": "message",
                    "role": "assistant",
                    "content": [],
                    "model": modelId,
                    "stop_reason": NSNull(),
                    "stop_sequence": NSNull(),
                    "usage": ["input_tokens": 0, "output_tokens": 1]
                ]
            ]
            sendAnthropicSSE(on: connection, event: "message_start", object: messageStart)

            let blockStart: [String: Any] = [
                "type": "content_block_start",
                "index": 0,
                "content_block": ["type": "text", "text": ""]
            ]
            sendAnthropicSSE(on: connection, event: "content_block_start", object: blockStart)

            do {
                let fullText = try await executeBackend(
                    systemPrompt: systemPrompt,
                    messages: chatMessages,
                    model: modelId,
                    temperature: temperature
                ) { delta in
                    let deltaObj: [String: Any] = [
                        "type": "content_block_delta",
                        "index": 0,
                        "delta": ["type": "text_delta", "text": delta]
                    ]
                    self.sendAnthropicSSE(on: connection, event: "content_block_delta", object: deltaObj)
                }

                sendAnthropicSSE(on: connection, event: "content_block_stop", object: ["type": "content_block_stop", "index": 0])
                sendAnthropicSSE(on: connection, event: "message_delta", object: [
                    "type": "message_delta",
                    "delta": ["stop_reason": "end_turn", "stop_sequence": NSNull()],
                    "usage": ["output_tokens": max(1, fullText.count / 4)]
                ])
                sendAnthropicSSE(on: connection, event: "message_stop", object: ["type": "message_stop"], closeAfter: true)
            } catch {
                sendAnthropicSSE(
                    on: connection,
                    event: "error",
                    object: ["type": "error", "error": ["type": "api_error", "message": error.localizedDescription]],
                    closeAfter: true
                )
            }
        } else {
            do {
                let fullText = try await executeBackend(
                    systemPrompt: systemPrompt,
                    messages: chatMessages,
                    model: modelId,
                    temperature: temperature,
                    onDelta: nil
                )
                let response: [String: Any] = [
                    "id": messageId,
                    "type": "message",
                    "role": "assistant",
                    "model": modelId,
                    "content": [["type": "text", "text": fullText]],
                    "stop_reason": "end_turn",
                    "stop_sequence": NSNull(),
                    "usage": [
                        "input_tokens": 0,
                        "output_tokens": max(1, fullText.count / 4)
                    ]
                ]
                sendJSONResponse(on: connection, statusCode: 200, statusText: "OK", object: response)
            } catch {
                sendJSONResponse(
                    on: connection,
                    statusCode: 500,
                    statusText: "Internal Server Error",
                    object: ["type": "error", "error": ["type": "api_error", "message": error.localizedDescription]]
                )
            }
        }
    }

    // MARK: - Ollama /api/chat & /api/generate

    private func handleOllamaChat(_ request: HTTPRequest, on connection: NWConnection) async {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            sendJSONResponse(on: connection, statusCode: 400, statusText: "Bad Request", object: ["error": "Invalid JSON body."])
            return
        }

        let modelId = resolvedModelId(requested: json["model"] as? String)
        let stream = (json["stream"] as? Bool) ?? true // Ollama defaults stream to true
        let options = json["options"] as? [String: Any]
        let temperature = (options?["temperature"] as? Double) ?? SettingsStore.shared.temperature
        let rawMessages = (json["messages"] as? [[String: Any]]) ?? []
        let (systemPrompt, chatMessages) = Self.extractOpenAIMessages(rawMessages)

        guard !chatMessages.isEmpty else {
            sendJSONResponse(on: connection, statusCode: 400, statusText: "Bad Request", object: ["error": "Field `messages` must not be empty."])
            return
        }

        if stream {
            sendStreamHeaders(on: connection, contentType: "application/x-ndjson; charset=utf-8")
            do {
                _ = try await executeBackend(
                    systemPrompt: systemPrompt,
                    messages: chatMessages,
                    model: modelId,
                    temperature: temperature
                ) { delta in
                    let line: [String: Any] = [
                        "model": modelId,
                        "created_at": Self.iso8601Timestamp(),
                        "message": ["role": "assistant", "content": delta],
                        "done": false
                    ]
                    self.sendNDJSONLine(on: connection, object: line)
                }
                let finalLine: [String: Any] = [
                    "model": modelId,
                    "created_at": Self.iso8601Timestamp(),
                    "message": ["role": "assistant", "content": ""],
                    "done": true,
                    "done_reason": "stop"
                ]
                sendNDJSONLine(on: connection, object: finalLine, closeAfter: true)
            } catch {
                sendNDJSONLine(on: connection, object: ["error": error.localizedDescription, "done": true], closeAfter: true)
            }
        } else {
            do {
                let fullText = try await executeBackend(
                    systemPrompt: systemPrompt,
                    messages: chatMessages,
                    model: modelId,
                    temperature: temperature,
                    onDelta: nil
                )
                let payload: [String: Any] = [
                    "model": modelId,
                    "created_at": Self.iso8601Timestamp(),
                    "message": ["role": "assistant", "content": fullText],
                    "done": true,
                    "done_reason": "stop"
                ]
                sendJSONResponse(on: connection, statusCode: 200, statusText: "OK", object: payload)
            } catch {
                sendJSONResponse(on: connection, statusCode: 500, statusText: "Internal Server Error", object: ["error": error.localizedDescription])
            }
        }
    }

    private func handleOllamaGenerate(_ request: HTTPRequest, on connection: NWConnection) async {
        guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            sendJSONResponse(on: connection, statusCode: 400, statusText: "Bad Request", object: ["error": "Invalid JSON body."])
            return
        }

        let modelId = resolvedModelId(requested: json["model"] as? String)
        let prompt = (json["prompt"] as? String) ?? ""
        let systemPrompt = (json["system"] as? String) ?? ""
        let stream = (json["stream"] as? Bool) ?? true // Ollama defaults stream to true
        let options = json["options"] as? [String: Any]
        let temperature = (options?["temperature"] as? Double) ?? SettingsStore.shared.temperature

        let chatMessages = [ChatMessage(role: .user, content: prompt)]

        if stream {
            sendStreamHeaders(on: connection, contentType: "application/x-ndjson; charset=utf-8")
            do {
                _ = try await executeBackend(
                    systemPrompt: systemPrompt,
                    messages: chatMessages,
                    model: modelId,
                    temperature: temperature
                ) { delta in
                    let line: [String: Any] = [
                        "model": modelId,
                        "created_at": Self.iso8601Timestamp(),
                        "response": delta,
                        "done": false
                    ]
                    self.sendNDJSONLine(on: connection, object: line)
                }
                let finalLine: [String: Any] = [
                    "model": modelId,
                    "created_at": Self.iso8601Timestamp(),
                    "response": "",
                    "done": true,
                    "done_reason": "stop"
                ]
                sendNDJSONLine(on: connection, object: finalLine, closeAfter: true)
            } catch {
                sendNDJSONLine(on: connection, object: ["error": error.localizedDescription, "done": true], closeAfter: true)
            }
        } else {
            do {
                let fullText = try await executeBackend(
                    systemPrompt: systemPrompt,
                    messages: chatMessages,
                    model: modelId,
                    temperature: temperature,
                    onDelta: nil
                )
                let payload: [String: Any] = [
                    "model": modelId,
                    "created_at": Self.iso8601Timestamp(),
                    "response": fullText,
                    "done": true,
                    "done_reason": "stop"
                ]
                sendJSONResponse(on: connection, statusCode: 200, statusText: "OK", object: payload)
            } catch {
                sendJSONResponse(on: connection, statusCode: 500, statusText: "Internal Server Error", object: ["error": error.localizedDescription])
            }
        }
    }

    // MARK: - Backend Execution

    private func executeBackend(
        systemPrompt: String,
        messages: [ChatMessage],
        model: String,
        temperature: Double,
        onDelta: (@Sendable (String) -> Void)?
    ) async throws -> String {
        let settings = SettingsStore.shared
        let provider = settings.selectedProvider

        if provider == .antigravity {
            let prompt = Self.formatMessagesForCLI(systemPrompt: systemPrompt, messages: messages)
            let state = AGYAccumulationBox()
            try await AGYCLIRunner.shared.streamTurn(
                prompt: prompt,
                model: model,
                conversationId: nil,
                allowTools: false,
                customBinaryPath: settings.agyCustomBinaryPath,
                portableRoot: settings.agyPortableRootPath,
                workingDirectory: nil
            ) { event in
                switch event {
                case .textDelta(_, let delta):
                    if !delta.isEmpty {
                        state.append(delta)
                        onDelta?(delta)
                    }
                case .finished(_, let finalResponse, _):
                    if let resp = finalResponse, !resp.isEmpty {
                        let missing = state.reconcileFinal(resp)
                        if !missing.isEmpty {
                            onDelta?(missing)
                        }
                    }
                default:
                    break
                }
            }
            return state.text
        } else {
            let client = LLMStreamingClient()
            var lastSentLength = 0
            let result = try await client.streamTurn(
                messages: messages,
                provider: provider,
                model: model,
                baseURL: settings.currentBaseURL,
                apiKey: settings.apiKey(for: provider),
                systemPrompt: systemPrompt,
                temperature: temperature,
                reasoningEffort: settings.effectiveReasoningEffortForAPI,
                enableServerSideSearch: false,
                includeTools: false
            ) { partial, _ in
                if partial.count > lastSentLength {
                    let startIdx = partial.index(partial.startIndex, offsetBy: lastSentLength)
                    let delta = String(partial[startIdx...])
                    lastSentLength = partial.count
                    if !delta.isEmpty {
                        onDelta?(delta)
                    }
                }
            }
            return result.content
        }
    }

    // MARK: - Message Parsing Helpers

    public nonisolated static func extractOpenAIMessages(_ rawMessages: [[String: Any]]) -> (system: String, messages: [ChatMessage]) {
        var systemParts: [String] = []
        var chatMessages: [ChatMessage] = []

        for item in rawMessages {
            let roleStr = ((item["role"] as? String) ?? "user").lowercased()
            let text: String
            if let str = item["content"] as? String {
                text = str
            } else if let blocks = item["content"] as? [[String: Any]] {
                text = blocks.compactMap { block -> String? in
                    if let t = block["text"] as? String { return t }
                    return nil
                }.joined(separator: "\n")
            } else {
                text = ""
            }

            switch roleStr {
            case "system", "developer":
                if !text.isEmpty { systemParts.append(text) }
            case "assistant":
                chatMessages.append(ChatMessage(role: .assistant, content: text))
            default:
                chatMessages.append(ChatMessage(role: .user, content: text))
            }
        }

        return (systemParts.joined(separator: "\n\n"), chatMessages)
    }

    public nonisolated static func formatMessagesForCLI(systemPrompt: String, messages: [ChatMessage]) -> String {
        if systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           messages.count == 1,
           messages[0].role == .user {
            return messages[0].content
        }

        var sections: [String] = []
        let trimmedSystem = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSystem.isEmpty {
            sections.append("System instructions:\n\(trimmedSystem)")
        }

        for msg in messages {
            let label = (msg.role == .assistant) ? "Assistant" : "User"
            sections.append("\(label):\n\(msg.content)")
        }
        return sections.joined(separator: "\n\n")
    }

    // MARK: - HTTP Wire Helpers

    private nonisolated static func iso8601Timestamp() -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.string(from: Date())
    }

    private nonisolated func corsHeaders() -> String {
        "Access-Control-Allow-Origin: *\r\n" +
        "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" +
        "Access-Control-Allow-Headers: Content-Type, Authorization, x-api-key, anthropic-version\r\n"
    }

    private nonisolated func sendEmptyResponse(on connection: NWConnection, statusCode: Int, statusText: String) {
        let raw = "HTTP/1.1 \(statusCode) \(statusText)\r\n" +
            corsHeaders() +
            "Content-Length: 0\r\n" +
            "Connection: close\r\n\r\n"
        sendRawAndClose(on: connection, string: raw)
    }

    private nonisolated func sendJSONResponse(on connection: NWConnection, statusCode: Int, statusText: String, object: Any) {
        let bodyData = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
        let header = "HTTP/1.1 \(statusCode) \(statusText)\r\n" +
            corsHeaders() +
            "Content-Type: application/json; charset=utf-8\r\n" +
            "Content-Length: \(bodyData.count)\r\n" +
            "Connection: close\r\n\r\n"
        var packet = Data(header.utf8)
        packet.append(bodyData)
        connection.send(content: packet, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private nonisolated func sendStreamHeaders(on connection: NWConnection, contentType: String) {
        let header = "HTTP/1.1 200 OK\r\n" +
            corsHeaders() +
            "Content-Type: \(contentType)\r\n" +
            "Cache-Control: no-cache\r\n" +
            "Connection: close\r\n\r\n"
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
    }

    private nonisolated func sendSSEData(on connection: NWConnection, object: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let jsonStr = String(data: data, encoding: .utf8) else { return }
        let frame = "data: \(jsonStr)\n\n"
        connection.send(content: Data(frame.utf8), completion: .contentProcessed { _ in })
    }

    private nonisolated func sendAnthropicSSE(on connection: NWConnection, event: String, object: Any, closeAfter: Bool = false) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let jsonStr = String(data: data, encoding: .utf8) else {
            if closeAfter { connection.cancel() }
            return
        }
        let frame = "event: \(event)\ndata: \(jsonStr)\n\n"
        if closeAfter {
            sendRawAndClose(on: connection, string: frame)
        } else {
            connection.send(content: Data(frame.utf8), completion: .contentProcessed { _ in })
        }
    }

    private nonisolated func sendNDJSONLine(on connection: NWConnection, object: Any, closeAfter: Bool = false) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let jsonStr = String(data: data, encoding: .utf8) else {
            if closeAfter { connection.cancel() }
            return
        }
        let line = "\(jsonStr)\n"
        if closeAfter {
            sendRawAndClose(on: connection, string: line)
        } else {
            connection.send(content: Data(line.utf8), completion: .contentProcessed { _ in })
        }
    }

    private nonisolated func sendRawAndClose(on connection: NWConnection, string: String) {
        connection.send(content: Data(string.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private final class ConnectionBuffer: @unchecked Sendable {
    var data = Data()
}

private final class AGYAccumulationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulated = ""

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return accumulated
    }

    func append(_ delta: String) {
        lock.lock()
        accumulated += delta
        lock.unlock()
    }

    func reconcileFinal(_ finalResponse: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if accumulated.isEmpty {
            accumulated = finalResponse
            return finalResponse
        }
        if finalResponse.hasPrefix(accumulated) && finalResponse.count > accumulated.count {
            let suffix = String(finalResponse.dropFirst(accumulated.count))
            accumulated = finalResponse
            return suffix
        }
        return ""
    }
}
