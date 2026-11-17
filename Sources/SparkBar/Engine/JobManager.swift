import Foundation
import PDFKit
import WebKit
import AppKit

/// Manages persistent shell state (`cwd` and exported env vars) and background jobs (just like OpenCode / Hermes Agent) with zero RAM overhead.
public final class JobManager: @unchecked Sendable {
    public static let shared = JobManager()

    public struct ManagedJob {
        public let id: String
        public let command: String
        public let pid: Int32
        public let startedAt: Date
        public var isRunning: Bool
        public var exitCode: Int32?
        public var outputBuffer: String
        fileprivate let process: Process
    }

    private let lock = NSLock()
    private var jobs: [String: ManagedJob] = [:]
    private var sessionCwd: String
    private var sessionWorkspacePath: String

    private init() {
        let base = EnvironmentProbe.shared.appSupportDirectory
            .appendingPathComponent("workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.sessionWorkspacePath = base.path
        // Default working directory to the user's home directory (like Terminal / OpenCode), while providing workspace for scratch files
        self.sessionCwd = FileManager.default.homeDirectoryForCurrentUser.path
    }

    public var currentWorkingDirectory: String {
        lock.lock()
        defer { lock.unlock() }
        return sessionCwd
    }

    public var workspaceDirectory: String {
        lock.lock()
        defer { lock.unlock() }
        return sessionWorkspacePath
    }

    public func setWorkingDirectory(_ path: String) {
        let expanded = NSString(string: path).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
            lock.lock()
            sessionCwd = expanded
            lock.unlock()
        }
    }

