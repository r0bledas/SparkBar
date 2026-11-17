import Foundation
import AppKit

/// Lightweight native Swift implementation of Hermes Agent / OpenCode tool schemas and execution.
public enum ToolRegistry {
    @MainActor
    public static func activeToolsJSON() -> [[String: Any]] {
        let settings = SettingsStore.shared
        guard settings.enableTools else { return [] }

        var tools: [[String: Any]] = []

        if settings.enableWebSearchTool {
            tools.append([
                "type": "function",
                "function": [
                    "name": "web_search",
                    "description": "Search the live web for up-to-date information, documentation, news, or facts. Returns top titles, URLs, and snippets.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "query": [
                                "type": "string",
                                "description": "Search query keywords"
                            ]
                        ],
                        "required": ["query"]
                    ]
                ]
            ])

            tools.append([
                "type": "function",
                "function": [
                    "name": "fetch_url",
                    "description": "Fetch and extract readable text content from a web URL.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "url": [
                                "type": "string",
                                "description": "Full HTTP/HTTPS URL to read"
                            ]
                        ],
                        "required": ["url"]
                    ]
                ]
            ])
        }

        if settings.enableTerminalTool {
            tools.append([
                "type": "function",
                "function": [
                    "name": "run_command",
                    "description": "Execute a non-interactive zsh shell command on the user's Mac and return stdout/stderr. Useful for checking git status, system info, calculations, or developer tasks.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "command": [
                                "type": "string",
                                "description": "The shell command to run"
                            ],
                            "working_directory": [
                                "type": "string",
                                "description": "Optional directory path to execute in"
                            ]
                        ],
                        "required": ["command"]
                    ]
                ]
            ])
        }

        if settings.enableFileTools {
            tools.append([
                "type": "function",
                "function": [
                    "name": "read_file",
                    "description": "Read the text contents of a local file on the user's Mac.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "path": [
                                "type": "string",
                                "description": "Absolute or ~-relative path to the file"
                            ],
                            "max_lines": [
                                "type": "integer",
                                "description": "Maximum number of lines to read (default 200)"
                            ]
                        ],
                        "required": ["path"]
                    ]
                ]
            ])

            tools.append([
                "type": "function",
                "function": [
                    "name": "write_file",
                    "description": "Write or overwrite text content to a local file.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "path": [
                                "type": "string",
                                "description": "Absolute or ~-relative path to the file"
                            ],
                            "content": [
                                "type": "string",
                                "description": "Full text content to write"
                            ]
                        ],
                        "required": ["path", "content"]
                    ]
                ]
            ])

            tools.append([
                "type": "function",
                "function": [
                    "name": "list_directory",
                    "description": "List files and subdirectories at a given path on the user's Mac.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "path": [
                                "type": "string",
                                "description": "Absolute or ~-relative directory path"
                            ]
                        ],
                        "required": ["path"]
                    ]
                ]
            ])
        }

        if settings.enableClipboardTool {
            tools.append([
                "type": "function",
                "function": [
                    "name": "clipboard",
                    "description": "Read from or write text to the macOS system clipboard.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "action": [
                                "type": "string",
                                "enum": ["read", "write"],
                                "description": "Whether to read or write the clipboard"
                            ],
                            "text": [
                                "type": "string",
                                "description": "Text to copy to clipboard when action is 'write'"
                            ]
                        ],
                        "required": ["action"]
                    ]
                ]
            ])
        }

        return tools
    }
}

