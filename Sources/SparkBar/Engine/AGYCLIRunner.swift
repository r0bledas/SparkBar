import Foundation

/// Events emitted live from `agy --output-format stream-json`.
public enum AGYStreamEvent: Sendable {
    case initialized(conversationId: String)
    case textDelta(stepIndex: Int, delta: String)
    case toolStarted(stepIndex: Int, toolName: String, argumentsJSON: String)
    case toolCompleted(stepIndex: Int, record: ToolExecutionRecord)
    case finished(conversationId: String?, finalResponse: String?, status: String)
}

/// On-demand, zero-idle-RAM runner for the Google Antigravity (`agy`) CLI.
/// Spawns `agy -p ... --output-format stream-json` per turn, streams NDJSON events live,
/// and exits cleanly when the turn finishes so idle RAM remains 0 MB.
public final class AGYCLIRunner: @unchecked Sendable {
    public static let shared = AGYCLIRunner()

    private let processLock = NSLock()
    private var activeProcess: Process?

    private init() {}

    /// Managed location inside Application Support where SparkBar can install `agy` via 1-click download.
    public static var managedBinaryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("SparkBar", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("agy")
    }

    /// Resolves the `agy` executable path across custom settings, AGY-Portable, SparkBar managed bin, and system PATH.
    public static func resolveBinaryPath(customPath: String = "", portableRoot: String = "") -> String? {
        let fm = FileManager.default
        var candidates: [String] = []

        let trimmedCustom = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCustom.isEmpty {
            candidates.append((trimmedCustom as NSString).expandingTildeInPath)
        }

        let trimmedPortable = portableRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPortable.isEmpty {
            let expanded = (trimmedPortable as NSString).expandingTildeInPath
            candidates.append((expanded as NSString).appendingPathComponent("macOS/bin/agy"))
            candidates.append((expanded as NSString).appendingPathComponent("bin/agy"))
        }

        candidates.append(managedBinaryURL.path)

        let home = fm.homeDirectoryForCurrentUser.path
        candidates.append(contentsOf: [
            "\(home)/.gemini/antigravity/scratch/AGY-Portable/macOS/bin/agy",
            "\(home)/.local/bin/agy",
            "/opt/homebrew/bin/agy",
            "/usr/local/bin/agy",
            "\(home)/Library/Application Support/agy/bin/agy"
        ])

        for path in candidates {
            if fm.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Builds process environment, optionally isolating `$HOME` to an `AGY-Portable/data/home` folder.
    public static func buildEnvironment(portableRoot: String = "") -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let fallbackPath = EnvironmentProbe.defaultFallbackPath
        if let existing = env["PATH"], !existing.isEmpty {
            env["PATH"] = "\(existing):\(fallbackPath)"
        } else {
            env["PATH"] = fallbackPath
        }

        let trimmedPortable = portableRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPortable.isEmpty {
            let root = (trimmedPortable as NSString).expandingTildeInPath
            let dataRoot = (root as NSString).appendingPathComponent("data")
            let portableHome = (dataRoot as NSString).appendingPathComponent("home")
            if FileManager.default.fileExists(atPath: portableHome) {
                env["HOME"] = portableHome
                env["XDG_CONFIG_HOME"] = (dataRoot as NSString).appendingPathComponent("config")
                env["XDG_DATA_HOME"] = (dataRoot as NSString).appendingPathComponent("share")
                env["XDG_CACHE_HOME"] = (dataRoot as NSString).appendingPathComponent("cache")
            }
        }
        return env
    }

    /// Parses the stdout of `agy models` into SparkBar `RemoteModelInfo` items.
    public static func parseModelsOutput(_ rawOutput: String) -> [RemoteModelInfo] {
        var results: [RemoteModelInfo] = []
        var seen: Set<String> = []

        for rawLine in rawOutput.components(separatedBy: .newlines) {
            // Strip spinner carriage-return updates (keep only the text after the last '\r')
            let afterCR = rawLine.components(separatedBy: "\r").last ?? rawLine
            let trimmed = afterCR.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("Fetching") || trimmed.hasPrefix("⠋") || trimmed.hasPrefix("⠙") { continue }

            // Format: "<model-id>   <Human Readable Name>"
            let parts = trimmed.split(maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard let idSub = parts.first else { continue }
            let id = String(idSub).trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !id.contains("["), !seen.contains(id) else { continue }

            // Model IDs are lowercase alphanumeric with hyphens/dots
            let validIdChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
            guard id.unicodeScalars.allSatisfy({ validIdChars.contains($0) }) else { continue }

            let displayName: String? = parts.count > 1
                ? String(parts[1]).trimmingCharacters(in: .whitespaces)
                : nil

            seen.insert(id)
            results.append(RemoteModelInfo(id: id, name: displayName, ownedBy: "antigravity"))
        }

        return results
    }

    /// Runs `agy models` to dynamically fetch all models available on the user's Google One / Antigravity plan.
    public static func fetchAvailableModels(customPath: String = "", portableRoot: String = "") async throws -> [RemoteModelInfo] {
        guard let binaryPath = resolveBinaryPath(customPath: customPath, portableRoot: portableRoot) else {
            throw NSError(
                domain: "AGYCLIRunner",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Antigravity CLI (`agy`) not found. Click 'Download AGY CLI' in Settings or point to your AGY-Portable folder."]
            )
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: binaryPath)
                proc.arguments = ["models"]
                proc.environment = buildEnvironment(portableRoot: portableRoot)

                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe

                do {
                    try proc.run()
                    proc.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    let models = parseModelsOutput(output)
                    continuation.resume(returning: models)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Parses a single NDJSON line from `agy --output-format stream-json`.
    public static func parseNDJSONLine(_ line: String) -> AGYStreamEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let eventType = obj["event"] as? String else {
            return nil
        }

        switch eventType {
        case "init":
            if let convId = obj["conversation_id"] as? String, !convId.isEmpty {
                return .initialized(conversationId: convId)
            }
            return nil

        case "step_update":
            guard let update = obj["step_update"] as? [String: Any],
                  let stepType = update["step_type"] as? String else {
                return nil
            }
            let stepIndex = update["step_index"] as? Int ?? 0
            let state = (update["state"] as? String ?? "").uppercased()

            if stepType == "agent_response" {
                if let delta = update["text_delta"] as? String, !delta.isEmpty {
                    return .textDelta(stepIndex: stepIndex, delta: delta)
                }
                return nil
            }

            if stepType == "tool" {
                let toolInfo = update["tool_info"] as? [String: Any]
                let toolName = (update["tool_name"] as? String)
                    ?? (toolInfo?["name"] as? String)
                    ?? "tool"

                var argsJSON = ""
                if let params = toolInfo?["parameters"],
                   JSONSerialization.isValidJSONObject(params),
                   let jsonData = try? JSONSerialization.data(withJSONObject: params, options: [.sortedKeys]),
                   let jsonStr = String(data: jsonData, encoding: .utf8) {
                    argsJSON = jsonStr
                }

                if state == "ACTIVE" {
                    return .toolStarted(stepIndex: stepIndex, toolName: toolName, argumentsJSON: argsJSON)
                } else if state == "DONE" || state == "ERROR" || state == "CANCELLED" {
                    let output = (toolInfo?["output"] as? String) ?? ""
                    let durationSec = update["duration_seconds"] as? Double ?? 0
                    let durationMs = Int(round(durationSec * 1000.0))
                    let isErr = (state == "ERROR")
                    let record = ToolExecutionRecord(
                        toolCallId: "agy_step_\(stepIndex)",
                        toolName: toolName,
                        arguments: argsJSON,
                        output: output,
                        durationMs: durationMs,
                        isError: isErr
                    )
                    return .toolCompleted(stepIndex: stepIndex, record: record)
                }
            }
            return nil

        case "result":
            let resultObj = obj["result"] as? [String: Any]
            let convId = (resultObj?["conversation_id"] as? String) ?? (obj["conversation_id"] as? String)
            let response = resultObj?["response"] as? String
            let status = (resultObj?["status"] as? String) ?? "SUCCESS"
            return .finished(conversationId: convId, finalResponse: response, status: status)

        default:
            return nil
        }
    }

    /// Terminates any currently running `agy` subprocess immediately.
    public func cancelCurrentProcess() {
        processLock.lock()
        let proc = activeProcess
        activeProcess = nil
        processLock.unlock()

        guard let proc = proc, proc.isRunning else { return }
        proc.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
            }
        }
    }

    /// Executes a single turn via `agy -p <prompt> --output-format stream-json`, streaming NDJSON events live.
    public func streamTurn(
        prompt: String,
        model: String,
        conversationId: String?,
        allowTools: Bool,
        customBinaryPath: String = "",
        portableRoot: String = "",
        workingDirectory: String? = nil,
        onEvent: @escaping @Sendable (AGYStreamEvent) -> Void
    ) async throws {
        guard let binaryPath = Self.resolveBinaryPath(customPath: customBinaryPath, portableRoot: portableRoot) else {
            throw NSError(
                domain: "AGYCLIRunner",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Antigravity CLI (`agy`) not found. Open Settings → Google Antigravity (AGY) and click 'Download AGY CLI' or select your AGY-Portable folder."]
            )
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: binaryPath)

                    var args: [String] = [
                        "-p", prompt,
                        "--output-format", "stream-json",
                        "--disable-slash-commands"
                    ]
                    if !model.isEmpty {
                        args.append(contentsOf: ["--model", model])
                    }
                    if let convId = conversationId, !convId.isEmpty {
                        args.append(contentsOf: ["--conversation", convId])
                    }
                    if allowTools {
                        args.append("--dangerously-skip-permissions")
                    }

                    proc.arguments = args
                    proc.environment = Self.buildEnvironment(portableRoot: portableRoot)
                    if let cwd = workingDirectory, FileManager.default.fileExists(atPath: cwd) {
                        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)
                    }

                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    proc.standardOutput = stdoutPipe
                    proc.standardError = stderrPipe

                    let bufferLock = NSLock()
                    var lineBuffer = Data()
                    var stderrData = Data()

                    let flushCompleteLines: () -> Void = {
                        bufferLock.lock()
                        defer { bufferLock.unlock() }
                        while let nlRange = lineBuffer.firstRange(of: Data([0x0A])) {
                            let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<nlRange.lowerBound)
                            lineBuffer.removeSubrange(lineBuffer.startIndex...nlRange.lowerBound)
                            if let line = String(data: lineData, encoding: .utf8),
                               let event = Self.parseNDJSONLine(line) {
                                onEvent(event)
                            }
                        }
                    }

                    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        if chunk.isEmpty {
                            handle.readabilityHandler = nil
                            return
                        }
                        bufferLock.lock()
                        lineBuffer.append(chunk)
                        bufferLock.unlock()
                        flushCompleteLines()
                    }

                    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        if chunk.isEmpty {
                            handle.readabilityHandler = nil
                            return
                        }
                        bufferLock.lock()
                        stderrData.append(chunk)
                        bufferLock.unlock()
                    }

                    self.processLock.lock()
                    self.activeProcess = proc
                    self.processLock.unlock()

                    do {
                        try proc.run()
                        proc.waitUntilExit()
                    } catch {
                        self.processLock.lock()
                        if self.activeProcess === proc { self.activeProcess = nil }
                        self.processLock.unlock()
                        stdoutPipe.fileHandleForReading.readabilityHandler = nil
                        stderrPipe.fileHandleForReading.readabilityHandler = nil
                        continuation.resume(throwing: error)
                        return
                    }

                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    let remaining = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    if !remaining.isEmpty {
                        bufferLock.lock()
                        lineBuffer.append(remaining)
                        bufferLock.unlock()
                    }
                    flushCompleteLines()

                    // Flush any trailing line without newline
                    bufferLock.lock()
                    let leftover = lineBuffer
                    lineBuffer.removeAll()
                    let errStr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    bufferLock.unlock()

                    if !leftover.isEmpty,
                       let line = String(data: leftover, encoding: .utf8),
                       let event = Self.parseNDJSONLine(line) {
                        onEvent(event)
                    }

                    self.processLock.lock()
                    if self.activeProcess === proc { self.activeProcess = nil }
                    self.processLock.unlock()

                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    if proc.terminationStatus != 0 {
                        let msg = errStr.isEmpty ? "Antigravity CLI exited with status \(proc.terminationStatus)." : errStr
                        continuation.resume(throwing: NSError(
                            domain: "AGYCLIRunner",
                            code: Int(proc.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: msg]
                        ))
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            self.cancelCurrentProcess()
        }
    }

    /// Downloads the official macOS `agy` CLI binary from Google's release manifest into `managedBinaryURL`.
    public static func downloadOfficialBinary(onProgress: @escaping @Sendable (String) -> Void) async throws -> String {
        let targetURL = managedBinaryURL
        let binDir = targetURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)

        onProgress("Fetching Google Antigravity CLI manifest…")

        let script = """
        set -euo pipefail
        ARCH=$(uname -m)
        if [ "$ARCH" = "arm64" ]; then
            MANIFEST="darwin_arm64.json"
            DL_FALLBACK="https://storage.googleapis.com/antigravity-public/antigravity-cli/1.2.2-6061403484848128/darwin-arm/cli_mac_arm64.tar.gz"
        else
            MANIFEST="darwin_amd64.json"
            DL_FALLBACK="https://storage.googleapis.com/antigravity-public/antigravity-cli/1.2.2-6061403484848128/darwin-x64/cli_mac_x64.tar.gz"
        fi
        MANIFEST_URL="https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/$MANIFEST"
        DL_URL=$(curl -sL "$MANIFEST_URL" 2>/dev/null | grep -o '"url": *"[^"]*"' | head -n1 | cut -d'"' -f4 || true)
        if [ -z "$DL_URL" ]; then DL_URL="$DL_FALLBACK"; fi
        TMP_ARCHIVE="\(binDir.path)/agy_archive.tar.gz"
        curl -sSL -o "$TMP_ARCHIVE" "$DL_URL"
        tar -xzf "$TMP_ARCHIVE" -C "\(binDir.path)"
        rm -f "$TMP_ARCHIVE"
        if [ -f "\(binDir.path)/antigravity" ]; then
            cp -f "\(binDir.path)/antigravity" "\(targetURL.path)"
        fi
        chmod +x "\(targetURL.path)"
        xattr -dr com.apple.quarantine "\(targetURL.path)" 2>/dev/null || true
        """

        onProgress("Downloading & extracting official macOS agy CLI (~50 MB)…")

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
                proc.arguments = ["-c", script]
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    if proc.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: targetURL.path) {
                        continuation.resume(returning: targetURL.path)
                    } else {
                        continuation.resume(throwing: NSError(
                            domain: "AGYCLIRunner",
                            code: Int(proc.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: "Download failed: \(out.suffix(250))"]
                        ))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
