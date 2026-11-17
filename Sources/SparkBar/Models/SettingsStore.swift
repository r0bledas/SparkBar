import Foundation
import Combine

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

        self.reasoningEffort = defaults.string(forKey: "sparkbar.reasoningEffort") ?? "high"
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
        currentModelInfo?.supportedEffortLevels ?? []
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
        guard let info = currentModelInfo, !info.supportedEffortLevels.isEmpty else { return }
        if !info.supportedEffortLevels.contains(reasoningEffort) {
            reasoningEffort = info.defaultEffortLevel ?? info.supportedEffortLevels.first ?? "high"
        }
    }

    /// Reads `AGENTS.md` to inject live workspace and environment context into the system prompt.
    public func effectiveSystemPrompt() -> String {
        var prompt = systemPrompt
        let candidatePaths = [
            FileManager.default.currentDirectoryPath + "/AGENTS.md",
            "/Users/raudel/.gemini/antigravity/scratch/SparkBar/AGENTS.md",
            Bundle.main.bundlePath + "/Contents/Resources/AGENTS.md"
        ]
        for path in candidatePaths {
            if let agentsDoc = try? String(contentsOfFile: path, encoding: .utf8), !agentsDoc.isEmpty {
                prompt += "\n\n---\n" + agentsDoc
                break
            }
        }
        return prompt
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
