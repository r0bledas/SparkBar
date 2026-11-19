import SwiftUI
import AppKit

/// Standalone native macOS Settings window controller, completely independent of the floating prompt panel.
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
    public static let shared = SettingsWindowController()

    private var window: NSWindow?

    private override init() {
        super.init()
    }

    public var isVisible: Bool {
        window?.isVisible ?? false
    }

    public func showWindow() {
        if window == nil {
            let hostingController = NSHostingController(rootView: SettingsSheetView())
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 580, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = "SparkBar Settings"
            win.minSize = NSSize(width: 520, height: 520)
            win.contentViewController = hostingController
            win.isReleasedWhenClosed = false
            win.level = .normal
            win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            win.delegate = self
            win.center()
            self.window = win
        }

        ChatViewModel.shared.showSettings = true
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    public func closeWindow() {
        ChatViewModel.shared.showSettings = false
        window?.close()
    }

    public func windowWillClose(_ notification: Notification) {
        ChatViewModel.shared.showSettings = false
    }
}

public struct SettingsSheetView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var updater = GitHubUpdater.shared
    @State private var apiKeyInput: String = ""
    @State private var modelInput: String = ""
    @State private var baseURLInput: String = ""
    @State private var showSavedToast: Bool = false
    @State private var isDownloadingAGY: Bool = false
    @State private var agyDownloadStatus: String = ""

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                   let nsImage = NSImage(contentsOf: iconURL) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    Image(systemName: "bolt.horizontal.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.accentColor)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("SparkBar Settings")
                        .font(.system(size: 16, weight: .semibold))
                    Text("v\(updater.installedVersion) (\(updater.installedCommitSHA))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save & Close") {
                    saveCurrentProviderFields()
                    SettingsWindowController.shared.closeWindow()
                }
                .keyboardShortcut(.defaultAction)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Provider Picker (Default DeepSeek)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Default AI Provider")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)

                        Picker("Provider", selection: $settings.selectedProvider) {
                            ForEach(LLMProviderType.allCases) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .onChange(of: settings.selectedProvider) { _, newProvider in
                            loadFields(for: newProvider)
                        }

                        Toggle("Show AI Provider picker in the main floating bar", isOn: $settings.showProviderInMainBar)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    // Google Antigravity (AGY CLI) Zero-API-Key Setup Card
                    if settings.selectedProvider == .antigravity {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Google Antigravity (AGY CLI) — Google One Plan")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if settings.resolvedAGYBinaryPath != nil {
                                    Label("AGY CLI Ready (0 MB Idle)", systemImage: "checkmark.seal.fill")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.green)
                                } else {
                                    Label("Binary Not Found", systemImage: "exclamationmark.triangle.fill")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.orange)
                                }
                            }

                            Text("Uses your authenticated Google One / Antigravity login—no metered API key required. Spawns `agy` on-demand per turn and exits immediately (0 MB idle RAM).")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)

                            if let binPath = settings.resolvedAGYBinaryPath {
                                Text("Binary: \(binPath)")
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            HStack(spacing: 8) {
                                Button {
                                    downloadAGYBinary()
                                } label: {
                                    HStack(spacing: 6) {
                                        if isDownloadingAGY {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Image(systemName: "arrow.down.circle.fill")
                                        }
                                        Text(isDownloadingAGY ? "Downloading AGY CLI…" : (settings.resolvedAGYBinaryPath == nil ? "Download AGY CLI" : "Re-download / Update AGY CLI"))
                                            .font(.system(size: 12, weight: .medium))
                                    }
                                }
                                .disabled(isDownloadingAGY)

                                Button("Refresh AGY Models") {
                                    Task {
                                        await settings.refreshModelsForCurrentProvider()
                                        modelInput = settings.currentModel
                                    }
                                }
                                .disabled(isDownloadingAGY || settings.isFetchingModels)
                            }

                            if !agyDownloadStatus.isEmpty {
                                Text(agyDownloadStatus)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Optional AGY-Portable Folder (leave blank to use host ~/.gemini login)")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.secondary)
                                TextField("/Volumes/USB/AGY-Portable (optional)", text: $settings.agyPortableRootPath)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11.5, design: .monospaced))
                            }
                            .padding(.top, 2)
                        }
                        .padding(12)
                        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 0.75)
                        )
                    }

                    // API Key Field
                    if settings.selectedProvider.requiresAPIKey {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("\(settings.selectedProvider.displayName) API Key")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if !apiKeyInput.isEmpty {
                                    Label("Key Configured", systemImage: "checkmark.seal.fill")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.green)
                                }
                            }

                            HStack(spacing: 8) {
                                SecureField("sk-...", text: $apiKeyInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 12, design: .monospaced))
                                    .onSubmit {
                                        saveCurrentProviderFields()
                                    }

                                Button("Save & Fetch Models") {
                                    saveCurrentProviderFields()
                                }
                            }
                        }
                    }

                    // Dynamic API Models Selection
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Active Model (Dynamically Fetched from API `/models`)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                Task {
                                    await settings.refreshModelsForCurrentProvider()
                                    modelInput = settings.currentModel
                                }
                            } label: {
                                Label(settings.isFetchingModels ? "Fetching…" : "Refresh API Models", systemImage: "arrow.clockwise")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.link)
                        }

                        HStack(spacing: 8) {
                            TextField("Model ID (fetched from API)", text: $modelInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                .onChange(of: modelInput) { _, newValue in
                                    settings.currentModel = newValue
                                }

                            if !settings.availableModels.isEmpty {
                                Menu("API Models (\(settings.availableModels.count))") {
                                    ForEach(settings.availableModels) { m in
                                        Button(m.displayLabel) {
                                            modelInput = m.id
                                            settings.currentModel = m.id
                                        }
                                    }
                                }
                                .frame(width: 150)
                            }
                        }
                    }

                    // Reasoning Effort Level (Dynamically populated from API `/models`)
                    let levels = settings.supportedEffortLevelsForCurrentModel
                    if !levels.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Thinking Effort (Dynamic from API)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)

                            Picker("Thinking Effort", selection: $settings.reasoningEffort) {
                                ForEach(levels, id: \.self) { level in
                                    Text(settings.effortDisplayLabel(for: level)).tag(level)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }
                    }

                    // Endpoint URL (not needed for local AGY CLI)
                    if settings.selectedProvider != .antigravity {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("API Base URL")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("Reset Default") {
                                    baseURLInput = settings.selectedProvider.defaultBaseURL
                                    settings.currentBaseURL = baseURLInput
                                    Task {
                                        await settings.refreshModelsForCurrentProvider()
                                        modelInput = settings.currentModel
                                    }
                                }
                                .buttonStyle(.link)
                                .font(.system(size: 11))
                            }

                            TextField("https://api.deepseek.com/v1", text: $baseURLInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                .onChange(of: baseURLInput) { _, newValue in
                                    settings.currentBaseURL = newValue
                                }
                        }
                    }

                    Divider()

                    // Agent Tools & Capabilities (Hermes / OpenCode engine)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Agent Tools & Web Search (Hermes / OpenCode Engine)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)

                        Toggle("Enable Function Calling & Autonomous Tools", isOn: $settings.enableTools)
                            .font(.system(size: 13))

                        if settings.enableTools {
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle("Web Search & URL Reader (`web_search`, `fetch_url`)", isOn: $settings.enableWebSearchTool)
                                Toggle("Terminal Command Runner (`run_command`)", isOn: $settings.enableTerminalTool)
                                Toggle("File System Access (`read_file`, `write_file`, `list_directory`)", isOn: $settings.enableFileTools)
                                Toggle("Clipboard Integration (`clipboard`)", isOn: $settings.enableClipboardTool)
                            }
                            .font(.system(size: 12))
                            .padding(.leading, 14)
                        }

                        Toggle("Enable Server-Side Web Search", isOn: $settings.enableServerSideSearch)
                            .font(.system(size: 13))
                    }

                    Divider()

                    // Window Behavior & Shortcut
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Window & Shortcut")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)

                        HStack {
                            Text("Global Toggle Shortcut:")
                                .font(.system(size: 12))
                            Text("⌥ Space (Option + Space)")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                        }

                        Toggle("Keep window pinned when clicking outside", isOn: $settings.pinWindowOnBlur)
                            .font(.system(size: 13))

                        Toggle("Open SparkBar automatically on startup", isOn: $settings.openOnStartup)
                            .font(.system(size: 13))

                        Toggle("Show SparkBar icon in the menu bar", isOn: $settings.showMenuBarIcon)
                            .font(.system(size: 13))
                    }

                    Divider()

                    // Software Update from GitHub
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Updates & GitHub Sync")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                if let url = URL(string: GitHubUpdater.repoWebURL) {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                Label("r0bledas/SparkBar", systemImage: "arrow.up.right.square")
                                    .font(.system(size: 11, design: .monospaced))
                            }
                            .buttonStyle(.link)
                        }

                        HStack(spacing: 10) {
                            Button {
                                updater.performUpdateFromGitHub()
                            } label: {
                                HStack(spacing: 6) {
                                    if updater.isUpdating {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                                    }
                                    Text(updater.isUpdating ? "Updating & Rebuilding…" : "Update from GitHub")
                                        .font(.system(size: 12.5, weight: .medium))
                                }
                            }
                            .disabled(updater.isUpdating || updater.isChecking)

                            Button {
                                Task {
                                    await updater.checkLatestCommit()
                                }
                            } label: {
                                Text(updater.isChecking ? "Checking…" : "Check Latest Commit")
                                    .font(.system(size: 12))
                            }
                            .disabled(updater.isUpdating || updater.isChecking)
                        }

                        if !updater.statusMessage.isEmpty {
                            Text(updater.statusMessage)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(updater.isError ? Color.orange : Color.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.trailing, 4)
            }

            if showSavedToast {
                Text("Saved configuration & refreshed API models!")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.green)
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 580, maxWidth: .infinity, minHeight: 520, idealHeight: 620, maxHeight: .infinity)
        .onAppear {
            loadFields(for: settings.selectedProvider)
        }
    }

    private func loadFields(for provider: LLMProviderType) {
        apiKeyInput = settings.apiKey(for: provider)
        modelInput = settings.currentModel
        baseURLInput = settings.customEndpoints[provider.rawValue] ?? provider.defaultBaseURL
    }

    private func saveCurrentProviderFields() {
        if settings.selectedProvider.requiresAPIKey {
            settings.setAPIKey(apiKeyInput, for: settings.selectedProvider)
        }
        if !modelInput.isEmpty {
            settings.currentModel = modelInput
        }
        if settings.selectedProvider != .antigravity {
            settings.currentBaseURL = baseURLInput
        }
        showSavedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showSavedToast = false
        }
    }

    private func downloadAGYBinary() {
        guard !isDownloadingAGY else { return }
        isDownloadingAGY = true
        agyDownloadStatus = "Starting download…"
        Task { @MainActor in
            do {
                let path = try await AGYCLIRunner.downloadOfficialBinary { progress in
                    Task { @MainActor in
                        agyDownloadStatus = progress
                    }
                }
                agyDownloadStatus = "Installed at \(path). Fetching models…"
                await settings.refreshModelsForCurrentProvider()
                modelInput = settings.currentModel
                agyDownloadStatus = "Ready! Loaded \(settings.availableModels.count) models."
            } catch {
                agyDownloadStatus = "Error: \(error.localizedDescription)"
            }
            isDownloadingAGY = false
        }
    }
}
