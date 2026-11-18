import Foundation

public struct StreamDeltaResult {
    public var content: String = ""
    public var reasoningContent: String = ""
    public var toolCalls: [ToolCallRequest] = []
    public var finishReason: String?
}

public enum LLMClientError: LocalizedError {
    case missingAPIKey(String)
    case invalidEndpoint(String)
    case httpError(Int, String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let provider):
            return "Missing API key for \(provider). Open Settings (⌘,) to add your API key."
        case .invalidEndpoint(let url):
            return "Invalid API endpoint URL: \(url)"
        case .httpError(let status, let body):
            return "API Error (HTTP \(status)): \(body)"
        case .emptyResponse:
            return "Received an empty response from the server."
        }
    }
}

public final class LLMStreamingClient {
    public init() {}

    /// Dynamically fetches the model list from `GET /models` (or `/v1/models`) and parses API ID, Name, Context Window, and Reasoning Effort levels.
    public static func fetchRemoteModels(
        baseURL: String,
        apiKey: String,
        provider: LLMProviderType
    ) async throws -> [RemoteModelInfo] {
        if provider.requiresAPIKey && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return []
        }

        let normalizedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let modelsURLString = normalizedBase.hasSuffix("/models")
            ? normalizedBase
            : "\(normalizedBase)/models"

        guard let url = URL(string: modelsURLString) else {
            throw LLMClientError.invalidEndpoint(modelsURLString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if provider == .anthropic {
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw LLMClientError.httpError(httpResponse.statusCode, body)
        }

        return parseModelsJSON(data)
    }

    public static func parseModelsJSON(_ data: Data) -> [RemoteModelInfo] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        let rawList: [[String: Any]]
        if let dataArray = json["data"] as? [[String: Any]] {
            rawList = dataArray
        } else if let modelsArray = json["models"] as? [[String: Any]] {
            rawList = modelsArray
        } else {
            return []
        }

        var models: [RemoteModelInfo] = []
        for item in rawList {
            guard let rawId = (item["id"] as? String) ?? (item["name"] as? String), !rawId.isEmpty else {
                continue
            }
            let apiName = (item["name"] as? String) ?? (item["display_name"] as? String)
            let ownedBy = item["owned_by"] as? String
            let contextWindow = (item["context_window"] as? Int) ?? (item["context_length"] as? Int)
            let maxOutput = item["max_output_tokens"] as? Int

            var effortLevels: [String] = []
            var defaultEffort: String? = nil

            if let effortDict = item["effort"] as? [String: Any] {
                if let levels = effortDict["supported_levels"] as? [String] {
                    effortLevels = levels
                }
                defaultEffort = effortDict["default_level"] as? String
            }

            models.append(
                RemoteModelInfo(
                    id: rawId,
                    name: apiName,
                    ownedBy: ownedBy,
                    contextWindow: contextWindow,
                    maxOutputTokens: maxOutput,
                    supportedEffortLevels: effortLevels,
                    defaultEffortLevel: defaultEffort
                )
            )
        }

        return models
    }

