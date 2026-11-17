import Foundation
import Combine
import ServiceManagement

@MainActor
public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()

    @Published public var selectedProvider: LLMProviderType {
        didSet {
            UserDefaults.standard.set(selectedProvider.rawValue, forKey: "sparkbar.selectedProvider")
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
        You are SparkBar, an ultra-fast, lightweight native macOS assistant and autonomous tool agent inspired by Hermes Agent and OpenCode.
        Provide concise, accurate, high-signal answers formatted in clean Markdown.
        When asked about live events, documentation, files, or system state, proactively use your available tools (`web_search`, `fetch_url`, `read_file`, `list_directory`, `run_command`, `clipboard`).
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

        bootstrapLocalKeysIfNeeded()

        Task {
            await refreshModelsForCurrentProvider()
        }
    }

    public var currentModel: String {
        get {
            if let saved = selectedModels[selectedProvider.rawValue], !saved.isEmpty {
                // Verify saved model exists in availableModels if availableModels is already loaded
                if availableModels.isEmpty || availableModels.contains(where: { $0.id == saved }) {
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
        availableModels.first(where: { $0.id == currentModel }) ?? availableModels.first
    }

    public var supportedEffortLevelsForCurrentModel: [String] {
        guard let info = currentModelInfo else { return [] }
        var levels: [String] = ["none", "default"]
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
                return "Default (\(def.capitalized))"
            }
            return "Default"
        default:
            return level.capitalized
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
            let fetched = try await LLMStreamingClient.fetchRemoteModels(
                baseURL: baseURL,
                apiKey: key,
                provider: provider
            )
            if !fetched.isEmpty {
                self.availableModels = fetched
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

    /// Reads universal `AGENTS.md` to include agent instructions in the system prompt.
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
        return prompt
    }

    private func updateLaunchAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Fallback to LaunchAgent plist below for unsigned/local builds
            }
        }

        let launchAgentsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let plistURL = launchAgentsDir.appendingPathComponent("com.sparkbar.app.plist")

        if enabled {
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
                </array>
                <key>RunAtLoad</key>
                <true/>
            </dict>
            </plist>
            """
            try? FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
            try? plistContent.write(to: plistURL, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: plistURL)
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
