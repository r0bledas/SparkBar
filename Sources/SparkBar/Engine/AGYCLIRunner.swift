import Foundation
import AppKit

/// Events emitted live from `agy --output-format stream-json`.
public enum AGYStreamEvent: Sendable {
    case initialized(conversationId: String)
    case textDelta(stepIndex: Int, delta: String)
    case toolStarted(stepIndex: Int, toolName: String, argumentsJSON: String)
    case toolCompleted(stepIndex: Int, record: ToolExecutionRecord)
    case finished(conversationId: String?, finalResponse: String?, status: String)
}

private final class AGYProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var proc: Process?
    func set(_ p: Process) { lock.lock(); proc = p; lock.unlock() }
    func get() -> Process? { lock.lock(); defer { lock.unlock() }; return proc }
}

/// On-demand, zero-idle-RAM runner for the Google Antigravity (`agy`) CLI.
/// Spawns `agy -p ... --output-format stream-json` per turn, streams NDJSON events live,
/// and exits cleanly when the turn finishes so idle RAM remains 0 MB.
public final class AGYCLIRunner: @unchecked Sendable {
    public static let shared = AGYCLIRunner()

    private let processLock = NSLock()
    private var interactiveProcesses: [UUID: Process] = [:]

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

    /// Parses the stdout of `agy models` into grouped SparkBar `RemoteModelInfo` items.
    /// Models sharing the same base name + trailing `(<Variant>)` (e.g. `Gemini 4 Neon (Low)`, `Gemini 4 Neon (High)`,
    /// `Orchestrator (Neon)`, `Orchestrator (Argon)`) are consolidated into one model entry whose
    /// `supportedEffortLevels` and `effortVariantModelIds` map each variant to its exact `agy --model` ID.
    public static func parseModelsOutput(_ rawOutput: String) -> [RemoteModelInfo] {
        struct RawEntry {
            let id: String
            let displayName: String
            let baseName: String
            let parenVariant: String?
        }

        let knownEffortLevels: Set<String> = ["low", "medium", "high", "xhigh", "max"]
        let effortOrder: [String: Int] = ["low": 0, "medium": 1, "high": 2, "xhigh": 3, "max": 4]

        var rawEntries: [RawEntry] = []
        var seenIds: Set<String> = []

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
            guard !id.isEmpty, !id.contains("["), !seenIds.contains(id) else { continue }

            let validIdChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
            guard id.unicodeScalars.allSatisfy({ validIdChars.contains($0) }) else { continue }

            let displayName = parts.count > 1
                ? String(parts[1]).trimmingCharacters(in: .whitespaces)
                : id

            // Detect trailing " (<Variant>)" pattern
            var baseName = displayName
            var parenVariant: String? = nil
            if displayName.hasSuffix(")"),
               let openIdx = displayName.lastIndex(of: "("),
               openIdx > displayName.startIndex {
                let candidateBase = displayName[..<openIdx].trimmingCharacters(in: .whitespaces)
                let candidateVariant = displayName[displayName.index(after: openIdx)..<displayName.index(before: displayName.endIndex)]
                    .trimmingCharacters(in: .whitespaces)
                if !candidateBase.isEmpty && !candidateVariant.isEmpty {
                    baseName = candidateBase
                    parenVariant = candidateVariant
                }
            }

            seenIds.insert(id)
            rawEntries.append(RawEntry(id: id, displayName: displayName, baseName: baseName, parenVariant: parenVariant))
        }

        // Count how many entries share each baseName (with a parenthetical variant)
        var baseNameCounts: [String: Int] = [:]
        for entry in rawEntries where entry.parenVariant != nil {
            baseNameCounts[entry.baseName, default: 0] += 1
        }

        // Group entries in stable order of first appearance
        var groupOrder: [String] = []
        var groupedEntries: [String: [RawEntry]] = [:]

        for entry in rawEntries {
            let shouldGroup: Bool
            if let v = entry.parenVariant {
                shouldGroup = (baseNameCounts[entry.baseName] ?? 0) > 1 || knownEffortLevels.contains(v.lowercased())
            } else {
                shouldGroup = false
            }

            let groupKey = shouldGroup ? "group:\(entry.baseName)" : "single:\(entry.id)"
            if groupedEntries[groupKey] == nil {
                groupOrder.append(groupKey)
                groupedEntries[groupKey] = []
            }
            groupedEntries[groupKey]?.append(entry)
        }

