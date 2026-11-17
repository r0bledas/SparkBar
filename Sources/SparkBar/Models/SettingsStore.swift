import Foundation
import Combine

@MainActor
public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()

    @Published public var selectedProvider: LLMProviderType {
        didSet {
            UserDefaults.standard.set(selectedProvider.rawValue, forKey: "sparkbar.selectedProvider")
        }
    }

    @Published public var selectedModels: [String: String] {
        didSet {
            UserDefaults.standard.set(selectedModels, forKey: "sparkbar.selectedModels")
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

        if let savedModels = defaults.dictionary(forKey: "sparkbar.selectedModels") as? [String: String] {
            self.selectedModels = savedModels
        } else {
            var initial: [String: String] = [:]
            for provider in LLMProviderType.allCases {
                initial[provider.rawValue] = provider.defaultModel
            }
            self.selectedModels = initial
        }

        if let savedEndpoints = defaults.dictionary(forKey: "sparkbar.customEndpoints") as? [String: String] {
            self.customEndpoints = savedEndpoints
        } else {
            var initialEndpoints: [String: String] = [:]
            for provider in LLMProviderType.allCases {
                initialEndpoints[provider.rawValue] = provider.defaultBaseURL
            }
            self.customEndpoints = initialEndpoints
        }

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
    }

    public var currentModel: String {
        get {
            selectedModels[selectedProvider.rawValue] ?? selectedProvider.defaultModel
        }
        set {
            selectedModels[selectedProvider.rawValue] = newValue
        }
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
    }

    private func bootstrapLocalKeysIfNeeded() {
        // If no DeepSeek key is stored yet, check if the user has deepseekapihermesandroid.txt in Downloads
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
