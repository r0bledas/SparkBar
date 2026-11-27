import Foundation
import Combine
import ServiceManagement

@MainActor
public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()

    @Published public var selectedProvider: LLMProviderType {
        didSet {
            UserDefaults.standard.set(selectedProvider.rawValue, forKey: "sparkbar.selectedProvider")
            if let cachedData = UserDefaults.standard.data(forKey: "sparkbar.cachedModels.\(selectedProvider.rawValue)"),
               let cached = try? JSONDecoder().decode([RemoteModelInfo].self, from: cachedData) {
                self.availableModels = cached
            } else {
                self.availableModels = []
            }
            Task {
                await refreshModelsForCurrentProvider()
            }
        }
    }

    /// Stores the active model ID per provider (dynamically populated from the API `/models` endpoint)
    @Published public var selectedModels: [String: String] {
        didSet {
            UserDefaults.standard.set(selectedModels, forKey: "sparkbar.selectedModels")
            syncEffortLevelWithCurrentModel()
        }
    }

    /// Dynamically fetched models from `GET /models` for the active provider
    @Published public var availableModels: [RemoteModelInfo] = []

    /// Active reasoning effort level (e.g. "low", "high", "max") discovered from the model's API metadata
    @Published public var reasoningEffort: String {
        didSet {
            UserDefaults.standard.set(reasoningEffort, forKey: "sparkbar.reasoningEffort")
        }
    }

    @Published public var isFetchingModels: Bool = false

    /// Option in Settings to show or hide the AI Provider selector in the main floating bar (defaults to false so DeepSeek-only workflow is clean)
    @Published public var showProviderInMainBar: Bool {
        didSet {
            UserDefaults.standard.set(showProviderInMainBar, forKey: "sparkbar.showProviderInMainBar")
        }
    }

    @Published public var customEndpoints: [String: String] {
        didSet {
            UserDefaults.standard.set(customEndpoints, forKey: "sparkbar.customEndpoints")
        }
    }

    @Published public var systemPrompt: String {
        didSet {
            UserDefaults.standard.set(systemPrompt, forKey: "sparkbar.systemPrompt")
        }
    }

    @Published public var enableTools: Bool {
        didSet {
            UserDefaults.standard.set(enableTools, forKey: "sparkbar.enableTools")
        }
    }

    @Published public var enableWebSearchTool: Bool {
        didSet {
            UserDefaults.standard.set(enableWebSearchTool, forKey: "sparkbar.enableWebSearchTool")
        }
    }

    @Published public var enableTerminalTool: Bool {
        didSet {
            UserDefaults.standard.set(enableTerminalTool, forKey: "sparkbar.enableTerminalTool")
        }
    }

    @Published public var enableFileTools: Bool {
        didSet {
            UserDefaults.standard.set(enableFileTools, forKey: "sparkbar.enableFileTools")
        }
    }

    @Published public var enableClipboardTool: Bool {
        didSet {
            UserDefaults.standard.set(enableClipboardTool, forKey: "sparkbar.enableClipboardTool")
        }
    }

    @Published public var enableServerSideSearch: Bool {
        didSet {
            UserDefaults.standard.set(enableServerSideSearch, forKey: "sparkbar.enableServerSideSearch")
        }
    }

    @Published public var pinWindowOnBlur: Bool {
        didSet {
            UserDefaults.standard.set(pinWindowOnBlur, forKey: "sparkbar.pinWindowOnBlur")
        }
    }

    @Published public var openOnStartup: Bool {
        didSet {
            UserDefaults.standard.set(openOnStartup, forKey: "sparkbar.openOnStartup")
            updateLaunchAtLogin(enabled: openOnStartup)
        }
    }

    @Published public var showMenuBarIcon: Bool {
        didSet {
            UserDefaults.standard.set(showMenuBarIcon, forKey: "sparkbar.showMenuBarIcon")
            NotificationCenter.default.post(name: NSNotification.Name("SparkBarMenuBarVisibilityChanged"), object: nil)
        }
    }

    @Published public var temperature: Double {
        didSet {
            UserDefaults.standard.set(temperature, forKey: "sparkbar.temperature")
        }
    }

    /// Optional custom path to the `agy` CLI binary (if empty, auto-discovers AGY-Portable, SparkBar bin, or system PATH).
    @Published public var agyCustomBinaryPath: String {
        didSet {
            UserDefaults.standard.set(agyCustomBinaryPath, forKey: "sparkbar.agyCustomBinaryPath")
        }
    }

    /// Optional path to an `AGY-Portable` root folder to isolate `$HOME` and read portable Google credentials from `data/home`.
    @Published public var agyPortableRootPath: String {
        didSet {
            UserDefaults.standard.set(agyPortableRootPath, forKey: "sparkbar.agyPortableRootPath")
        }
    }

    /// Beta local HTTP API endpoint (OpenAI / Anthropic / Ollama compatible) bound to 127.0.0.1.
    @Published public var enableLocalAPIServer: Bool {
        didSet {
            UserDefaults.standard.set(enableLocalAPIServer, forKey: "sparkbar.enableLocalAPIServer")
            if enableLocalAPIServer {
                LocalAPIServer.shared.start(port: localAPIServerPort)
            } else {
                LocalAPIServer.shared.stop()
            }
        }
    }

    /// Port for the Beta local HTTP API server (default 11435).
    @Published public var localAPIServerPort: Int {
        didSet {
            UserDefaults.standard.set(localAPIServerPort, forKey: "sparkbar.localAPIServerPort")
        }
    }

    /// Optional Bearer / API key required by the Beta Local API server (empty = open on 127.0.0.1).
    @Published public var localAPIServerToken: String {
        didSet {
            UserDefaults.standard.set(localAPIServerToken, forKey: "sparkbar.localAPIServerToken")
        }
    }

    /// Custom global toggle hotkey (defaults to Option + Space: keyCode 49, modifiers 2048).
    @Published public var hotkeyKeyCode: UInt32 {
        didSet {
            UserDefaults.standard.set(Int(hotkeyKeyCode), forKey: "sparkbar.hotkeyKeyCode")
            HotkeyManager.shared.registerHotkey(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers)
        }
    }

    @Published public var hotkeyModifiers: UInt32 {
        didSet {
            UserDefaults.standard.set(Int(hotkeyModifiers), forKey: "sparkbar.hotkeyModifiers")
            HotkeyManager.shared.registerHotkey(keyCode: hotkeyKeyCode, modifiers: hotkeyModifiers)
        }
    }

    public func updateGlobalHotkey(keyCode: UInt32, modifiers: UInt32) {
        self.hotkeyKeyCode = keyCode
        self.hotkeyModifiers = modifiers
    }

    public func resetHotkeyToDefault() {
        updateGlobalHotkey(keyCode: 49, modifiers: 2048) // Option + Space
    }

    public func generateLocalAPIToken() {
        let raw = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        self.localAPIServerToken = "sb-\(raw)"
    }

    public var resolvedAGYBinaryPath: String? {
        AGYCLIRunner.resolveBinaryPath(customPath: agyCustomBinaryPath, portableRoot: agyPortableRootPath)
    }

    private init() {
        let defaults = UserDefaults.standard
        let providerRaw = defaults.string(forKey: "sparkbar.selectedProvider") ?? LLMProviderType.deepseek.rawValue
        self.selectedProvider = LLMProviderType(rawValue: providerRaw) ?? .deepseek

        self.selectedModels = (defaults.dictionary(forKey: "sparkbar.selectedModels") as? [String: String]) ?? [:]

        if let savedEndpoints = defaults.dictionary(forKey: "sparkbar.customEndpoints") as? [String: String] {
            self.customEndpoints = savedEndpoints
        } else {
            var initialEndpoints: [String: String] = [:]
            for provider in LLMProviderType.allCases {
                initialEndpoints[provider.rawValue] = provider.defaultBaseURL
            }
            self.customEndpoints = initialEndpoints
        }

        self.reasoningEffort = defaults.string(forKey: "sparkbar.reasoningEffort") ?? "default"
        self.showProviderInMainBar = defaults.object(forKey: "sparkbar.showProviderInMainBar") as? Bool ?? false

        self.systemPrompt = defaults.string(forKey: "sparkbar.systemPrompt") ?? """
        You are an AI assistant running inside SparkBar, an ultra-fast, lightweight native macOS Spotlight launcher (⌥ + Space).
        You are primarily a live web-search and quick-answer bot: whenever tools are enabled and the user asks about factual topics, app features, how-to questions, live events, or anything that may have changed, ALWAYS run `web_search` first instead of guessing from memory.
        Keep answers short, direct, and formatted in clean Markdown.
        """

        self.enableTools = defaults.object(forKey: "sparkbar.enableTools") as? Bool ?? true
        self.enableWebSearchTool = defaults.object(forKey: "sparkbar.enableWebSearchTool") as? Bool ?? true
        self.enableTerminalTool = defaults.object(forKey: "sparkbar.enableTerminalTool") as? Bool ?? true
        self.enableFileTools = defaults.object(forKey: "sparkbar.enableFileTools") as? Bool ?? true
        self.enableClipboardTool = defaults.object(forKey: "sparkbar.enableClipboardTool") as? Bool ?? true
        self.enableServerSideSearch = defaults.object(forKey: "sparkbar.enableServerSideSearch") as? Bool ?? true
        self.pinWindowOnBlur = defaults.object(forKey: "sparkbar.pinWindowOnBlur") as? Bool ?? false
        self.openOnStartup = defaults.object(forKey: "sparkbar.openOnStartup") as? Bool ?? false
        self.showMenuBarIcon = defaults.object(forKey: "sparkbar.showMenuBarIcon") as? Bool ?? true
        self.temperature = defaults.object(forKey: "sparkbar.temperature") as? Double ?? 0.3
        self.agyCustomBinaryPath = defaults.string(forKey: "sparkbar.agyCustomBinaryPath") ?? ""
        self.agyPortableRootPath = defaults.string(forKey: "sparkbar.agyPortableRootPath") ?? ""
        self.enableLocalAPIServer = defaults.object(forKey: "sparkbar.enableLocalAPIServer") as? Bool ?? false
        let savedPort = defaults.integer(forKey: "sparkbar.localAPIServerPort")
        self.localAPIServerPort = (savedPort >= 1024 && savedPort <= 65535) ? savedPort : 11435
        self.localAPIServerToken = defaults.string(forKey: "sparkbar.localAPIServerToken") ?? ""
        let savedKeyCode = defaults.object(forKey: "sparkbar.hotkeyKeyCode") as? Int
        let savedMods = defaults.object(forKey: "sparkbar.hotkeyModifiers") as? Int
        self.hotkeyKeyCode = UInt32(savedKeyCode ?? 49)
        self.hotkeyModifiers = UInt32(savedMods ?? 2048)

        // Hydrate cached model metadata immediately for zero-flash startup
        if let cachedData = defaults.data(forKey: "sparkbar.cachedModels.\(self.selectedProvider.rawValue)"),
           let cached = try? JSONDecoder().decode([RemoteModelInfo].self, from: cachedData) {
            self.availableModels = cached
        }

        bootstrapLocalKeysIfNeeded()

        Task {
            await refreshModelsForCurrentProvider()
        }
    }

    public var currentModel: String {
        get {
            if let saved = selectedModels[selectedProvider.rawValue], !saved.isEmpty {
                // Verify saved model exists in availableModels (directly or as a grouped effort variant)
                if availableModels.isEmpty || availableModels.contains(where: {
                    $0.id == saved || ($0.effortVariantModelIds?.values.contains(saved) ?? false)
                }) {
                    return saved
                }
            }
            return availableModels.first?.id ?? ""
        }
        set {
            selectedModels[selectedProvider.rawValue] = newValue
        }
    }

    public var currentModelInfo: RemoteModelInfo? {
        availableModels.first(where: {
            $0.id == currentModel || ($0.effortVariantModelIds?.values.contains(currentModel) ?? false)
        }) ?? availableModels.first
    }

    /// The exact backend model ID to pass to the API or `agy --model`, resolving any grouped effort/variant IDs.
    public var effectiveModelIdForExecution: String {
        currentModelInfo?.resolvedModelId(forEffort: reasoningEffort) ?? currentModel
    }

    public var supportedEffortLevelsForCurrentModel: [String] {
        guard let info = currentModelInfo else { return [] }
        var levels: [String] = (info.effortVariantModelIds != nil) ? ["default"] : ["none", "default"]
        for lvl in info.supportedEffortLevels where !levels.contains(lvl.lowercased()) {
            levels.append(lvl)
        }
        return levels
    }

    public var dynamicModelEffortLevelsOnly: [String] {
        guard let info = currentModelInfo else { return [] }
        return info.supportedEffortLevels.filter { $0.lowercased() != "none" && $0.lowercased() != "default" }
    }

    public func effortDisplayLabel(for level: String) -> String {
        switch level.lowercased() {
        case "none":
            return "None"
        case "default":
            if let def = currentModelInfo?.defaultEffortLevel, !def.isEmpty {
                return "Default (\(Self.prettyEffortToken(def)))"
            }
            return "Default"
        default:
            return Self.prettyEffortToken(level)
        }
    }

    private static func prettyEffortToken(_ token: String) -> String {
        switch token.lowercased() {
        case "xhigh": return "XHigh"
        case "xlow": return "XLow"
        default: return token.capitalized
        }
    }

    public var effectiveReasoningEffortForAPI: String? {
        guard let info = currentModelInfo, !info.supportedEffortLevels.isEmpty else {
            return nil
        }
        let current = reasoningEffort.lowercased()
        if current == "none" {
            return nil
        }
        if current == "default" {
            return info.defaultEffortLevel
        }
        if info.supportedEffortLevels.contains(current) {
            return current
        }
        return info.defaultEffortLevel
    }

    public var currentBaseURL: String {
        get {
            customEndpoints[selectedProvider.rawValue] ?? selectedProvider.defaultBaseURL
        }
        set {
            customEndpoints[selectedProvider.rawValue] = newValue
        }
    }

    public func apiKey(for provider: LLMProviderType) -> String {
        KeychainHelper.loadKey(for: provider.rawValue)
    }

    public func setAPIKey(_ key: String, for provider: LLMProviderType) {
        KeychainHelper.saveKey(key, for: provider.rawValue)
        objectWillChange.send()
        Task {
            await refreshModelsForCurrentProvider()
        }
    }

    /// Dynamically fetches the model list from the active provider's `/models` endpoint (Zero hardcoding).
    public func refreshModelsForCurrentProvider() async {
        let provider = selectedProvider
        let baseURL = currentBaseURL
        let key = apiKey(for: provider)

        isFetchingModels = true
        defer { isFetchingModels = false }

        do {
            let fetched: [RemoteModelInfo]
            if provider == .antigravity {
                fetched = try await AGYCLIRunner.fetchAvailableModels(
                    customPath: agyCustomBinaryPath,
                    portableRoot: agyPortableRootPath
                )
            } else {
                fetched = try await LLMStreamingClient.fetchRemoteModels(
                    baseURL: baseURL,
                    apiKey: key,
                    provider: provider
                )
            }
            if !fetched.isEmpty {
                self.availableModels = fetched
                if let encoded = try? JSONEncoder().encode(fetched) {
                    UserDefaults.standard.set(encoded, forKey: "sparkbar.cachedModels.\(provider.rawValue)")
                }
                let existing = selectedModels[provider.rawValue] ?? ""
                if existing.isEmpty || !fetched.contains(where: { $0.id == existing }) {
                    selectedModels[provider.rawValue] = fetched.first?.id ?? ""
                }
                syncEffortLevelWithCurrentModel()
            }
        } catch {
            // Keep existing models if offline or key not yet entered
        }
    }

    private func syncEffortLevelWithCurrentModel() {
        let validLevels = supportedEffortLevelsForCurrentModel
        guard !validLevels.isEmpty else { return }
        if !validLevels.contains(reasoningEffort) {
            reasoningEffort = "default"
        }
    }

    /// Concise host context note injected on the first turn of an `agy` CLI conversation so the model knows it is running inside SparkBar.
    public var sparkBarContextNoteForAGY: String {
        "You are currently running inside SparkBar, a lightweight native macOS Spotlight-style AI launcher (⌥ + Space). You are primarily a live web-search and quick-answer bot: for factual, app-feature, how-to, or current-state questions, ALWAYS call `search_web` first to verify up-to-date facts instead of answering solely from memory. Keep responses short, direct, and formatted in clean GitHub-flavored Markdown suited for a compact floating panel."
    }

    /// Reads universal `AGENTS.md` and appends the pre-probed Host Environment Manifest so the agent never wastes turns guessing PATH, brew, or PDF capabilities.
    public func effectiveSystemPrompt() -> String {
        var prompt = systemPrompt
        let candidatePaths = [
            Bundle.main.bundlePath + "/Contents/Resources/AGENTS.md",
            FileManager.default.currentDirectoryPath + "/AGENTS.md"
        ]
        for path in candidatePaths {
            if let agentsDoc = try? String(contentsOfFile: path, encoding: .utf8), !agentsDoc.isEmpty {
                prompt += "\n\n---\n" + agentsDoc
                break
            }
        }
        let manifestSummary = EnvironmentProbe.shared.currentManifest().toSystemPromptSummary(
            sessionWorkspace: JobManager.shared.workspaceDirectory,
            currentCwd: JobManager.shared.currentWorkingDirectory
        )
        prompt += "\n\n---\n" + manifestSummary
        return prompt
    }

    private func updateLaunchAtLogin(enabled: Bool) {
        let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let plistURL = launchAgentsDir.appendingPathComponent("com.sparkbar.app.plist")

        var usedSMAppService = false
        if #available(macOS 13.0, *), Bundle.main.bundleURL.pathExtension == "app" {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                usedSMAppService = true
            } catch {
                usedSMAppService = false
            }
        }

        // Only use LaunchAgent plist if SMAppService was unavailable (e.g. non-.app CLI build).
        // Never keep both active at once, or macOS will spawn two instances on login.
        if usedSMAppService || !enabled {
            try? FileManager.default.removeItem(at: plistURL)
        } else if enabled {
            let executablePath = Bundle.main.executablePath
                ?? "/Applications/SparkBar.app/Contents/MacOS/SparkBar"
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key>
                <string>com.sparkbar.app</string>
                <key>ProgramArguments</key>
                <array>
                    <string>\(executablePath)</string>
                    <string>--background</string>
                </array>
                <key>RunAtLoad</key>
                <true/>
            </dict>
            </plist>
            """
            try? FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
            try? plistContent.write(to: plistURL, atomically: true, encoding: .utf8)
        }
    }

    private func bootstrapLocalKeysIfNeeded() {
        if KeychainHelper.loadKey(for: LLMProviderType.deepseek.rawValue).isEmpty {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let candidate = home.appendingPathComponent("Downloads/deepseekapihermesandroid.txt")
            if let content = try? String(contentsOf: candidate, encoding: .utf8) {
                let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("sk-") {
                    KeychainHelper.saveKey(trimmed, for: LLMProviderType.deepseek.rawValue)
                }
            }
        }
    }
}