        var results: [RemoteModelInfo] = []
        for key in groupOrder {
            guard let entries = groupedEntries[key], let first = entries.first else { continue }

            if key.hasPrefix("group:") {
                var variantMap: [String: String] = [:]
                var variantKeys: [String] = []

                for e in entries {
                    guard let v = e.parenVariant else { continue }
                    let vKey = v.lowercased()
                    if variantMap[vKey] == nil {
                        variantMap[vKey] = e.id
                        variantKeys.append(vKey)
                    }
                }

                // Sort known effort levels in ascending order (low -> medium -> high -> xhigh -> max)
                let allKnownEfforts = variantKeys.allSatisfy { effortOrder[$0] != nil }
                if allKnownEfforts {
                    variantKeys.sort { (effortOrder[$0] ?? 99) < (effortOrder[$1] ?? 99) }
                }

                // Choose sensible default variant: medium -> high -> first
                let defaultKey: String
                if variantMap["medium"] != nil {
                    defaultKey = "medium"
                } else if variantMap["high"] != nil {
                    defaultKey = "high"
                } else {
                    defaultKey = variantKeys.first ?? ""
                }
                let defaultId = variantMap[defaultKey] ?? first.id

                results.append(
                    RemoteModelInfo(
                        id: defaultId,
                        name: first.baseName,
                        ownedBy: "antigravity",
                        supportedEffortLevels: variantKeys,
                        defaultEffortLevel: defaultKey.isEmpty ? nil : defaultKey,
                        effortVariantModelIds: variantMap
                    )
                )
            } else {
                results.append(RemoteModelInfo(id: first.id, name: first.displayName, ownedBy: "antigravity"))
            }
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

    /// Terminates any currently running interactive `agy` UI subprocesses immediately (without killing concurrent LocalAPIServer requests).
    public func cancelCurrentProcess() {
        processLock.lock()
        let procs = Array(interactiveProcesses.values)
        interactiveProcesses.removeAll()
        processLock.unlock()

        for proc in procs where proc.isRunning {
            proc.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                if proc.isRunning {
                    kill(proc.processIdentifier, SIGKILL)
                }
            }
        }
    }

    private func terminateProcess(_ proc: Process) {
        guard proc.isRunning else { return }
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
        isInteractive: Bool = true,
        onEvent: @escaping @Sendable (AGYStreamEvent) -> Void
    ) async throws {
        guard let binaryPath = Self.resolveBinaryPath(customPath: customBinaryPath, portableRoot: portableRoot) else {
            throw NSError(
                domain: "AGYCLIRunner",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Antigravity CLI (`agy`) not found. Open Settings → Google Antigravity (AGY) and click 'Download AGY CLI' or select your AGY-Portable folder."]
            )
        }

        let runId = UUID()
        let procBox = AGYProcessBox()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    let proc = Process()
                    procBox.set(proc)
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

                    if isInteractive {
                        self.processLock.lock()
                        self.interactiveProcesses[runId] = proc
                        self.processLock.unlock()
                    }

                    do {
                        try proc.run()
                        proc.waitUntilExit()
                    } catch {
                        if isInteractive {
                            self.processLock.lock()
                            self.interactiveProcesses.removeValue(forKey: runId)
                            self.processLock.unlock()
                        }
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

                    if isInteractive {
                        self.processLock.lock()
                        self.interactiveProcesses.removeValue(forKey: runId)
                        self.processLock.unlock()
                    }

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
            if let proc = procBox.get() {
                self.terminateProcess(proc)
            }
        }
    }

