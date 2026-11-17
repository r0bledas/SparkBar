import Foundation

public struct EnvironmentManifest: Codable, Equatable {
    public var osVersion: String
    public var arch: String
    public var shell: String
    public var capturedPath: String
    public var homebrewBinMtime: TimeInterval?
    public var tools: [String: String?]
    public var notes: [String]
    public var generatedAt: Date

    public func toSystemPromptSummary(sessionWorkspace: String, currentCwd: String) -> String {
        let installed = tools.compactMap { key, val -> String? in
            guard let v = val else { return nil }
            return "\(key)=\(v)"
        }.sorted().joined(separator: ", ")

        let missing = tools.compactMap { key, val -> String? in
            val == nil ? key : nil
        }.sorted().joined(separator: ", ")

        return """
        ## Host Environment Manifest (Verified & Pre-Probed — Do NOT waste calls re-probing)
        - **OS**: \(osVersion) (\(arch))
        - **Shell**: \(shell) (persistent `cwd` and `env` across `run_command` calls)
        - **Session Workspace**: `\(sessionWorkspace)`
        - **Current Working Directory (`cwd`)**: `\(currentCwd)`
        - **Active PATH**: `\(capturedPath)`
        - **Installed CLI Tools**: \(installed.isEmpty ? "standard POSIX utilities" : installed)
        - **Not Installed**: \(missing.isEmpty ? "none" : missing)
        - **Built-in Native Tools**:
          - `render_pdf`: First-class HTML/Markdown to PDF generator (uses native WebKit + PDFKit verification in 1 call). Prefer `render_pdf` over shell pipelines.
          - `pdf_info`: Uses native macOS `PDFKit.PDFDocument` to read exact `pageCount`, dimensions, and text preview (do NOT use `mdls` for page count on new files, as Spotlight indexing is asynchronous).
          - `sparkbar-tools`: Precompiled CLI helper on `PATH` supporting `sparkbar-tools html2pdf <in.html> <out.pdf>`, `sparkbar-tools pdf-info <file.pdf>`, and `sparkbar-tools file-verify <path>`.
          - `run_command`: 30s synchronous window with automatic promotion to a tracked background job (`job_id`) if still running, plus `job_status`, `job_output`, and `job_cancel`.
        - **Platform Notes**:
          - \(notes.joined(separator: "\n  - "))
        """
    }
}

public final class EnvironmentProbe: @unchecked Sendable {
    public static let shared = EnvironmentProbe()

    private let lock = NSLock()
    private var cachedManifest: EnvironmentManifest?

    public static let defaultFallbackPath = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