public enum ToolExecutor {
    public static func execute(_ call: ToolCallRequest) async -> ToolExecutionRecord {
        let start = DispatchTime.now()
        let args = parseJSONArguments(call.arguments)

        let result: (output: String, isError: Bool)
        switch call.name {
        case "web_search":
            let query = args["query"] as? String ?? ""
            result = await performWebSearch(query: query)
        case "fetch_url":
            let urlStr = args["url"] as? String ?? ""
            result = await performFetchURL(urlString: urlStr)
        case "run_command":
            let command = args["command"] as? String ?? ""
            let cwd = args["working_directory"] as? String
            result = await performRunCommand(command: command, workingDirectory: cwd)
        case "read_file":
            let path = args["path"] as? String ?? ""
            let maxLines = args["max_lines"] as? Int ?? 200
            result = performReadFile(path: path, maxLines: maxLines)
        case "write_file":
            let path = args["path"] as? String ?? ""
            let content = args["content"] as? String ?? ""
            result = performWriteFile(path: path, content: content)
        case "list_directory":
            let path = args["path"] as? String ?? "."
            result = performListDirectory(path: path)
        case "clipboard":
            let action = args["action"] as? String ?? "read"
            let text = args["text"] as? String
            result = await performClipboard(action: action, text: text)
        default:
            result = ("Unknown tool '\(call.name)'", true)
        }

        let end = DispatchTime.now()
        let ms = Int((end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)

        return ToolExecutionRecord(
            toolCallId: call.id,
            toolName: call.name,
            arguments: call.arguments,
            output: result.output,
            durationMs: ms,
            isError: result.isError
        )
    }

    public static func parseJSONArguments(_ jsonString: String) -> [String: Any] {
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    private static func expandPath(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    // MARK: - Web Search (DuckDuckGo Lite HTML + Instant Answer API)

    private static func performWebSearch(query: String) async -> (String, Bool) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ("Error: Empty search query.", true)
        }

        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://html.duckduckgo.com/html/?q=\(encoded)") else {
            return ("Error: Invalid search query.", true)
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let html = String(data: data, encoding: .utf8) ?? ""
            let parsed = parseDuckDuckGoHTML(html, maxResults: 6)
            if !parsed.isEmpty {
                return (parsed, false)
            }

            // Fallback to DuckDuckGo Instant Answer JSON API
            if let apiURL = URL(string: "https://api.duckduckgo.com/?q=\(encoded)&format=json&no_html=1") {
                let (apiData, _) = try await URLSession.shared.data(from: apiURL)
                if let json = try? JSONSerialization.jsonObject(with: apiData) as? [String: Any] {
                    var summaryParts: [String] = []
                    if let abstract = json["AbstractText"] as? String, !abstract.isEmpty {
                        summaryParts.append("Summary: \(abstract)")
                    }
                    if let related = json["RelatedTopics"] as? [[String: Any]] {
                        for topic in related.prefix(5) {
                            if let text = topic["Text"] as? String,
                               let firstURL = topic["FirstURL"] as? String {
                                summaryParts.append("- \(text) (\(firstURL))")
                            }
                        }
                    }
                    if !summaryParts.isEmpty {
                        return (summaryParts.joined(separator: "\n"), false)
                    }
                }
            }

            return ("No web search results found for '\(trimmed)'.", false)
        } catch {
            return ("Web search failed: \(error.localizedDescription)", true)
        }
    }

    public static func parseDuckDuckGoHTML(_ html: String, maxResults: Int = 6) -> String {
        var results: [String] = []
        let blocks = html.components(separatedBy: "class=\"result__body\"")
        for block in blocks.dropFirst().prefix(maxResults) {
            let title = extractBetween(block, start: "class=\"result__a\"", end: "</a>")
                .flatMap { afterCloseBracket($0) }
                .map { stripHTMLTags($0) } ?? ""

            let rawHref = extractBetween(block, start: "href=\"", end: "\"") ?? ""
            let cleanURL = decodeDuckDuckGoRedirect(rawHref)

            let snippet = extractBetween(block, start: "class=\"result__snippet\"", end: "</a>")
                .orElse(extractBetween(block, start: "class=\"result__snippet\"", end: "</div>"))
                .flatMap { afterCloseBracket($0) }
                .map { stripHTMLTags($0) } ?? ""

            if !title.isEmpty {
                results.append("• \(title)\n  URL: \(cleanURL)\n  Snippet: \(snippet)")
            }
        }
        return results.joined(separator: "\n\n")
    }

    private static func decodeDuckDuckGoRedirect(_ href: String) -> String {
        if let range = href.range(of: "uddg=") {
            let sub = String(href[range.upperBound...])
            let end = sub.components(separatedBy: "&").first ?? sub
            return end.removingPercentEncoding ?? end
        }
        if href.hasPrefix("//") {
            return "https:" + href
        }
        return href
    }

    private static func extractBetween(_ text: String, start: String, end: String) -> String? {
        guard let startRange = text.range(of: start) else { return nil }
        let remainder = text[startRange.upperBound...]
        guard let endRange = remainder.range(of: end) else { return nil }
        return String(remainder[..<endRange.lowerBound])
    }

    private static func afterCloseBracket(_ text: String) -> String? {
        guard let idx = text.firstIndex(of: ">") else { return text }
        return String(text[text.index(after: idx)...])
    }

