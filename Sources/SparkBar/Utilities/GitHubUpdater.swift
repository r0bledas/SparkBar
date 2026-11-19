import Foundation
import AppKit

/// Self-updater that checks `https://github.com/r0bledas/SparkBar.git` (`main` branch),
/// pulls the latest source code, builds a fresh Release `.app` bundle, installs it to
/// `/Applications/SparkBar.app`, and relaunches SparkBar automatically.
@MainActor
public final class GitHubUpdater: ObservableObject {
    public static let shared = GitHubUpdater()

    public static let repoURL = "https://github.com/r0bledas/SparkBar.git"
    public static let repoWebURL = "https://github.com/r0bledas/SparkBar"

    @Published public var isUpdating: Bool = false
    @Published public var isChecking: Bool = false
    @Published public var statusMessage: String = ""
    @Published public var isError: Bool = false
    @Published public var remoteCommitSHA: String? = nil

    public var installedVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.5.11"
    }

    public var installedCommitSHA: String {
        if let sha = Bundle.main.infoDictionary?["GitCommitSHA"] as? String, !sha.isEmpty, sha != "unknown" {
            return sha
        }
        return "dev"
    }

    private init() {}

    /// Checks the latest commit on `origin/main` from GitHub without modifying the local installation.
    public func checkLatestCommit() async {
        guard !isChecking && !isUpdating else { return }
        isChecking = true
        isError = false
        statusMessage = "Checking GitHub (\(Self.repoWebURL))…"

        let result = await Self.runShellCommand("git ls-remote \(Self.repoURL) refs/heads/main")
        isChecking = false

        if result.exitCode == 0,
           let firstToken = result.output.split(whereSeparator: { $0.isWhitespace }).first {
            let fullSHA = String(firstToken)
            let shortSHA = String(fullSHA.prefix(7))
            remoteCommitSHA = shortSHA
            let current = installedCommitSHA
            if current != "dev" && current == shortSHA {
                statusMessage = "Up to date with GitHub main (\(shortSHA))."
            } else {
                statusMessage = "Latest GitHub commit on main: \(shortSHA) (installed: \(current))."
            }
        } else {
            isError = true
            statusMessage = "Failed to reach GitHub: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }

    /// Pulls the latest `main` branch from GitHub, builds a Release `.app` bundle, installs it into `/Applications/SparkBar.app`, and relaunches.
    public func performUpdateFromGitHub() {
        guard !isUpdating else { return }
        isUpdating = true
        isError = false
        statusMessage = "Fetching latest source from GitHub…"

        Task { @MainActor in
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let buildCacheDir = appSupport.appendingPathComponent("SparkBar/github-build-cache", isDirectory: true)
            let parentDir = buildCacheDir.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

            // Step 1: Clone or fetch latest main branch
            let gitDir = buildCacheDir.appendingPathComponent(".git")
            let syncCmd: String
            if FileManager.default.fileExists(atPath: gitDir.path) {
                syncCmd = """
                cd "\(buildCacheDir.path)" && git remote set-url origin "\(Self.repoURL)" && git fetch origin main --depth=1 && git reset --hard origin/main && git clean -fdx -e .build
                """
            } else {
                syncCmd = """
                rm -rf "\(buildCacheDir.path)" && git clone --depth=1 --branch main "\(Self.repoURL)" "\(buildCacheDir.path)"
                """
            }

            let syncResult = await Self.runShellCommand(syncCmd)
            guard syncResult.exitCode == 0 else {
                self.isUpdating = false
                self.isError = true
                self.statusMessage = "Git sync failed: \(syncResult.output.trimmingCharacters(in: .whitespacesAndNewlines))"
                return
            }

            // Read the fetched commit SHA
            let shaResult = await Self.runShellCommand("cd \"\(buildCacheDir.path)\" && git rev-parse --short HEAD")
            let latestSHA = shaResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !latestSHA.isEmpty {
                self.remoteCommitSHA = latestSHA
            }

            // Step 2: Build Release bundle via Scripts/package_app.sh
            self.statusMessage = "Building SparkBar Release (\(latestSHA.isEmpty ? "main" : latestSHA))… This takes ~10–15s."
            let buildCmd = """
            cd "\(buildCacheDir.path)" && chmod +x Scripts/package_app.sh && ./Scripts/package_app.sh "\(self.installedVersion)"
            """
            let buildResult = await Self.runShellCommand(buildCmd)
            guard buildResult.exitCode == 0 else {
                self.isUpdating = false
                self.isError = true
                self.statusMessage = "Build failed: \(buildResult.output.suffix(300))"
                return
            }

            let builtBundlePath = buildCacheDir.appendingPathComponent("dist/SparkBar.app").path
            guard FileManager.default.fileExists(atPath: builtBundlePath) else {
                self.isUpdating = false
                self.isError = true
                self.statusMessage = "Build finished, but dist/SparkBar.app was not found."
                return
            }

            // Step 3: Determine target installation path (/Applications/SparkBar.app or active bundle path)
            let currentBundlePath = Bundle.main.bundleURL.path
            let targetAppPath: String
            if currentBundlePath.hasSuffix(".app") && FileManager.default.isWritableFile(atPath: (currentBundlePath as NSString).deletingLastPathComponent) {
                targetAppPath = currentBundlePath
            } else {
                targetAppPath = "/Applications/SparkBar.app"
            }

            self.statusMessage = "Installing update to \(targetAppPath) and relaunching…"
            ChatViewModel.shared.persistCurrentSession()

            let currentPID = ProcessInfo.processInfo.processIdentifier
            let installAndRelaunchScript = """
            (
                sleep 0.4
                kill -9 \(currentPID) 2>/dev/null || true
                rm -rf "\(targetAppPath)"
                cp -R "\(builtBundlePath)" "\(targetAppPath)"
                if [ "\(targetAppPath)" != "/Applications/SparkBar.app" ] && [ -w "/Applications" ]; then
                    rm -rf "/Applications/SparkBar.app"
                    cp -R "\(builtBundlePath)" "/Applications/SparkBar.app"
                fi
                open "\(targetAppPath)"
            ) >/dev/null 2>&1 &
            """

            _ = await Self.runShellCommand(installAndRelaunchScript)
            NSApplication.shared.terminate(nil)
        }
    }

    private static func runShellCommand(_ command: String) async -> (output: String, exitCode: Int32) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-l", "-c", command]

                var env = ProcessInfo.processInfo.environment
                env["PATH"] = EnvironmentProbe.defaultFallbackPath
                process.environment = env

                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: (output, process.terminationStatus))
                } catch {
                    continuation.resume(returning: (error.localizedDescription, -1))
                }
            }
        }
    }
}