    /// Checks `agy --version` against Google's live release manifest without downloading anything.
    public static func checkForCLIUpdate(binaryPath: String) async -> (installed: String, latest: String?, updateAvailable: Bool, error: String?) {
        let arch = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/uname")
                p.arguments = ["-m"]
                let pipe = Pipe()
                p.standardOutput = pipe
                try? p.run()
                p.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "arm64"
                cont.resume(returning: out)
            }
        }

        let installedVersion: String = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: binaryPath)
                p.arguments = ["--version"]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                try? p.run()
                p.waitUntilExit()
                let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                cont.resume(returning: raw)
            }
        }

        let manifestName = (arch == "arm64") ? "darwin_arm64.json" : "darwin_amd64.json"
        guard let url = URL(string: "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/\(manifestName)") else {
            return (installedVersion, nil, false, "Invalid manifest URL")
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let latest = json["version"] as? String, !latest.isEmpty {
                let isNewer = !installedVersion.isEmpty && installedVersion != latest
                return (installedVersion, latest, isNewer, nil)
            }
            return (installedVersion, nil, false, "Could not parse manifest")
        } catch {
            return (installedVersion, nil, false, error.localizedDescription)
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

/// Manages multiple Google Antigravity (AGY) OAuth account profiles using the exact same
/// `accounts/<name>/token` + `.active` layout as `AGY-Portable`, sharing credentials seamlessly
/// when an `AGY-Portable` folder is configured or storing them in `~/Library/Application Support/SparkBar/agy-accounts/`.
@MainActor
public final class AGYAccountManager: ObservableObject {
    public static let shared = AGYAccountManager()

    @Published public private(set) var accounts: [String] = []
    @Published public private(set) var activeAccount: String = ""
    @Published public private(set) var isSignedIn: Bool = false

    private init() {
        reload()
    }

    private func resolvedPaths(portableRoot: String) -> (accountsDir: URL, activeFile: URL, modernLiveTokenURL: URL, legacyLiveTokenURL: URL, cliStateURL: URL) {
        let fm = FileManager.default
        let trimmed = portableRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let root = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
            let dataRoot = root.appendingPathComponent("data", isDirectory: true)
            let accountsDir = dataRoot.appendingPathComponent("accounts", isDirectory: true)
            let activeFile = accountsDir.appendingPathComponent(".active")
            let geminiDir = dataRoot
                .appendingPathComponent("home", isDirectory: true)
                .appendingPathComponent(".gemini", isDirectory: true)
            let modernToken = geminiDir
                .appendingPathComponent("antigravity-cli", isDirectory: true)
                .appendingPathComponent("antigravity-oauth-token")
            let legacyToken = geminiDir.appendingPathComponent("jetski-standalone-oauth-token")
            let cliState = geminiDir
                .appendingPathComponent("antigravity-cli", isDirectory: true)
                .appendingPathComponent("jetski_state.pbtxt")
            return (accountsDir, activeFile, modernToken, legacyToken, cliState)
        }

        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let accountsDir = appSupport
            .appendingPathComponent("SparkBar", isDirectory: true)
            .appendingPathComponent("agy-accounts", isDirectory: true)
        let activeFile = accountsDir.appendingPathComponent(".active")
        let geminiDir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".gemini", isDirectory: true)
        let modernToken = geminiDir
            .appendingPathComponent("antigravity-cli", isDirectory: true)
            .appendingPathComponent("antigravity-oauth-token")
        let legacyToken = geminiDir.appendingPathComponent("jetski-standalone-oauth-token")
        let cliState = geminiDir
            .appendingPathComponent("antigravity-cli", isDirectory: true)
            .appendingPathComponent("jetski_state.pbtxt")
        return (accountsDir, activeFile, modernToken, legacyToken, cliState)
    }

    private func existingLiveTokenURL(in paths: (accountsDir: URL, activeFile: URL, modernLiveTokenURL: URL, legacyLiveTokenURL: URL, cliStateURL: URL)) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: paths.modernLiveTokenURL.path) {
            return paths.modernLiveTokenURL
        }
        if fm.fileExists(atPath: paths.legacyLiveTokenURL.path) {
            return paths.legacyLiveTokenURL
        }
        return nil
    }

    /// Detects the host Antigravity signed-in Google email from `~/Library/Application Support/Antigravity/app_storage.json`
    /// or standalone OAuth token files (never returns fake placeholder labels like "Host Account").
    private static func detectHostSignedInEmail() -> String? {
        let fm = FileManager.default
        let appStorage = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Antigravity/app_storage.json")
        if let email = extractEmail(from: appStorage) {
            return email
        }
        return nil
    }

    public func reload(portableRoot: String? = nil) {
        let root = portableRoot ?? SettingsStore.shared.agyPortableRootPath
        let paths = resolvedPaths(portableRoot: root)
        let fm = FileManager.default
        try? fm.createDirectory(at: paths.accountsDir, withIntermediateDirectories: true)

        let liveToken = existingLiveTokenURL(in: paths)
        let signedOutMarker = paths.accountsDir.appendingPathComponent(".signed_out")
        let dismissedFile = paths.accountsDir.appendingPathComponent(".dismissed")
        let explicitlySignedOut = fm.fileExists(atPath: signedOutMarker.path)
        let dismissedSet: Set<String> = {
            guard let raw = try? String(contentsOf: dismissedFile, encoding: .utf8) else { return [] }
            return Set(raw.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        }()

        let rawHostEmail = explicitlySignedOut ? nil : Self.detectHostSignedInEmail()
        let hostEmail = rawHostEmail.flatMap { dismissedSet.contains($0) ? nil : $0 }
        let hasHostSession = !explicitlySignedOut && ((liveToken != nil) || (hostEmail != nil) || (fm.fileExists(atPath: paths.cliStateURL.path) && dismissedSet.isEmpty))
        var discovered = listAccountNames(in: paths.accountsDir)

        // Auto-migrate existing standalone token file into an email-named profile if none saved yet
        if !explicitlySignedOut, let tokenURL = liveToken, discovered.isEmpty {
            let inferredName = Self.extractEmail(from: tokenURL) ?? hostEmail ?? "account"
            if !dismissedSet.contains(inferredName) {
                storeToken(from: tokenURL, as: inferredName, in: paths.accountsDir)
                writeActive(inferredName, to: paths.activeFile)
                discovered = [inferredName]
            }
        }

        // If signed in via host macOS Keychain / Antigravity app (and not explicitly removed by user),
        // include the detected email as the primary account
        if let email = hostEmail, !discovered.contains(email) {
            discovered.insert(email, at: 0)
        }

        let active = readActive(from: paths.activeFile)
        self.accounts = discovered
        if !active.isEmpty && discovered.contains(active) {
            self.activeAccount = active
        } else {
            self.activeAccount = discovered.first ?? ""
        }
        self.isSignedIn = !explicitlySignedOut && (hasHostSession || !discovered.isEmpty)
    }

    /// Best-effort extraction of an email address from a JSON, JWT, or Antigravity storage file.
    private static func extractEmail(from fileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let text = String(data: data, encoding: .utf8) else { return nil }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["email", "user_email", "account", "login"] {
                if let val = obj[key] as? String, val.contains("@") {
                    return val
                }
            }
        }
        let pattern = #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
        if let range = text.range(of: pattern, options: .regularExpression) {
            return String(text[range])
        }
        return nil
    }

    public func isRemovableAccount(_ name: String, portableRoot: String? = nil) -> Bool {
        let root = portableRoot ?? SettingsStore.shared.agyPortableRootPath
        let paths = resolvedPaths(portableRoot: root)
        let targetToken = paths.accountsDir.appendingPathComponent(name, isDirectory: true).appendingPathComponent("token")
        return FileManager.default.fileExists(atPath: targetToken.path)
    }

    public func switchAccount(to name: String, portableRoot: String? = nil) {
        let root = portableRoot ?? SettingsStore.shared.agyPortableRootPath
        let paths = resolvedPaths(portableRoot: root)
        let fm = FileManager.default

        let targetToken = paths.accountsDir.appendingPathComponent(name, isDirectory: true).appendingPathComponent("token")
        if !fm.fileExists(atPath: targetToken.path) {
            // Switching back to the host Keychain email session (no standalone token file override)
            if !activeAccount.isEmpty && isRemovableAccount(activeAccount, portableRoot: root),
               let liveURL = existingLiveTokenURL(in: paths) {
                storeToken(from: liveURL, as: activeAccount, in: paths.accountsDir)
            }
            try? fm.removeItem(at: paths.modernLiveTokenURL)
            try? fm.removeItem(at: paths.legacyLiveTokenURL)
            writeActive(name, to: paths.activeFile)
            reload(portableRoot: root)
            Task { await SettingsStore.shared.refreshModelsForCurrentProvider() }
            return
        }

        // Persist any refreshed live token back into the previously active profile before swapping
        if !activeAccount.isEmpty && isRemovableAccount(activeAccount, portableRoot: root),
           let liveURL = existingLiveTokenURL(in: paths) {
            storeToken(from: liveURL, as: activeAccount, in: paths.accountsDir)
        }

        // Load selected profile token into both modern (v1.5+) and legacy live token slots
        for liveSlot in [paths.modernLiveTokenURL, paths.legacyLiveTokenURL] {
            try? fm.createDirectory(at: liveSlot.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: liveSlot)
            try? fm.copyItem(at: targetToken, to: liveSlot)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: liveSlot.path)
        }

        writeActive(name, to: paths.activeFile)
        reload(portableRoot: root)

        Task {
            await SettingsStore.shared.refreshModelsForCurrentProvider()
        }
    }

    public func removeAccount(named name: String, portableRoot: String? = nil) {
        let root = portableRoot ?? SettingsStore.shared.agyPortableRootPath
        let paths = resolvedPaths(portableRoot: root)
        let fm = FileManager.default
        let dir = paths.accountsDir.appendingPathComponent(name, isDirectory: true)
        try? fm.removeItem(at: dir)

        // Record removed email in .dismissed so reload() never auto-reimports it from host Antigravity app_storage.json
        let dismissedFile = paths.accountsDir.appendingPathComponent(".dismissed")
        var dismissed = Set(
            ((try? String(contentsOf: dismissedFile, encoding: .utf8)) ?? "")
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        dismissed.insert(name)
        try? dismissed.sorted().joined(separator: "\n").write(to: dismissedFile, atomically: true, encoding: .utf8)

        let wasLast = accounts.count <= 1
        if activeAccount == name || wasLast {
            try? fm.removeItem(at: paths.activeFile)
            try? fm.removeItem(at: paths.modernLiveTokenURL)
            try? fm.removeItem(at: paths.legacyLiveTokenURL)
        }

        if wasLast {
            let signedOutMarker = paths.accountsDir.appendingPathComponent(".signed_out")
            try? "1".write(to: signedOutMarker, atomically: true, encoding: .utf8)
            reload(portableRoot: root)
            return
        }

        reload(portableRoot: root)
        if !activeAccount.isEmpty {
            switchAccount(to: activeAccount, portableRoot: root)
        }
    }

    /// Launches `agy` in Terminal.app with an isolated temp `$HOME` so the user can complete Google OAuth.
    /// Automatically detects the signed-in Google email from the OAuth token (no manual label required),
    /// saves the profile under that email, kills `agy`, closes the Terminal window, and focuses SparkBar.
    public func launchLoginInTerminal(accountName rawName: String = "", binaryPath: String, portableRoot: String? = nil) {
        let fallbackName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)

        let root = portableRoot ?? SettingsStore.shared.agyPortableRootPath
        let paths = resolvedPaths(portableRoot: root)
        let fm = FileManager.default
        try? fm.createDirectory(at: paths.accountsDir, withIntermediateDirectories: true)

        // Sync current active token back first
        if !activeAccount.isEmpty && isRemovableAccount(activeAccount, portableRoot: root),
           let liveURL = existingLiveTokenURL(in: paths) {
            storeToken(from: liveURL, as: activeAccount, in: paths.accountsDir)
        }

        let tempHome = fm.temporaryDirectory.appendingPathComponent("sparkbar_agy_login_\(UUID().uuidString.prefix(8))", isDirectory: true)
        let tempModernToken = tempHome.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
        let tempLegacyToken = tempHome.appendingPathComponent(".gemini/jetski-standalone-oauth-token")
        let scriptURL = fm.temporaryDirectory.appendingPathComponent("sparkbar_agy_login_\(UUID().uuidString.prefix(8)).command")
        let doneMarker = tempHome.appendingPathComponent(".sparkbar_done")

        let script = """
        #!/usr/bin/env bash
        clear
        echo "======================================================"
        echo "  SparkBar — Sign In with Google (AGY)"
        echo "======================================================"
        echo "Complete Google sign-in in your browser."
        echo "This window will close automatically once signed in."
        echo ""
        mkdir -p "\(tempHome.path)/.gemini/antigravity-cli"

        save_token_file() {
            local SRC="$1"
            local EMAIL
            EMAIL=$(grep -ahoE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}' "$SRC" "\(tempHome.path)/Library/Application Support/Antigravity/app_storage.json" 2>/dev/null | head -n1 || true)
            if [ -z "$EMAIL" ]; then
                EMAIL="\(fallbackName)"
            fi
            if [ -z "$EMAIL" ]; then
                EMAIL="account-$(date +%H%M%S)"
            fi
            local DEST_DIR="\(paths.accountsDir.path)/$EMAIL"
            mkdir -p "$DEST_DIR" "\(paths.modernLiveTokenURL.deletingLastPathComponent().path)" "\(paths.legacyLiveTokenURL.deletingLastPathComponent().path)"
            cp -f "$SRC" "$DEST_DIR/token"
            chmod 600 "$DEST_DIR/token"
            cp -f "$SRC" "\(paths.modernLiveTokenURL.path)"
            chmod 600 "\(paths.modernLiveTokenURL.path)"
            cp -f "$SRC" "\(paths.legacyLiveTokenURL.path)"
            chmod 600 "\(paths.legacyLiveTokenURL.path)"
            rm -f "\(paths.accountsDir.path)/.signed_out"
            if [ -f "\(paths.accountsDir.path)/.dismissed" ]; then
                grep -vxF "$EMAIL" "\(paths.accountsDir.path)/.dismissed" > "\(paths.accountsDir.path)/.dismissed.tmp" 2>/dev/null || true
                mv -f "\(paths.accountsDir.path)/.dismissed.tmp" "\(paths.accountsDir.path)/.dismissed" 2>/dev/null || true
            fi
            printf '%s\\r\\n' "$EMAIL" > "\(paths.activeFile.path)"
            touch "\(doneMarker.path)"
        }

        # Background token watcher: detects either modern v1.5+ or legacy OAuth token file immediately,
        # kills the foreground agy TUI so the user is never stuck in CLI mode, saves the profile, and closes Terminal.
        MAIN_SHELL_PID=$$
        (
            FOUND_TOKEN=""
            while [ -z "$FOUND_TOKEN" ]; do
                if [ -s "\(tempModernToken.path)" ]; then
                    FOUND_TOKEN="\(tempModernToken.path)"
                elif [ -s "\(tempLegacyToken.path)" ]; then
                    FOUND_TOKEN="\(tempLegacyToken.path)"
                else
                    sleep 0.25
                fi
            done
            sleep 0.4
            save_token_file "$FOUND_TOKEN"
            pkill -TERM -P "$MAIN_SHELL_PID" 2>/dev/null || true
            sleep 0.25
            pkill -KILL -P "$MAIN_SHELL_PID" 2>/dev/null || true
        ) &
        WATCHER_PID=$!

        # Run agy in the FOREGROUND so it owns the TTY if the user needs to paste an OAuth code
        HOME="\(tempHome.path)" "\(binaryPath)" || true
        kill "$WATCHER_PID" 2>/dev/null || true

        # Fallback save if token appeared right as user exited manually
        if [ ! -f "\(doneMarker.path)" ]; then
            if [ -s "\(tempModernToken.path)" ]; then
                save_token_file "\(tempModernToken.path)"
            elif [ -s "\(tempLegacyToken.path)" ]; then
                save_token_file "\(tempLegacyToken.path)"
            fi
        fi

        rm -rf "\(tempHome.path)"
        rm -f "\(scriptURL.path)"

        # Close this Terminal window automatically and return focus to SparkBar
        CURRENT_TTY=$(tty 2>/dev/null || true)
        if [ -n "$CURRENT_TTY" ]; then
            osascript -e "tell application \\"Terminal\\" to close (every window whose tty of selected tab is \\"$CURRENT_TTY\\")" >/dev/null 2>&1 &
        fi
        exit 0
        """

        try? script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let openProc = Process()
        openProc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProc.arguments = ["-a", "Terminal", scriptURL.path]
        try? openProc.run()

        // Poll briefly in background so SparkBar refreshes and regains focus automatically once login completes
        Task { @MainActor in
            for _ in 0..<240 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if !fm.fileExists(atPath: scriptURL.path) {
                    self.reload(portableRoot: root)
                    await SettingsStore.shared.refreshModelsForCurrentProvider()
                    NSApp.activate(ignoringOtherApps: true)
                    break
                }
            }
        }
    }

    private func listAccountNames(in dir: URL) -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items.compactMap { url in
            let tokenFile = url.appendingPathComponent("token")
            return fm.fileExists(atPath: tokenFile.path) ? url.lastPathComponent : nil
        }.sorted()
    }

    private func storeToken(from source: URL, as name: String, in accountsDir: URL) {
        let fm = FileManager.default
        let destDir = accountsDir.appendingPathComponent(name, isDirectory: true)
        let destToken = destDir.appendingPathComponent("token")
        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        try? fm.removeItem(at: destToken)
        try? fm.copyItem(at: source, to: destToken)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destToken.path)
    }

    private func readActive(from activeFile: URL) -> String {
        guard let str = try? String(contentsOf: activeFile, encoding: .utf8) else { return "" }
        return str.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func writeActive(_ name: String, to activeFile: URL) {
        let content = "\(name)\r\n"
        try? content.write(to: activeFile, atomically: true, encoding: .utf8)
    }
}