    public static func stripHTMLTags(_ html: String) -> String {
        var out = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        let entities: [String: String] = [
            "&amp;": "&",
            "&quot;": "\"",
            "&#x27;": "'",
            "&#39;": "'",
            "&lt;": "<",
            "&gt;": ">",
            "&nbsp;": " "
        ]
        for (entity, char) in entities {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Fetch URL

    private static func performFetchURL(urlString: String) async -> (String, Bool) {
        guard let url = URL(string: urlString) else {
            return ("Error: Invalid URL '\(urlString)'", true)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) SparkBar/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let raw = String(data: data, encoding: .utf8) ?? ""
            let cleaned = stripHTMLTags(raw)
            let truncated = String(cleaned.prefix(8000))
            return (truncated.isEmpty ? "(Empty response)" : truncated, false)
        } catch {
            return ("Failed to fetch URL: \(error.localizedDescription)", true)
        }
    }

    // MARK: - Shell Command Execution

    private static func performRunCommand(command: String, workingDirectory: String?) async -> (String, Bool) {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ("Error: Empty command.", true)
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", command]

                if let cwd = workingDirectory, !cwd.isEmpty {
                    let expanded = expandPath(cwd)
                    if FileManager.default.fileExists(atPath: expanded) {
                        process.currentDirectoryURL = URL(fileURLWithPath: expanded)
                    }
                }

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    let deadline = DispatchTime.now() + .seconds(15)
                    let group = DispatchGroup()
                    group.enter()
                    process.terminationHandler = { _ in
                        group.leave()
                    }
                    if group.wait(timeout: deadline) == .timedOut {
                        process.terminate()
                        continuation.resume(returning: ("Command timed out after 15 seconds.", true))
                        return
                    }

                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    let truncated = output.count > 8000 ? String(output.prefix(8000)) + "\n...[truncated]" : output
                    let isError = process.terminationStatus != 0
                    continuation.resume(returning: (truncated.isEmpty ? "(Exited with code \(process.terminationStatus))" : truncated, isError))
                } catch {
                    continuation.resume(returning: ("Failed to execute command: \(error.localizedDescription)", true))
                }
            }
        }
    }

    // MARK: - File Operations

    private static func performReadFile(path: String, maxLines: Int) -> (String, Bool) {
        let fullPath = expandPath(path)
        guard FileManager.default.fileExists(atPath: fullPath) else {
            return ("File not found: \(fullPath)", true)
        }
        do {
            let content = try String(contentsOfFile: fullPath, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            let limited = lines.prefix(max(1, maxLines)).joined(separator: "\n")
            if lines.count > maxLines {
                return (limited + "\n... [Showing \(maxLines) of \(lines.count) lines]", false)
            }
            return (limited, false)
        } catch {
            return ("Error reading file: \(error.localizedDescription)", true)
        }
    }

    private static func performWriteFile(path: String, content: String) -> (String, Bool) {
        let fullPath = expandPath(path)
        let url = URL(fileURLWithPath: fullPath)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try content.write(to: url, atomically: true, encoding: .utf8)
            return ("Successfully wrote \(content.utf8.count) bytes to \(fullPath)", false)
        } catch {
            return ("Error writing file: \(error.localizedDescription)", true)
        }
    }

    private static func performListDirectory(path: String) -> (String, Bool) {
        let fullPath = expandPath(path)
        do {
            let items = try FileManager.default.contentsOfDirectory(atPath: fullPath).sorted()
            return (items.prefix(200).joined(separator: "\n"), false)
        } catch {
            return ("Error listing directory: \(error.localizedDescription)", true)
        }
    }

    // MARK: - Clipboard

    @MainActor
    private static func performClipboard(action: String, text: String?) -> (String, Bool) {
        let pb = NSPasteboard.general
        if action == "write" {
            guard let text = text else {
                return ("Error: Missing 'text' parameter for clipboard write.", true)
            }
            pb.clearContents()
            pb.setString(text, forType: .string)
            return ("Copied \(text.count) characters to clipboard.", false)
        } else {
            let current = pb.string(forType: .string) ?? "(Clipboard is empty or non-text)"
            return (String(current.prefix(4000)), false)
        }
    }
}

private extension Optional {
    func orElse(_ fallback: @autoclosure () -> Wrapped?) -> Wrapped? {
        switch self {
        case .some(let val): return val
        case .none: return fallback()
        }
    }
}
