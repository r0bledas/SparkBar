import Foundation

public enum LLMProviderType: String, CaseIterable, Codable, Identifiable {
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

    public var defaultModel: String {
        switch self {
        case .deepseek: return "deepseek-chat"
        case .openai: return "gpt-4o-mini"
        case .openrouter: return "deepseek/deepseek-chat:online"
        case .anthropic: return "claude-3-5-sonnet-latest"
        case .groq: return "llama-3.3-70b-versatile"
        case .gemini: return "gemini-2.5-flash"
        case .ollama: return "qwen2.5-coder:7b"
        case .custom: return "local-model"
        }
    }

    public var suggestedModels: [String] {
        switch self {
        case .deepseek:
            return ["deepseek-chat", "deepseek-reasoner"]
        case .openai:
            return ["gpt-4o-mini", "gpt-4o", "gpt-4.1-mini", "gpt-4.1", "o3-mini"]
        case .openrouter:
            return [
                "deepseek/deepseek-chat:online",
                "deepseek/deepseek-chat",
                "deepseek/deepseek-r1:online",
                "anthropic/claude-3.5-sonnet:online",
                "google/gemini-2.5-flash:online",
                "perplexity/sonar-pro",
                "openai/gpt-4o-mini"
            ]
        case .anthropic:
            return ["claude-3-5-sonnet-latest", "claude-3-5-haiku-latest", "claude-3-7-sonnet-latest"]
        case .groq:
            return ["llama-3.3-70b-versatile", "deepseek-r1-distill-llama-70b", "mixtral-8x7b-32768"]
        case .gemini:
            return ["gemini-2.5-flash", "gemini-2.5-pro"]
        case .ollama:
            return ["qwen2.5-coder:7b", "llama3.2", "deepseek-r1:8b", "mistral"]
        case .custom:
            return ["local-model"]
        }
    }

    public var requiresAPIKey: Bool {
        switch self {
        case .ollama: return false
        default: return true
        }
    }

    public var supportsServerSideWebSearch: Bool {
        switch self {
        case .deepseek, .openrouter, .openai, .gemini:
            return true
        default:
            return false
        }
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

public struct ToolExecutionRecord: Identifiable, Codable, Equatable {
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

public struct ChatMessage: Identifiable, Codable, Equatable {
    public var id: UUID
    public var role: MessageRole
    public var content: String
    public var reasoningContent: String?
    public var toolCalls: [ToolCallRequest]?
    public var toolCallId: String?
    public var toolName: String?
    public var toolRecords: [ToolExecutionRecord]
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
        self.timestamp = timestamp
    }
}