    /// Parses a single OpenAI-compatible `data: {...}` SSE JSON payload.
    public static func parseOpenAISSELine(
        _ line: String,
        accumulatedContent: inout String,
        accumulatedReasoning: inout String,
        toolCallsByIndex: inout [Int: (id: String, name: String, arguments: String)],
        finishReason: inout String?
    ) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return false }
        let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            return true
        }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first else {
            return false
        }

        if let reason = first["finish_reason"] as? String, !reason.isEmpty {
            finishReason = reason
        }

        guard let delta = first["delta"] as? [String: Any] else { return false }

        if let contentChunk = delta["content"] as? String {
            accumulatedContent += contentChunk
        }

        if let reasoningChunk = delta["reasoning_content"] as? String {
            accumulatedReasoning += reasoningChunk
        } else if let reasoningChunk = delta["reasoning"] as? String {
            accumulatedReasoning += reasoningChunk
        }

        if let rawToolCalls = delta["tool_calls"] as? [[String: Any]] {
            for tc in rawToolCalls {
                let index = tc["index"] as? Int ?? 0
                var entry = toolCallsByIndex[index] ?? (id: "", name: "", arguments: "")
                if let id = tc["id"] as? String, !id.isEmpty {
                    entry.id = id
                }
                if let fn = tc["function"] as? [String: Any] {
                    if let name = fn["name"] as? String, !name.isEmpty {
                        entry.name += name
                    }
                    if let args = fn["arguments"] as? String {
                        entry.arguments += args
                    }
                }
                toolCallsByIndex[index] = entry
            }
        }

        return false
    }

    @MainActor
    public func streamTurn(
        messages: [ChatMessage],
        provider: LLMProviderType,
        model: String,
        baseURL: String,
        apiKey: String,
        systemPrompt: String,
        temperature: Double,
        reasoningEffort: String? = nil,
        enableServerSideSearch: Bool,
        onUpdate: @escaping @MainActor (String, String) -> Void
    ) async throws -> StreamDeltaResult {
        if provider.requiresAPIKey && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw LLMClientError.missingAPIKey(provider.displayName)
        }

        // If model has not been fetched yet, dynamically resolve it from the provider's /models endpoint
        var activeModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if activeModel.isEmpty {
            let discovered = try await Self.fetchRemoteModels(baseURL: baseURL, apiKey: apiKey, provider: provider)
            if let first = discovered.first {
                activeModel = first.id
                SettingsStore.shared.availableModels = discovered
                SettingsStore.shared.currentModel = first.id
            }
        }

        if provider == .anthropic {
            return try await streamAnthropicTurn(
                messages: messages,
                model: activeModel,
                baseURL: baseURL,
                apiKey: apiKey,
                systemPrompt: systemPrompt,
                temperature: temperature,
                onUpdate: onUpdate
            )
        } else {
            return try await streamOpenAICompatibleTurn(
                messages: messages,
                provider: provider,
                model: activeModel,
                baseURL: baseURL,
                apiKey: apiKey,
                systemPrompt: systemPrompt,
                temperature: temperature,
                reasoningEffort: reasoningEffort,
                enableServerSideSearch: enableServerSideSearch,
                onUpdate: onUpdate
            )
        }
    }

    // MARK: - OpenAI / DeepSeek / OpenRouter / Groq / Ollama Streaming

    @MainActor
    private func streamOpenAICompatibleTurn(
        messages: [ChatMessage],
        provider: LLMProviderType,
        model: String,
        baseURL: String,
        apiKey: String,
        systemPrompt: String,
        temperature: Double,
        reasoningEffort: String?,
        enableServerSideSearch: Bool,
        onUpdate: @escaping @MainActor (String, String) -> Void
    ) async throws -> StreamDeltaResult {
        let normalizedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let endpointString = normalizedBase.hasSuffix("/chat/completions")
            ? normalizedBase
            : "\(normalizedBase)/chat/completions"

        guard let url = URL(string: endpointString) else {
            throw LLMClientError.invalidEndpoint(endpointString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if provider == .openrouter {
            request.setValue("https://github.com/r0bledas/SparkBar", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("SparkBar", forHTTPHeaderField: "X-Title")
        }

        var apiMessages: [[String: Any]] = []
        if !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            apiMessages.append([
                "role": "system",
                "content": systemPrompt
            ])
        }

        var i = 0
        while i < messages.count {
            let msg = messages[i]
            switch msg.role {
            case .system:
                apiMessages.append(["role": "system", "content": msg.content])
            case .user:
                let lowerModel = model.lowercased()
                let isTextOnlyDeepSeek = (provider == .deepseek && !lowerModel.contains("flash") && !lowerModel.contains("vl") && !lowerModel.contains("vision"))
                if msg.attachedImages.isEmpty {
                    apiMessages.append(["role": "user", "content": msg.content])
                } else if isTextOnlyDeepSeek {
                    // DeepSeek Pro / Reasoner is text-only: enrich prompt with on-device Vision OCR + local file path
                    var enriched = msg.content
                    for img in msg.attachedImages {
                        let ocr = VisionOCRHelper.recognizeText(from: img.base64Data)
                        var block = "\n\n[Attached Image: \(img.fileName ?? "image.png")"
                        if let loc = img.localFilePath {
                            block += " | Local Path: `\(loc)`"
                        }
                        if !ocr.isEmpty {
                            block += "\nOCR Extracted Text:\n```\n\(ocr)\n```"
                        }
                        block += "]"
                        enriched += block
                    }
                    apiMessages.append(["role": "user", "content": enriched])
                } else {
                    // Vision-enabled multimodal payload (DeepSeek Flash, OpenAI, OpenRouter, Gemini, Groq, Ollama)
                    var contentParts: [[String: Any]] = []
                    if !msg.content.isEmpty {
                        contentParts.append(["type": "text", "text": msg.content])
                    }
                    for img in msg.attachedImages {
                        contentParts.append([
                            "type": "image_url",
                            "image_url": [
                                "url": "data:\(img.mimeType);base64,\(img.base64Data)"
                            ]
                        ])
                    }
                    apiMessages.append(["role": "user", "content": contentParts])
                }
            case .assistant:
                var dict: [String: Any] = ["role": "assistant"]
                if !msg.content.isEmpty {
                    dict["content"] = msg.content
                } else if msg.toolCalls != nil {
                    dict["content"] = NSNull()
                } else {
                    dict["content"] = ""
                }
                if let reasoning = msg.reasoningContent, !reasoning.isEmpty {
                    dict["reasoning_content"] = reasoning
                }
                if let tcs = msg.toolCalls, !tcs.isEmpty {
                    dict["tool_calls"] = tcs.map { tc in
                        [
                            "id": tc.id,
                            "type": "function",
                            "function": [
                                "name": tc.name,
                                "arguments": tc.arguments
                            ]
                        ]
                    }
                    apiMessages.append(dict)

                    // Collect all immediately following `.tool` responses and ensure every `tool_call_id` has a response
                    var respondedIds = Set<String>()
                    var j = i + 1
                    while j < messages.count && messages[j].role == .tool {
                        let toolMsg = messages[j]
                        let callId = toolMsg.toolCallId ?? "call_0"
                        respondedIds.insert(callId)
                        apiMessages.append([
                            "role": "tool",
                            "tool_call_id": callId,
                            "content": toolMsg.content
                        ])
                        j += 1
                    }
                    for tc in tcs where !respondedIds.contains(tc.id) {
                        apiMessages.append([
                            "role": "tool",
                            "tool_call_id": tc.id,
                            "content": "[Tool execution interrupted or cancelled]"
                        ])
                    }
                    i = j
                    continue
                } else {
                    apiMessages.append(dict)
                }
            case .tool:
                // Orphaned tool message without a preceding assistant tool_calls message: skip to avoid HTTP 400
                break
            }
            i += 1
        }

        var effectiveModel = model
        if provider == .openrouter && enableServerSideSearch && !effectiveModel.hasSuffix(":online") && !effectiveModel.contains("sonar") {
            effectiveModel += ":online"
        }

        var body: [String: Any] = [
            "model": effectiveModel,
            "messages": apiMessages,
            "stream": true
        ]

        if let effort = reasoningEffort, !effort.isEmpty, effort.lowercased() != "none" {
            body["reasoning_effort"] = effort
        }

        let tools = ToolRegistry.activeToolsJSON()
        if !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = "auto"
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line + "\n"
                if errorBody.count > 2000 { break }
            }
            throw LLMClientError.httpError(httpResponse.statusCode, errorBody.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var accumulatedContent = ""
        var accumulatedReasoning = ""
        var toolCallsByIndex: [Int: (id: String, name: String, arguments: String)] = [:]
        var finishReason: String?

        for try await line in bytes.lines {
            try Task.checkCancellation()
            let isDone = Self.parseOpenAISSELine(
                line,
                accumulatedContent: &accumulatedContent,
                accumulatedReasoning: &accumulatedReasoning,
                toolCallsByIndex: &toolCallsByIndex,
                finishReason: &finishReason
            )
            onUpdate(accumulatedContent, accumulatedReasoning)
            if isDone { break }
        }

        let sortedToolCalls: [ToolCallRequest] = toolCallsByIndex.keys.sorted().compactMap { idx in
            guard let item = toolCallsByIndex[idx], !item.name.isEmpty else { return nil }
            let callId = item.id.isEmpty ? "call_\(idx)_\(UUID().uuidString.prefix(6))" : item.id
            return ToolCallRequest(id: callId, name: item.name, arguments: item.arguments.isEmpty ? "{}" : item.arguments)
        }

        return StreamDeltaResult(
            content: accumulatedContent,
            reasoningContent: accumulatedReasoning,
            toolCalls: sortedToolCalls,
            finishReason: finishReason
        )
    }

    // MARK: - Anthropic Messages API Streaming

    @MainActor
    private func streamAnthropicTurn(
        messages: [ChatMessage],
        model: String,
        baseURL: String,
        apiKey: String,
        systemPrompt: String,
        temperature: Double,
        onUpdate: @escaping @MainActor (String, String) -> Void
    ) async throws -> StreamDeltaResult {
        let normalizedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        let endpointString = normalizedBase.hasSuffix("/messages")
            ? normalizedBase
            : "\(normalizedBase)/messages"

        guard let url = URL(string: endpointString) else {
            throw LLMClientError.invalidEndpoint(endpointString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        var anthropicMessages: [[String: Any]] = []
        for msg in messages {
            switch msg.role {
            case .user:
                if msg.attachedImages.isEmpty {
                    anthropicMessages.append(["role": "user", "content": msg.content])
                } else {
                    var contentBlocks: [[String: Any]] = []
                    for img in msg.attachedImages {
                        contentBlocks.append([
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": img.mimeType,
                                "data": img.base64Data
                            ]
                        ])
                    }
                    if !msg.content.isEmpty {
                        contentBlocks.append(["type": "text", "text": msg.content])
                    }
                    anthropicMessages.append(["role": "user", "content": contentBlocks])
                }
            case .assistant:
                var contentBlocks: [[String: Any]] = []
                if !msg.content.isEmpty {
                    contentBlocks.append(["type": "text", "text": msg.content])
                }
                if let tcs = msg.toolCalls {
                    for tc in tcs {
                        let inputObj = ToolExecutor.parseJSONArguments(tc.arguments)
                        contentBlocks.append([
                            "type": "tool_use",
                            "id": tc.id,
                            "name": tc.name,
                            "input": inputObj
                        ])
                    }
                }
                if !contentBlocks.isEmpty {
                    anthropicMessages.append(["role": "assistant", "content": contentBlocks])
                }
            case .tool:
                anthropicMessages.append([
                    "role": "user",
                    "content": [
                        [
                            "type": "tool_result",
                            "tool_use_id": msg.toolCallId ?? "tool_0",
                            "content": msg.content
                        ]
                    ]
                ])
            case .system:
                break
            }
        }

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "messages": anthropicMessages,
            "temperature": temperature,
            "stream": true
        ]
        if !systemPrompt.isEmpty {
            body["system"] = systemPrompt
        }

        let openAITools = ToolRegistry.activeToolsJSON()
        if !openAITools.isEmpty {
            let anthropicTools: [[String: Any]] = openAITools.compactMap { item in
                guard let fn = item["function"] as? [String: Any],
                      let name = fn["name"] as? String,
                      let desc = fn["description"] as? String,
                      let schema = fn["parameters"] as? [String: Any] else { return nil }
                return [
                    "name": name,
                    "description": desc,
                    "input_schema": schema
                ]
            }
            body["tools"] = anthropicTools
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line + "\n"
                if errorBody.count > 2000 { break }
            }
            throw LLMClientError.httpError(httpResponse.statusCode, errorBody.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var accumulatedContent = ""
        var toolCallsByIndex: [Int: (id: String, name: String, arguments: String)] = [:]
        var finishReason: String?

        for try await line in bytes.lines {
            try Task.checkCancellation()
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else { continue }

            if type == "content_block_start",
               let index = json["index"] as? Int,
               let block = json["content_block"] as? [String: Any],
               block["type"] as? String == "tool_use" {
                let id = block["id"] as? String ?? "tool_\(index)"
                let name = block["name"] as? String ?? ""
                toolCallsByIndex[index] = (id: id, name: name, arguments: "")
            } else if type == "content_block_delta",
                      let index = json["index"] as? Int,
                      let delta = json["delta"] as? [String: Any] {
                let deltaType = delta["type"] as? String
                if deltaType == "text_delta", let text = delta["text"] as? String {
                    accumulatedContent += text
                    onUpdate(accumulatedContent, "")
                } else if deltaType == "input_json_delta", let partial = delta["partial_json"] as? String {
                    var entry = toolCallsByIndex[index] ?? (id: "tool_\(index)", name: "", arguments: "")
                    entry.arguments += partial
                    toolCallsByIndex[index] = entry
                }
            } else if type == "message_delta",
                      let delta = json["delta"] as? [String: Any],
                      let stopReason = delta["stop_reason"] as? String {
                finishReason = stopReason == "tool_use" ? "tool_calls" : stopReason
            }
        }

        let sortedToolCalls: [ToolCallRequest] = toolCallsByIndex.keys.sorted().compactMap { idx in
            guard let item = toolCallsByIndex[idx], !item.name.isEmpty else { return nil }
            return ToolCallRequest(id: item.id, name: item.name, arguments: item.arguments.isEmpty ? "{}" : item.arguments)
        }

        return StreamDeltaResult(
            content: accumulatedContent,
            reasoningContent: "",
            toolCalls: sortedToolCalls,
            finishReason: finishReason
        )
    }
}
