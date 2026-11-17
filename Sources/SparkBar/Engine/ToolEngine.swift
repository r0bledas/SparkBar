import Foundation
import AppKit
import WebKit

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
                    "description": "Execute a zsh command in the user's login shell environment (full Homebrew PATH, persistent working directory across calls, 30s default synchronous window with automatic promotion to a background job if it runs longer).",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "command": [
                                "type": "string",
                                "description": "The zsh shell command to run"
                            ],
                            "working_directory": [
                                "type": "string",
                                "description": "Optional directory path to execute in (defaults to persistent session cwd)"
                            ],
                            "background": [
                                "type": "boolean",
                                "description": "Set true to immediately start as a background job and return a job_id"
                            ]
                        ],
                        "required": ["command"]
                    ]
                ]
            ])

            tools.append([
                "type": "function",
                "function": [
                    "name": "job_status",
                    "description": "Check the status, PID, elapsed time, and recent output of a background job started by run_command.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "job_id": [
                                "type": "string",
                                "description": "The job_id returned by run_command"
                            ]
                        ],
                        "required": ["job_id"]
                    ]
                ]
            ])

            tools.append([
                "type": "function",
                "function": [
                    "name": "job_cancel",
                    "description": "Terminate a running background job by job_id.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "job_id": [
                                "type": "string",
                                "description": "The job_id to terminate"
                            ]
                        ],
                        "required": ["job_id"]
                    ]
                ]
            ])
        }

        if settings.enableFileTools {
            tools.append([
                "type": "function",
                "function": [
                    "name": "render_pdf",
                    "description": "First-class HTML or Markdown to PDF generator using native macOS WebKit createPDF + PDFKit verification in 1 call. Automatically verifies page_count and byte size.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "output_path": [
                                "type": "string",
                                "description": "Destination file path for the generated .pdf"
                            ],
                            "html": [
                                "type": "string",
                                "description": "HTML (or plain content) to render into the PDF"
                            ],
                            "input_path": [
                                "type": "string",
                                "description": "Optional path to an existing .html file to render instead of inline html"
                            ]
                        ],
                        "required": ["output_path"]
                    ]
                ]
            ])

            tools.append([
                "type": "function",
                "function": [
                    "name": "pdf_info",
                    "description": "Verify a PDF file using native macOS PDFKit (returns exact page_count, page dimensions, byte size, and text preview — reliable even on unindexed files where mdls returns null).",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "path": [
                                "type": "string",
                                "description": "Path to the PDF file"
                            ]
                        ],
                        "required": ["path"]
                    ]
                ]
            ])
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
            let background = args["background"] as? Bool ?? false
            result = await JobManager.shared.runCommand(command, workingDirectory: cwd, background: background, timeoutSeconds: 30.0)
        case "job_status":
            let jobId = args["job_id"] as? String ?? ""
            result = JobManager.shared.formatJobStatus(jobId: jobId)
        case "job_cancel":
            let jobId = args["job_id"] as? String ?? ""
            result = JobManager.shared.cancelJob(jobId: jobId)
        case "render_pdf":
            let outPath = args["output_path"] as? String ?? ""
            let html = args["html"] as? String
            let inPath = args["input_path"] as? String
            result = await NativePDFRenderer.renderToPDF(htmlOrMarkdown: html, inputPath: inPath, outputPath: outPath)
        case "pdf_info":
            let path = args["path"] as? String ?? ""
            result = await MainActor.run { NativePDFRenderer.inspectPDF(at: path) }
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
        JobManager.shared.resolvePath(path)
    }

    // MARK: - Web Search (Native WKWebView Search + Wikipedia / HN API Fallbacks)

    private static func performWebSearch(query: String) async -> (String, Bool) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ("Error: Empty search query.", true)
        }

        // 1. Primary: Native offscreen WKWebView search (executes with a real macOS Safari WebKit engine)
        if let webKitResults = await WebKitSearchRunner.search(query: trimmed),
           !webKitResults.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (webKitResults, false)
        }

        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return ("Error: Invalid search query.", true)
        }

        // 2. Fallback: Wikipedia Search API + HackerNews Algolia API
        var combinedResults: [String] = []

        if let wikiURL = URL(string: "https://en.wikipedia.org/w/api.php?action=query&list=search&srsearch=\(encoded)&format=json") {
            if let (wikiData, _) = try? await URLSession.shared.data(from: wikiURL),
               let json = try? JSONSerialization.jsonObject(with: wikiData) as? [String: Any],
               let queryDict = json["query"] as? [String: Any],
               let searchArr = queryDict["search"] as? [[String: Any]] {
                for item in searchArr.prefix(4) {
                    let title = item["title"] as? String ?? ""
                    let snippet = stripHTMLTags(item["snippet"] as? String ?? "")
                    let pageURL = "https://en.wikipedia.org/wiki/" + (title.replacingOccurrences(of: " ", with: "_").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")
                    if !title.isEmpty {
                        combinedResults.append("• [Wikipedia] \(title)\n  URL: \(pageURL)\n  Snippet: \(snippet)")
                    }
                }
            }
        }

        if let hnURL = URL(string: "https://hn.algolia.com/api/v1/search?query=\(encoded)&hitsPerPage=4") {
            if let (hnData, _) = try? await URLSession.shared.data(from: hnURL),
               let json = try? JSONSerialization.jsonObject(with: hnData) as? [String: Any],
               let hits = json["hits"] as? [[String: Any]] {
                for hit in hits.prefix(4) {
                    let title = hit["title"] as? String ?? ""
                    let url = hit["url"] as? String ?? ""
                    if !title.isEmpty && !url.isEmpty {
                        combinedResults.append("• \(title)\n  URL: \(url)")
                    }
                }
            }
        }

        if !combinedResults.isEmpty {
            return (combinedResults.joined(separator: "\n\n"), false)
        }

        return ("search_failed: Unable to retrieve search results for '\(trimmed)'.", true)
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

/// Uses an offscreen macOS `WKWebView` instance to load search results in a real WebKit engine and extract organic titles, URLs, and snippets.
@MainActor
public final class WebKitSearchRunner: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String?, Never>?
    private var timeoutTask: Task<Void, Never>?

    public static func search(query: String) async -> String? {
        let runner = WebKitSearchRunner()
        return await runner.run(query: query)
    }

    private func run(query: String) async -> String? {
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://duckduckgo.com/?q=\(encoded)&ia=web") else {
            return nil
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            self.continuation = cont

            let config = WKWebViewConfiguration()
            let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
            wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
            wv.navigationDelegate = self
            self.webView = wv

            wv.load(URLRequest(url: url, timeoutInterval: 10))

            self.timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 8_500_000_000)
                self?.finish(with: nil)
            }
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            // Wait briefly for client-side organic results DOM hydration
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            guard let self = self, self.continuation != nil else { return }

            let js = #"""
            (() => {
                const items = [];
                const articles = document.querySelectorAll('article[data-testid="result"], li[data-layout="organic"], .react-results--main li');
                for (const el of articles) {
                    const titleLink = el.querySelector('h2 a, a[data-testid="result-title-a"]');
                    if (!titleLink) continue;
                    const title = titleLink.innerText.trim();
                    const href = titleLink.href || '';
                    if (!title || !href || href.includes('duckduckgo.com/y.js')) continue;
                    const snippetEl = el.querySelector('[data-result="snippet"], .OgdwYG6KE2qthn9XQWFC');
                    const snippet = snippetEl ? snippetEl.innerText.trim() : el.innerText.replace(/\s+/g, ' ').trim();
                    items.push("• " + title + "\n  URL: " + href + "\n  Snippet: " + snippet);
                    if (items.length >= 7) break;
                }
                return items.join("\n\n");
            })()
            """#

            do {
                let res = try await webView.evaluateJavaScript(js) as? String
                self.finish(with: res)
            } catch {
                self.finish(with: nil)
            }
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(with: nil)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(with: nil)
    }

    private func finish(with result: String?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        if let cont = continuation {
            continuation = nil
            cont.resume(returning: result)
        }
    }
}
