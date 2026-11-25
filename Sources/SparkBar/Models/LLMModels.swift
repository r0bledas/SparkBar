import Foundation

public enum LLMProviderType: String, CaseIterable, Codable, Identifiable {
    case antigravity = "antigravity"
    case deepseek = "deepseek"
    case openai = "openai"
    case openrouter = "openrouter"
    case anthropic = "anthropic"
    case groq = "groq"
    case gemini = "gemini"
    case ollama = "ollama"
    case custom = "custom"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .antigravity: return "Google Antigravity (AGY)"
        case .deepseek: return "DeepSeek"
        case .openai: return "OpenAI"
        case .openrouter: return "OpenRouter"
        case .anthropic: return "Anthropic Claude"
        case .groq: return "Groq"
        case .gemini: return "Google Gemini"
        case .ollama: return "Ollama (Local)"
        case .custom: return "Custom OpenAI-Compatible"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .antigravity: return "local://agy-cli"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .openai: return "https://api.openai.com/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .ollama: return "http://127.0.0.1:11434/v1"
        case .custom: return "http://127.0.0.1:8080/v1"
        }
    }

    public var requiresAPIKey: Bool {
        switch self {
        case .antigravity, .ollama: return false
        default: return true
        }
    }

    public var supportsServerSideWebSearch: Bool {
        switch self {
        case .antigravity, .deepseek, .openrouter, .openai, .gemini:
            return true
        default:
            return false
        }
    }

    public static let antigravityProviders: [LLMProviderType] = [.antigravity]
    public static let apiProviders: [LLMProviderType] = [.deepseek, .openai, .openrouter, .anthropic, .groq, .gemini]
    public static let localProviders: [LLMProviderType] = [.ollama, .custom]
}

/// Dynamic model metadata fetched live from `GET /models` or `agy models` — zero hardcoded model lists.
public struct RemoteModelInfo: Identifiable, Codable, Equatable {
    public var id: String
    public var name: String?
    public var ownedBy: String?
    public var contextWindow: Int?
    public var maxOutputTokens: Int?
    public var supportedEffortLevels: [String]
    public var defaultEffortLevel: String?
    /// Optional mapping from lowercase effort/variant key (e.g. `"low"`, `"high"`, `"xhigh"`, `"neon"`)
    /// to the exact backend model ID (e.g. `"gemini-4-neon-high"`, `"gemini-pro-orchestrator-neon"`).
    public var effortVariantModelIds: [String: String]?

    public init(
        id: String,
        name: String? = nil,
        ownedBy: String? = nil,
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        supportedEffortLevels: [String] = [],
        defaultEffortLevel: String? = nil,
        effortVariantModelIds: [String: String]? = nil
    ) {
        self.id = id
        self.name = name
        self.ownedBy = ownedBy
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.supportedEffortLevels = supportedEffortLevels
        self.defaultEffortLevel = defaultEffortLevel
        self.effortVariantModelIds = effortVariantModelIds
    }

    /// Resolves the concrete backend model ID for a given effort/variant selection.
    public func resolvedModelId(forEffort effort: String?) -> String {
        guard let variants = effortVariantModelIds, !variants.isEmpty else {
            return id
        }
        let key = (effort ?? "default").lowercased()
        if let exact = variants[key] {
            return exact
        }
        if key == "none", let lowest = variants["low"] {
            return lowest
        }
        if let defKey = defaultEffortLevel?.lowercased(), let defId = variants[defKey] {
            return defId
        }
        return id
    }

    /// Shows the clean API model name (e.g. `DeepSeek-V4.1-Flash` or `Gemini 4 Neon`) without repeating the ID in parentheses.
    public var displayLabel: String {
        if let name = name, !name.isEmpty {
            return name
        }
        return id
    }

    public var shortLabel: String {
        displayLabel
    }
}

public struct ToolCallRequest: Identifiable, Codable, Equatable {
    public var id: String
    public var name: String
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

public struct ToolExecutionRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var toolCallId: String
    public var toolName: String
    public var arguments: String
    public var output: String
    public var durationMs: Int
    public var isError: Bool

    public init(
        id: UUID = UUID(),
        toolCallId: String,
        toolName: String,
        arguments: String,
        output: String,
        durationMs: Int,
        isError: Bool = false
    ) {
        self.id = id
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.arguments = arguments
        self.output = output
        self.durationMs = durationMs
        self.isError = isError
    }
}

public enum MessageRole: String, Codable {
    case system
    case user
    case assistant
    case tool
}

public struct AttachedImage: Identifiable, Codable, Equatable {
    public var id: UUID
    public var base64Data: String
    public var mimeType: String
    public var fileName: String?
    public var localFilePath: String?

    public init(
        id: UUID = UUID(),
        base64Data: String,
        mimeType: String = "image/jpeg",
        fileName: String? = nil,
        localFilePath: String? = nil
    ) {
        self.id = id
        self.base64Data = base64Data
        self.mimeType = mimeType
        self.fileName = fileName
        self.localFilePath = localFilePath
    }
}

public struct ChatMessage: Identifiable, Codable, Equatable {
    public var id: UUID
    public var role: MessageRole
    public var content: String
    public var reasoningContent: String?
    public var toolCalls: [ToolCallRequest]?
    public var toolCallId: String?
    public var toolName: String?
    public var toolRecords: [ToolExecutionRecord]
    public var attachedImages: [AttachedImage]
    public var systemNote: String?
    public var timestamp: Date

    public init(
        id: UUID = UUID(),
        role: MessageRole,
        content: String,
        reasoningContent: String? = nil,
        toolCalls: [ToolCallRequest]? = nil,
        toolCallId: String? = nil,
        toolName: String? = nil,
        toolRecords: [ToolExecutionRecord] = [],
        attachedImages: [AttachedImage] = [],
        systemNote: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.toolRecords = toolRecords
        self.attachedImages = attachedImages
        self.systemNote = systemNote
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey {
        case id, role, content, reasoningContent, toolCalls, toolCallId, toolName, toolRecords, attachedImages, systemNote, timestamp
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.role = try container.decode(MessageRole.self, forKey: .role)
        self.content = try container.decode(String.self, forKey: .content)
        self.reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
        self.toolCalls = try container.decodeIfPresent([ToolCallRequest].self, forKey: .toolCalls)
        self.toolCallId = try container.decodeIfPresent(String.self, forKey: .toolCallId)
        self.toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        self.toolRecords = try container.decodeIfPresent([ToolExecutionRecord].self, forKey: .toolRecords) ?? []
        self.attachedImages = try container.decodeIfPresent([AttachedImage].self, forKey: .attachedImages) ?? []
        self.systemNote = try container.decodeIfPresent(String.self, forKey: .systemNote)
        self.timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
    }
}