    public func resolvePath(_ path: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return expanded
        }
        return (currentWorkingDirectory as NSString).appendingPathComponent(expanded)
    }

    /// Runs a command in a login-initialized zsh shell with persistent `cwd`, full user `PATH`, and automatic background job promotion if it runs past `timeoutSeconds` or has `background == true`.
    public func runCommand(
        _ command: String,
        workingDirectory: String?,
        background: Bool = false,
        timeoutSeconds: TimeInterval = 30.0
    ) async -> (output: String, isError: Bool) {
        let effectiveCwd: String
        if let customCwd = workingDirectory, !customCwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            effectiveCwd = resolvePath(customCwd)
        } else {
            effectiveCwd = currentWorkingDirectory
        }

        let jobId = "job_" + UUID().uuidString.prefix(6).lowercased()
        let pwdMarker = "__SPARKBAR_PWD_\(jobId)__"

        // Wrap command so any `cd` inside the command updates our persistent `sessionCwd`
        let wrappedCommand = """
        \(command)
        __sparkbar_exit=$?
        print -r -- "\(pwdMarker)$(pwd)"
        exit $__sparkbar_exit
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", wrappedCommand]

        if FileManager.default.fileExists(atPath: effectiveCwd) {
            process.currentDirectoryURL = URL(fileURLWithPath: effectiveCwd)
        } else {
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        }

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = EnvironmentProbe.shared.effectivePath
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        env["TERM"] = "xterm-256color"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["SPARKBAR_WORKSPACE"] = workspaceDirectory
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return ("Failed to execute command: \(error.localizedDescription)", true)
        }

        let pid = process.processIdentifier
        lock.lock()
        jobs[jobId] = ManagedJob(
            id: jobId,
            command: command,
            pid: pid,
            startedAt: Date(),
            isRunning: true,
            exitCode: nil,
            outputBuffer: "",
            process: process
        )
        lock.unlock()

        // Asynchronously stream stdout/stderr into the job's buffer
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            self?.appendJobOutput(jobId: jobId, chunk: chunk, pwdMarker: pwdMarker)
        }

        let finishGroup = DispatchGroup()
        finishGroup.enter()
        process.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
            if !remaining.isEmpty, let chunk = String(data: remaining, encoding: .utf8) {
                self?.appendJobOutput(jobId: jobId, chunk: chunk, pwdMarker: pwdMarker)
            }
            self?.markJobFinished(jobId: jobId, exitCode: proc.terminationStatus)
            finishGroup.leave()
        }

        if background {
            try? await Task.sleep(nanoseconds: 250_000_000)
            let snapshot = getJobSnapshot(jobId: jobId)
            return (
                "Started background job `\(jobId)` (PID \(pid)).\nUse `job_status` or `job_output` with `job_id: \"\(jobId)\"` to check progress.\nInitial output:\n\(snapshot?.outputBuffer ?? "(running)")",
                false
            )
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let waitResult = finishGroup.wait(timeout: .now() + timeoutSeconds)
                guard let self = self else {
                    continuation.resume(returning: ("Cancelled", true))
                    return
                }

                if waitResult == .timedOut {
                    // Auto-promote to background job instead of killing at the cliff!
                    let partial = self.getJobSnapshot(jobId: jobId)?.outputBuffer ?? ""
                    let msg = """
                    Command is still running after \(Int(timeoutSeconds))s and was promoted to background job `\(jobId)` (PID \(pid)).
                    Use `job_status(job_id: "\(jobId)")` or `job_output(job_id: "\(jobId)")` to monitor it, or `job_cancel(job_id: "\(jobId)")` to stop it.
                    Partial output so far:
                    \(partial.suffix(3000))
                    """
                    continuation.resume(returning: (msg, false))
                } else {
                    if let job = self.getJobSnapshot(jobId: jobId) {
                        let out = job.outputBuffer.trimmingCharacters(in: .newlines)
                        let truncated = out.count > 10_000 ? String(out.prefix(10_000)) + "\n...[truncated]" : out
                        let isErr = (job.exitCode ?? 0) != 0
                        let finalOut = truncated.isEmpty ? "(Exited with code \(job.exitCode ?? 0))" : truncated
                        continuation.resume(returning: (finalOut, isErr))
                    } else {
                        continuation.resume(returning: ("(Completed)", false))
                    }
                }
            }
        }
    }

    private func appendJobOutput(jobId: String, chunk: String, pwdMarker: String) {
        lock.lock()
        defer { lock.unlock() }
        guard var job = jobs[jobId] else { return }

        var cleanedChunk = chunk
        if let range = cleanedChunk.range(of: pwdMarker) {
            let after = String(cleanedChunk[range.upperBound...])
            let pwdLine = after.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !pwdLine.isEmpty && pwdLine.hasPrefix("/") {
                sessionCwd = pwdLine
            }
            cleanedChunk = String(cleanedChunk[..<range.lowerBound])
        }

        job.outputBuffer += cleanedChunk
        if job.outputBuffer.count > 64_000 {
            job.outputBuffer = String(job.outputBuffer.suffix(64_000))
        }
        jobs[jobId] = job
    }

    private func markJobFinished(jobId: String, exitCode: Int32) {
        lock.lock()
        defer { lock.unlock() }
        guard var job = jobs[jobId] else { return }
        job.isRunning = false
        job.exitCode = exitCode
        jobs[jobId] = job
    }

    public func getJobSnapshot(jobId: String) -> ManagedJob? {
        lock.lock()
        defer { lock.unlock() }
        return jobs[jobId]
    }

    public func formatJobStatus(jobId: String) -> (String, Bool) {
        guard let job = getJobSnapshot(jobId: jobId) else {
            return ("Error: Unknown job_id '\(jobId)'", true)
        }
        let elapsed = String(format: "%.1fs", Date().timeIntervalSince(job.startedAt))
        let state = job.isRunning ? "running" : "completed (exit_code: \(job.exitCode ?? 0))"
        return (
            """
            job_id: \(job.id)
            pid: \(job.pid)
            state: \(state)
            elapsed: \(elapsed)
            command: \(job.command)
            output_tail:
            \(job.outputBuffer.suffix(2000))
            """,
            false
        )
    }

    public func cancelJob(jobId: String) -> (String, Bool) {
        lock.lock()
        guard let job = jobs[jobId] else {
            lock.unlock()
            return ("Error: Unknown job_id '\(jobId)'", true)
        }
        lock.unlock()
        if job.isRunning {
            job.process.terminate()
            return ("Terminated job \(jobId) (PID \(job.pid)).", false)
        } else {
            return ("Job \(jobId) already finished with exit code \(job.exitCode ?? 0).", false)
        }
    }
}

/// First-class native WebKit HTML/Markdown -> PDF renderer & PDFKit verifier.
@MainActor
public final class NativePDFRenderer: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<(String, Bool), Never>?
    private var outputPath: String = ""

    public static func renderToPDF(htmlOrMarkdown: String?, inputPath: String?, outputPath: String) async -> (String, Bool) {
        let resolvedOut = JobManager.shared.resolvePath(outputPath)
        var rawSource = htmlOrMarkdown ?? ""

        if rawSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let inPath = inputPath {
            let resolvedIn = JobManager.shared.resolvePath(inPath)
            if let fileText = try? String(contentsOfFile: resolvedIn, encoding: .utf8) {
                rawSource = fileText
            } else {
                return ("Error: Could not read input file at \(resolvedIn)", true)
            }
        }

        guard !rawSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ("Error: Provide non-empty `html` or `input_path` to render_pdf.", true)
        }

        let fullHTML = buildStyledHTMLDocument(from: rawSource)
        let renderer = NativePDFRenderer()
        return await renderer.run(html: fullHTML, outputPath: resolvedOut)
    }

    public static func inspectPDF(at path: String) -> (String, Bool) {
        let resolved = JobManager.shared.resolvePath(path)
        let url = URL(fileURLWithPath: resolved)
        guard FileManager.default.fileExists(atPath: resolved) else {
            return ("Error: PDF file not found at \(resolved)", true)
        }
        let attrs = (try? FileManager.default.attributesOfItem(atPath: resolved)) ?? [:]
        let fileSize = (attrs[.size] as? Int64) ?? 0

        guard let doc = PDFDocument(url: url) else {
            return ("Error: File at \(resolved) (\(fileSize) bytes) is not a valid PDF document.", true)
        }

        let pageCount = doc.pageCount
        var pageBoundsStr = "unknown"
        if let firstPage = doc.page(at: 0) {
            let b = firstPage.bounds(for: .mediaBox)
            pageBoundsStr = "\(Int(b.width))x\(Int(b.height)) pt"
        }
        let previewText = String((doc.string ?? "").prefix(600)).trimmingCharacters(in: .whitespacesAndNewlines)

        return (
            """
            path: \(resolved)
            valid_pdf: true
            file_size_bytes: \(fileSize)
            page_count: \(pageCount)
            page_size: \(pageBoundsStr)
            text_preview: \(previewText.isEmpty ? "(no extractable text)" : previewText)
            """,
            false
        )
    }

    private func run(html: String, outputPath: String) async -> (String, Bool) {
        self.outputPath = outputPath
        return await withCheckedContinuation { cont in
            self.continuation = cont
            let config = WKWebViewConfiguration()
            // Standard US Letter width at 72dpi = 612x792
            let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 612, height: 792), configuration: config)
            wv.navigationDelegate = self
            self.webView = wv
            wv.loadHTMLString(html, baseURL: URL(string: "https://cdn.jsdelivr.net"))
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            // Allow 250ms for any KaTeX or web fonts to settle
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self = self, let cont = self.continuation else { return }
            self.continuation = nil

            do {
                let pdfConfig = WKPDFConfiguration()
                let pdfData = try await webView.createPDF(configuration: pdfConfig)
                let outURL = URL(fileURLWithPath: self.outputPath)
                try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try pdfData.write(to: outURL, options: .atomic)

                self.webView = nil
                let (info, isErr) = Self.inspectPDF(at: self.outputPath)
                cont.resume(returning: ("Successfully generated PDF:\n\(info)", isErr))
            } catch {
                self.webView = nil
                cont.resume(returning: ("Failed to generate PDF: \(error.localizedDescription)", true))
            }
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if let cont = continuation {
            continuation = nil
            self.webView = nil
            cont.resume(returning: ("WebKit navigation failed: \(error.localizedDescription)", true))
        }
    }

    private static func buildStyledHTMLDocument(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().contains("<html") || trimmed.lowercased().hasPrefix("<!doctype") {
            return raw
        }
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
            body {
                font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", Arial, sans-serif;
                font-size: 13pt;
                line-height: 1.55;
                color: #111827;
                padding: 40px 48px;
                max-width: 720px;
                margin: 0 auto;
            }
            h1, h2, h3 { color: #0f172a; margin-top: 1.2em; margin-bottom: 0.4em; }
            pre, code {
                font-family: "SF Mono", Menlo, monospace;
                background: #f3f4f6;
                border-radius: 6px;
            }
            pre { padding: 12px; overflow-x: auto; }
            code { padding: 2px 5px; }
            table { border-collapse: collapse; width: 100%; margin: 1em 0; }
            th, td { border: 1px solid #d1d5db; padding: 8px 10px; text-align: left; }
            th { background: #f9fafb; font-weight: 600; }
        </style>
        </head>
        <body>
        \(raw)
        </body>
        </html>
        """
    }
}