    public var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("SparkBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public var helperBinDirectory: URL {
        let binDir = appSupportDirectory.appendingPathComponent("bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        return binDir
    }

    private var manifestFileURL: URL {
        appSupportDirectory.appendingPathComponent("env_manifest.json")
    }

    private init() {
        installCLISymlinkIfNeeded()
        if let loaded = loadCachedManifestFromDisk(), !isCacheStale(loaded) {
            self.cachedManifest = loaded
        }
    }

    public func currentManifest() -> EnvironmentManifest {
        lock.lock()
        if let existing = cachedManifest {
            lock.unlock()
            return existing
        }
        lock.unlock()

        let fresh = buildManifestSynchronously()
        lock.lock()
        cachedManifest = fresh
        lock.unlock()
        saveManifestToDisk(fresh)
        return fresh
    }

    public func refreshAsync() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            self.installCLISymlinkIfNeeded()
            let fresh = self.buildManifestSynchronously()
            self.lock.lock()
            self.cachedManifest = fresh
            self.lock.unlock()
            self.saveManifestToDisk(fresh)
        }
    }

    public var effectivePath: String {
        lock.lock()
        let path = cachedManifest?.capturedPath
        lock.unlock()
        if let path = path, !path.isEmpty {
            return path
        }
        return "\(helperBinDirectory.path):\(Self.defaultFallbackPath)"
    }

    public func installCLISymlinkIfNeeded() {
        let symlinkURL = helperBinDirectory.appendingPathComponent("sparkbar-tools")
        let execPath = Bundle.main.executablePath ?? ProcessInfo.processInfo.arguments.first ?? "/Applications/SparkBar.app/Contents/MacOS/SparkBar"
        let wrapperScript = """
        #!/bin/zsh
        exec "\(execPath)" --cli "$@"
        """
        try? wrapperScript.write(to: symlinkURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: symlinkURL.path)
    }

    private func isCacheStale(_ manifest: EnvironmentManifest) -> Bool {
        let currentMtime = homebrewDirectoryMtime()
        if manifest.homebrewBinMtime != currentMtime {
            return true
        }
        if Date().timeIntervalSince(manifest.generatedAt) > 86_400 {
            return true
        }
        return false
    }

    private func homebrewDirectoryMtime() -> TimeInterval? {
        for candidate in ["/opt/homebrew/bin", "/usr/local/bin"] {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: candidate),
               let modDate = attrs[.modificationDate] as? Date {
                return modDate.timeIntervalSince1970
            }
        }
        return nil
    }

    private func loadCachedManifestFromDisk() -> EnvironmentManifest? {
        guard let data = try? Data(contentsOf: manifestFileURL),
              let decoded = try? JSONDecoder().decode(EnvironmentManifest.self, from: data) else {
            return nil
        }
        return decoded
    }

    private func saveManifestToDisk(_ manifest: EnvironmentManifest) {
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestFileURL, options: .atomic)
        }
    }

    private func buildManifestSynchronously() -> EnvironmentManifest {
        let loginPath = captureLoginShellPath(timeoutSeconds: 3.0)
        let helperBin = helperBinDirectory.path
        var pathComponents: [String] = [helperBin]
        for part in (loginPath + ":" + Self.defaultFallbackPath).components(separatedBy: ":") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !pathComponents.contains(trimmed) {
                pathComponents.append(trimmed)
            }
        }
        let finalPath = pathComponents.joined(separator: ":")

        let candidates = [
            "brew", "node", "npm", "python3", "pip3", "swift", "git", "gh",
            "docker", "ffmpeg", "pandoc", "typst", "wkhtmltopdf", "rg", "jq", "cupsfilter"
        ]

        var toolsMap: [String: String?] = [:]
        for tool in candidates {
            toolsMap[tool] = resolveExecutable(named: tool, inPath: finalPath)
        }

        let osVer = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "macOS \(osVer.majorVersion).\(osVer.minorVersion).\(osVer.patchVersion)"

        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif

        return EnvironmentManifest(
            osVersion: osString,
            arch: arch,
            shell: "/bin/zsh",
            capturedPath: finalPath,
            homebrewBinMtime: homebrewDirectoryMtime(),
            tools: toolsMap,
            notes: [
                "cupsfilter only supports text/plain and image formats, NOT text/html.",
                "Use the built-in `render_pdf` tool (or `sparkbar-tools html2pdf`) for instant HTML/Markdown to PDF conversion via WebKit.",
                "Use `pdf_info` (or `sparkbar-tools pdf-info`) to verify PDF page count and metadata via PDFKit instead of `mdls`."
            ],
            generatedAt: Date()
        )
    }

    private func captureLoginShellPath(timeoutSeconds: TimeInterval) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "print -r -- \"__SPARKBAR_PATH_START__${PATH}__SPARKBAR_PATH_END__\""]

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
            let group = DispatchGroup()
            group.enter()
            process.terminationHandler = { _ in
                group.leave()
            }
            if group.wait(timeout: .now() + timeoutSeconds) == .timedOut {
                process.terminate()
                return Self.defaultFallbackPath
            }
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            if let startRange = output.range(of: "__SPARKBAR_PATH_START__"),
               let endRange = output.range(of: "__SPARKBAR_PATH_END__"),
               startRange.upperBound <= endRange.lowerBound {
                let extracted = String(output[startRange.upperBound..<endRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !extracted.isEmpty {
                    return extracted
                }
            }
        } catch {
            return Self.defaultFallbackPath
        }
        return Self.defaultFallbackPath
    }

    private func resolveExecutable(named name: String, inPath pathString: String) -> String? {
        for dir in pathString.components(separatedBy: ":") where !dir.isEmpty {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
