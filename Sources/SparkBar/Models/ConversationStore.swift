import Foundation
import AppKit

public struct ConversationSession: Identifiable, Codable, Equatable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var provider: String
    public var model: String
    public var agyConversationId: String?
    public var messages: [ChatMessage]

    public init(
        id: UUID = UUID(),
        title: String = "New Chat",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        provider: String = "",
        model: String = "",
        agyConversationId: String? = nil,
        messages: [ChatMessage] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.provider = provider
        self.model = model
        self.agyConversationId = agyConversationId
        self.messages = messages
    }

    /// Generates a clean, concise title from the first user message.
    public static func makeTitle(from messages: [ChatMessage]) -> String {
        guard let firstUser = messages.first(where: { $0.role == .user }) else {
            return "New Chat"
        }
        let cleaned = firstUser.content
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return "New Chat" }
        if cleaned.count <= 58 { return cleaned }
        return String(cleaned.prefix(58)) + "…"
    }

    public var userAndAssistantMessageCount: Int {
        messages.filter { $0.role == .user || ($0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }.count
    }

    public var previewSnippet: String {
        if let lastAssistant = messages.last(where: { $0.role == .assistant && !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            let line = lastAssistant.content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return line.count <= 90 ? line : String(line.prefix(90)) + "…"
        }
        if let lastUser = messages.last(where: { $0.role == .user }) {
            let line = lastUser.content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return line.count <= 90 ? line : String(line.prefix(90)) + "…"
        }
        return "Empty conversation"
    }
}

@MainActor
public final class ConversationStore: ObservableObject {
    public static let shared = ConversationStore()

    @Published public private(set) var sessions: [ConversationSession] = []
    @Published public var activeSessionId: UUID? = nil

    public let conversationsDirectory: URL
    public let markdownLogsDirectory: URL
    private let sessionsFileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let appDir = base.appendingPathComponent("SparkBar", isDirectory: true)
        let convDir = appDir.appendingPathComponent("conversations", isDirectory: true)
        let logsDir = appDir.appendingPathComponent("logs", isDirectory: true)

        try? FileManager.default.createDirectory(at: convDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        self.conversationsDirectory = convDir
        self.markdownLogsDirectory = logsDir
        self.sessionsFileURL = convDir.appendingPathComponent("sessions.json")

        loadFromDisk()
        seedRecoveredWorkspaceSessionsIfNeeded()
    }

    public func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: sessionsFileURL.path),
              let data = try? Data(contentsOf: sessionsFileURL) else {
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([ConversationSession].self, from: data) {
            self.sessions = decoded.sorted(by: { $0.updatedAt > $1.updatedAt })
        }
    }

    public func upsertSession(
        id: UUID,
        messages: [ChatMessage],
        provider: String,
        model: String,
        agyConversationId: String? = nil
    ) {
        // Only persist sessions that have at least one message
        guard !messages.isEmpty else { return }

        let now = Date()
        let title = ConversationSession.makeTitle(from: messages)

        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].title = title
            sessions[index].updatedAt = now
            sessions[index].provider = provider
            sessions[index].model = model
            if let agyId = agyConversationId, !agyId.isEmpty {
                sessions[index].agyConversationId = agyId
            }
            sessions[index].messages = messages
        } else {
            let newSession = ConversationSession(
                id: id,
                title: title,
                createdAt: messages.first?.timestamp ?? now,
                updatedAt: now,
                provider: provider,
                model: model,
                agyConversationId: agyConversationId,
                messages: messages
            )
            sessions.insert(newSession, at: 0)
        }

        sessions.sort(by: { $0.updatedAt > $1.updatedAt })
        activeSessionId = id
        saveToDisk()

        if let current = sessions.first(where: { $0.id == id }) {
            writeMarkdownLog(for: current)
        }
    }

    public func deleteSession(id: UUID) {
        if let session = sessions.first(where: { $0.id == id }) {
            removeMarkdownLog(for: session)
        }
        sessions.removeAll { $0.id == id }
        if activeSessionId == id {
            activeSessionId = nil
        }
        saveToDisk()
    }

    public func clearAllHistory() {
        for session in sessions {
            removeMarkdownLog(for: session)
        }
        sessions.removeAll()
        activeSessionId = nil
        saveToDisk()
    }

    public func openLogsFolderInFinder() {
        NSWorkspace.shared.open(markdownLogsDirectory)
    }

    private func saveToDisk() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(sessions) else { return }
        try? data.write(to: sessionsFileURL, options: .atomic)
    }

    private func writeMarkdownLog(for session: ConversationSession) {
        let logURL = markdownLogURL(for: session)
        var md = "# \(session.title)\n\n"
        let fmt = ISO8601DateFormatter()
        md += "- **Session ID**: `\(session.id.uuidString)`\n"
        md += "- **Created**: \(fmt.string(from: session.createdAt))\n"
        md += "- **Updated**: \(fmt.string(from: session.updatedAt))\n"
        if !session.provider.isEmpty || !session.model.isEmpty {
            md += "- **Model**: `\(session.provider) / \(session.model)`\n"
        }
        md += "\n---\n\n"

        for msg in session.messages {
            switch msg.role {
            case .user:
                var userText = "## 👤 User\n\n"
                for img in msg.attachedImages {
                    if let path = img.localFilePath {
                        userText += "![Attached Image](\(path))\n\n"
                    } else {
                        userText += "*[Attached Image: \(img.fileName ?? "image.png")]*\n\n"
                    }
                }
                userText += "\(msg.content)\n\n"
                md += userText
            case .assistant:
                if let reasoning = msg.reasoningContent, !reasoning.isEmpty {
                    md += "<details><summary>Thought Process</summary>\n\n\(reasoning)\n\n</details>\n\n"
                }
                if !msg.content.isEmpty {
                    md += "## ⚡ SparkBar\n\n\(msg.content)\n\n"
                }
            case .tool:
                let name = msg.toolName ?? "tool"
                md += "### 🔧 Tool (`\(name)`)\n\n```text\n\(msg.content)\n```\n\n"
            case .system:
                break
            }
        }

        try? md.write(to: logURL, atomically: true, encoding: .utf8)
    }

    private func removeMarkdownLog(for session: ConversationSession) {
        let logURL = markdownLogURL(for: session)
        try? FileManager.default.removeItem(at: logURL)
    }

    private func markdownLogURL(for session: ConversationSession) -> URL {
        let shortId = String(session.id.uuidString.prefix(8)).lowercased()
        let slug = session.title
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(6)
            .joined(separator: "-")
        let safeSlug = slug.isEmpty ? "chat" : slug
        return markdownLogsDirectory.appendingPathComponent("\(safeSlug)-\(shortId).md")
    }

    /// Reconstructs any pre-v1.2 workspace artifacts (such as `workspace/urbanire`) into a recoverable session if `sessions` is empty.
    private func seedRecoveredWorkspaceSessionsIfNeeded() {
        guard sessions.isEmpty else { return }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let urbanireDir = base.appendingPathComponent("SparkBar/workspace/urbanire", isDirectory: true)
        guard FileManager.default.fileExists(atPath: urbanireDir.path) else { return }

        let planURL = urbanireDir.appendingPathComponent("widget_planning.md")
        let liveActivityURL = urbanireDir.appendingPathComponent("MetroLiveActivity.swift")
        let bundleURL = urbanireDir.appendingPathComponent("MetroWidgetBundle.swift")

        let planText = (try? String(contentsOf: planURL, encoding: .utf8)) ?? ""
        let liveActivityText = (try? String(contentsOf: liveActivityURL, encoding: .utf8)) ?? ""
        let bundleText = (try? String(contentsOf: bundleURL, encoding: .utf8)) ?? ""

        guard !planText.isEmpty || !liveActivityText.isEmpty else { return }

        let fileDate = (try? FileManager.default.attributesOfItem(atPath: liveActivityURL.path)[.modificationDate] as? Date) ?? Date()

        var reconstructedMessages: [ChatMessage] = [
            ChatMessage(
                role: .user,
                content: "ShadowBani / Urbanire — WidgetKit & Live Activity implementation (Recovered from workspace)",
                timestamp: fileDate.addingTimeInterval(-120)
            )
        ]

        var combinedResponse = "### Recovered Workspace Artifacts (`~/Library/Application Support/SparkBar/workspace/urbanire`)\n\n"
        if !planText.isEmpty {
            combinedResponse += planText + "\n\n---\n\n"
        }
        if !bundleText.isEmpty {
            combinedResponse += "## `MetroWidgetBundle.swift`\n\n```swift\n\(bundleText)\n```\n\n"
        }
        if !liveActivityText.isEmpty {
            combinedResponse += "## `MetroLiveActivity.swift`\n\n```swift\n\(liveActivityText)\n```\n"
        }

        reconstructedMessages.append(
            ChatMessage(
                role: .assistant,
                content: combinedResponse,
                timestamp: fileDate
            )
        )

        let recoveredSession = ConversationSession(
            id: UUID(),
            title: "ShadowBani — WidgetKit & Live Activity (Recovered)",
            createdAt: fileDate.addingTimeInterval(-120),
            updatedAt: fileDate,
            provider: "deepseek",
            model: "deepseek-chat",
            messages: reconstructedMessages
        )

        self.sessions = [recoveredSession]
        saveToDisk()
        writeMarkdownLog(for: recoveredSession)
    }
}
