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
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSRunningApplication.current.activate(options: [.activateAllWindows])
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
        DispatchQueue.main.async {
            if !self.isVisible && !FullScreenChatWindowController.shared.isVisible {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

public struct SettingsSheetView: View {
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var updater = GitHubUpdater.shared
    @ObservedObject private var agyAccounts = AGYAccountManager.shared
    @ObservedObject private var localAPI = LocalAPIServer.shared
    @State private var apiKeyInput: String = ""
    @State private var baseURLInput: String = ""
    @State private var localAPIPortInput: String = ""
    @State private var copiedEndpointLabel: String? = nil
    @State private var isRecordingHotkey: Bool = false
    @State private var hotkeyRecorderMonitor: Any? = nil
    @State private var showSavedToast: Bool = false
    @State private var isDownloadingAGY: Bool = false
    @State private var agyDownloadStatus: String = ""
    @State private var showRemoveAccountConfirm: Bool = false

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
                            ForEach(LLMProviderType.antigravityProviders) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                            Divider()
                            ForEach(LLMProviderType.apiProviders) { provider in
                                Text(provider.displayName).tag(provider)
                            }
                            Divider()
                            ForEach(LLMProviderType.localProviders) { provider in
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

                    // Compact Google Antigravity (AGY CLI) All-in-One Card
                    if settings.selectedProvider == .antigravity {
                        let hasBin = settings.resolvedAGYBinaryPath != nil
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(hasBin && agyAccounts.isSignedIn ? Color.green : Color.orange)
                                    .frame(width: 8, height: 8)
                                Text(hasBin ? (agyAccounts.isSignedIn ? "AGY · Signed In" : "AGY · Sign In Required") : "AGY · Not Installed")
                                    .font(.system(size: 12.5, weight: .medium))

                                Spacer()

                                if !hasBin {
                                    Button {
                                        downloadAndPromptLogin()
                                    } label: {
                                        HStack(spacing: 5) {
                                            if isDownloadingAGY { ProgressView().controlSize(.small) }
                                            Text(isDownloadingAGY ? "Downloading…" : "Download & Sign In")
                                                .font(.system(size: 11.5, weight: .medium))
                                        }
                                    }
                                    .controlSize(.small)
                                    .disabled(isDownloadingAGY)
                                } else if !agyAccounts.isSignedIn {
                                    Button("Sign In with Google") {
                                        if let bin = settings.resolvedAGYBinaryPath {
                                            agyAccounts.launchLoginInTerminal(binaryPath: bin)
                                        }
                                    }
                                    .controlSize(.small)
                                } else {
                                    Button {
                                        checkForAGYUpdate()
                                    } label: {
                                        HStack(spacing: 4) {
                                            if isDownloadingAGY { ProgressView().controlSize(.small) }
                                            Text(isDownloadingAGY ? "Checking…" : "Check for Updates")
                                                .font(.system(size: 11))
                                        }
                                    }
                                    .controlSize(.small)
                                    .disabled(isDownloadingAGY)
                                }
                            }

                            if hasBin && agyAccounts.isSignedIn {
                                HStack(spacing: 8) {
                                    Text("Account")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)

                                    Picker("Account", selection: Binding(
                                        get: { agyAccounts.activeAccount },
                                        set: { agyAccounts.switchAccount(to: $0) }
                                    )) {
                                        ForEach(agyAccounts.accounts, id: \.self) { name in
                                            Text(name).tag(name)
                                        }
                                    }
                                    .labelsHidden()
                                    .pickerStyle(.menu)
                                    .frame(maxWidth: 240)

                                    Spacer()

                                    Button {
                                        if let bin = settings.resolvedAGYBinaryPath {
                                            agyAccounts.launchLoginInTerminal(binaryPath: bin)
                                        }
                                    } label: {
                                        Image(systemName: "plus")
                                            .font(.system(size: 11, weight: .semibold))
                                    }
                                    .controlSize(.small)
                                    .help("Add another Google account")

                                    if !agyAccounts.activeAccount.isEmpty {
                                        Button {
                                            showRemoveAccountConfirm = true
                                        } label: {
                                            Image(systemName: "minus")
                                                .font(.system(size: 11, weight: .semibold))
                                        }
                                        .controlSize(.small)
                                        .help(agyAccounts.accounts.count <= 1 ? "Sign out & remove account" : "Remove selected account")
                                    }
                                }
                            }

                            if !agyDownloadStatus.isEmpty {
                                Text(agyDownloadStatus)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.75)
                        )
                    }

                    // API Key Field (required for cloud APIs, optional for Custom OpenAI-Compatible)
                    if settings.selectedProvider.requiresAPIKey || settings.selectedProvider == .custom {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(settings.selectedProvider == .custom
                                     ? "\(settings.selectedProvider.displayName) API Key (Optional)"
                                     : "\(settings.selectedProvider.displayName) API Key")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if !apiKeyInput.isEmpty {
                                    Text("Configured")
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

                                Button("Save") {
                                    saveCurrentProviderFields()
                                }
                            }
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

                    // Tools & Web Search
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Tools & Web Search")
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

                    // Local API Endpoint (Beta) — OpenAI / Anthropic / Ollama compatible
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text("Local API Endpoint")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)

                            Text("BETA")
                                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.14), in: Capsule())
                                .overlay(
                                    Capsule()
                                        .strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.75)
                                )

                            Spacer()

                            HStack(spacing: 5) {
                                Circle()
                                    .fill(localAPI.isRunning ? Color.green : Color.secondary.opacity(0.4))
                                    .frame(width: 7, height: 7)
                                Text(localAPI.isRunning ? "Listening on :\(localAPI.activePort)" : "Stopped")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Toggle("Expose OpenAI, Anthropic, Ollama, Gemini & llama.cpp on 127.0.0.1", isOn: $settings.enableLocalAPIServer)
                            .font(.system(size: 13))

                        HStack(spacing: 8) {
                            Text("Port")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)

                            TextField("11435", text: $localAPIPortInput)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(width: 84)
                                .onSubmit { applyLocalAPIPort() }

                            Button(localAPI.isRunning ? "Apply & Restart" : "Apply") {
                                applyLocalAPIPort()
                            }
                            .controlSize(.small)

                            Spacer()
                        }

                        if let err = localAPI.lastError, !err.isEmpty {
                            Text(err)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.orange)
                        }

                        if settings.enableLocalAPIServer {
                            let port = localAPI.isRunning ? localAPI.activePort : settings.localAPIServerPort
                            VStack(alignment: .leading, spacing: 6) {
                                endpointCopyRow(label: "OpenAI", url: "http://127.0.0.1:\(port)/v1")
                                endpointCopyRow(label: "Anthropic", url: "http://127.0.0.1:\(port)")
                                endpointCopyRow(label: "Ollama", url: "http://127.0.0.1:\(port)")
                                endpointCopyRow(label: "Gemini", url: "http://127.0.0.1:\(port)/v1beta")
                                endpointCopyRow(label: "llama.cpp", url: "http://127.0.0.1:\(port)/completion")

                                Divider().opacity(0.35).padding(.vertical, 2)

                                HStack(spacing: 8) {
                                    Text("Auth Key")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 66, alignment: .leading)

                                    SecureField("Optional Bearer token", text: $settings.localAPIServerToken)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(size: 11, design: .monospaced))

                                    Button("Generate") {
                                        settings.generateLocalAPIToken()
                                    }
                                    .controlSize(.small)

                                    if !settings.localAPIServerToken.isEmpty {
                                        Button {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(settings.localAPIServerToken, forType: .string)
                                            copiedEndpointLabel = "AuthKey"
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                                if copiedEndpointLabel == "AuthKey" { copiedEndpointLabel = nil }
                                            }
                                        } label: {
                                            Image(systemName: copiedEndpointLabel == "AuthKey" ? "checkmark" : "doc.on.doc")
                                                .font(.system(size: 10.5))
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Copy Bearer token")

                                        Button {
                                            settings.localAPIServerToken = ""
                                        } label: {
                                            Image(systemName: "xmark.circle")
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.borderless)
                                        .help("Clear token (open on localhost)")
                                    }
                                }
                            }
                            .padding(10)
                            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.75)
                            )
                        }
                    }

                    Divider()

                    // Window Behavior & Shortcut
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Window & Shortcut")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            Text("Global Toggle Shortcut:")
                                .font(.system(size: 12))

                            Button {
                                toggleHotkeyRecording()
                            } label: {
                                Text(isRecordingHotkey
                                     ? "Press shortcut… (Esc to cancel)"
                                     : HotkeyManager.displayString(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers))
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(isRecordingHotkey ? Color.accentColor : Color.primary)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 3.5)
                                    .background(
                                        (isRecordingHotkey ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.08)),
                                        in: RoundedRectangle(cornerRadius: 5)
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5)
                                            .strokeBorder(isRecordingHotkey ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                            .help("Click to record a custom global hotkey")

                            if settings.hotkeyKeyCode != 49 || settings.hotkeyModifiers != 2048 {
                                Button("Reset") {
                                    stopHotkeyRecording()
                                    settings.resetHotkeyToDefault()
                                }
                                .buttonStyle(.link)
                                .font(.system(size: 11))
                            }
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

                    Divider()

                    // Extra: Optional AGY-Portable USB Integration
                    DisclosureGroup("AGY-Portable Folder (Optional)") {
                        TextField("/Volumes/USB/AGY-Portable", text: $settings.agyPortableRootPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5, design: .monospaced))
                            .padding(.top, 4)
                            .onChange(of: settings.agyPortableRootPath) { _, newVal in
                                agyAccounts.reload(portableRoot: newVal)
                            }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
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
            localAPIPortInput = String(settings.localAPIServerPort)
            agyAccounts.reload()
        }
        .onDisappear {
            stopHotkeyRecording()
        }
        .alert(
            agyAccounts.accounts.count <= 1 ? "Sign Out & Remove Last Account?" : "Remove Account?",
            isPresented: $showRemoveAccountConfirm
        ) {
            Button("Cancel", role: .cancel) {}
            Button(agyAccounts.accounts.count <= 1 ? "Sign Out & Remove" : "Remove", role: .destructive) {
                agyAccounts.removeAccount(named: agyAccounts.activeAccount)
            }
        } message: {
            if agyAccounts.accounts.count <= 1 {
                Text("You are about to remove your last account (\(agyAccounts.activeAccount)). This will sign you out of AGY in SparkBar.")
            } else {
                Text("Remove \(agyAccounts.activeAccount) from SparkBar?")
            }
        }
    }

    private func loadFields(for provider: LLMProviderType) {
        apiKeyInput = settings.apiKey(for: provider)
        baseURLInput = settings.customEndpoints[provider.rawValue] ?? provider.defaultBaseURL
    }

    @ViewBuilder
    private func endpointCopyRow(label: String, url: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)

            Text(url)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)

            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                copiedEndpointLabel = label
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    if copiedEndpointLabel == label {
                        copiedEndpointLabel = nil
                    }
                }
            } label: {
                Image(systemName: copiedEndpointLabel == label ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10.5))
            }
            .buttonStyle(.borderless)
            .help("Copy \(label) base URL")
        }
    }

    private func applyLocalAPIPort() {
        let trimmed = localAPIPortInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(trimmed), parsed >= 1024, parsed <= 65535 else {
            localAPIPortInput = String(settings.localAPIServerPort)
            return
        }
        settings.localAPIServerPort = parsed
        if settings.enableLocalAPIServer {
            LocalAPIServer.shared.start(port: parsed)
        }
    }

    private func toggleHotkeyRecording() {
        if isRecordingHotkey {
            stopHotkeyRecording()
            return
        }
        isRecordingHotkey = true
        hotkeyRecorderMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = UInt32(event.keyCode)
            if code == 53 { // Escape cancels recording
                stopHotkeyRecording()
                return nil
            }
            let mods = HotkeyManager.carbonModifiers(from: event.modifierFlags)
            guard mods != 0 else { return nil } // Require at least one modifier key (⌥, ⌘, ⌃, or ⇧)
            settings.updateGlobalHotkey(keyCode: code, modifiers: mods)
            stopHotkeyRecording()
            return nil
        }
    }

    private func stopHotkeyRecording() {
        isRecordingHotkey = false
        if let mon = hotkeyRecorderMonitor {
            NSEvent.removeMonitor(mon)
            hotkeyRecorderMonitor = nil
        }
    }

    private func saveCurrentProviderFields() {
        if settings.selectedProvider.requiresAPIKey || settings.selectedProvider == .custom {
            settings.setAPIKey(apiKeyInput, for: settings.selectedProvider)
        }
        if settings.selectedProvider != .antigravity {
            settings.currentBaseURL = baseURLInput
        }
        showSavedToast = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            showSavedToast = false
        }
    }

    private func downloadAndPromptLogin() {
        guard !isDownloadingAGY else { return }
        isDownloadingAGY = true
        agyDownloadStatus = "Downloading AGY CLI…"
        Task { @MainActor in
            do {
                let path = try await AGYCLIRunner.downloadOfficialBinary { progress in
                    Task { @MainActor in agyDownloadStatus = progress }
                }
                agyAccounts.reload()
                if !agyAccounts.isSignedIn {
                    agyDownloadStatus = "Installed! Opening Google sign-in…"
                    agyAccounts.launchLoginInTerminal(binaryPath: path)
                } else {
                    await settings.refreshModelsForCurrentProvider()
                    agyDownloadStatus = "Signed in."
                }
            } catch {
                agyDownloadStatus = "Error: \(error.localizedDescription)"
            }
            isDownloadingAGY = false
        }
    }

    private func checkForAGYUpdate() {
        guard !isDownloadingAGY, let bin = settings.resolvedAGYBinaryPath else { return }
        isDownloadingAGY = true
        agyDownloadStatus = "Checking for AGY CLI updates…"
        Task { @MainActor in
            let check = await AGYCLIRunner.checkForCLIUpdate(binaryPath: bin)
            if let err = check.error {
                agyDownloadStatus = "Update check failed: \(err)"
            } else if !check.updateAvailable {
                let ver = check.installed.isEmpty ? (check.latest ?? "") : check.installed
                agyDownloadStatus = ver.isEmpty ? "Up to date." : "Up to date (v\(ver))."
            } else {
                agyDownloadStatus = "Updating v\(check.installed) → v\(check.latest ?? "latest")…"
                do {
                    _ = try await AGYCLIRunner.downloadOfficialBinary { progress in
                        Task { @MainActor in agyDownloadStatus = progress }
                    }
                    await settings.refreshModelsForCurrentProvider()
                    agyDownloadStatus = "Updated to v\(check.latest ?? "latest")."
                } catch {
                    agyDownloadStatus = "Error: \(error.localizedDescription)"
                }
            }
            isDownloadingAGY = false
        }
    }
}
