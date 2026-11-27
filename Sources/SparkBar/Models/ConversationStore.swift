import Foundation
import AppKit

public struct ConversationSession: Identifiable, Codable, Equatable {
    public var id: UUID
    public var title: String
    public var customTitle: String?
    public var isPinned: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var provider: String
    public var model: String
    public var agyConversationId: String?
    public var messages: [ChatMessage]

    public var displayTitle: String {
        if let custom = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            return custom
        }
        return title
    }

    public init(
        id: UUID = UUID(),
        title: String = "New Chat",
        customTitle: String? = nil,
        isPinned: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        provider: String = "",
        model: String = "",
        agyConversationId: String? = nil,
        messages: [ChatMessage] = []
    ) {
        self.id = id
        self.title = title
        self.customTitle = customTitle
        self.isPinned = isPinned
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.provider = provider
        self.model = model
        self.agyConversationId = agyConversationId
        self.messages = messages
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, customTitle, isPinned, createdAt, updatedAt, provider, model, agyConversationId, messages
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "New Chat"
        customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        provider = try c.decodeIfPresent(String.self, forKey: .provider) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        agyConversationId = try c.decodeIfPresent(String.self, forKey: .agyConversationId)
        messages = try c.decodeIfPresent([ChatMessage].self, forKey: .messages) ?? []
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
    public let attachmentsDirectory: URL
    private let sessionsFileURL: URL
    private let ioQueue = DispatchQueue(label: "com.sparkbar.conversations.io", qos: .utility)
    private var searchIndex: [UUID: String] = [:]

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let appDir = base.appendingPathComponent("SparkBar", isDirectory: true)
        let convDir = appDir.appendingPathComponent("conversations", isDirectory: true)
        let logsDir = appDir.appendingPathComponent("logs", isDirectory: true)
        let attachDir = appDir.appendingPathComponent("attachments", isDirectory: true)

        try? FileManager.default.createDirectory(at: convDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: attachDir, withIntermediateDirectories: true)

        self.conversationsDirectory = convDir
        self.markdownLogsDirectory = logsDir
        self.attachmentsDirectory = attachDir
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
        if var decoded = try? decoder.decode([ConversationSession].self, from: data) {
            // Migrate any inline base64 image payloads out of sessions.json into attachments/
            // so sessions.json stays tiny (~200 KB instead of 60+ MB) and startup RAM stays low.
            var didMigrate = false
            for sIdx in decoded.indices {
                let (compacted, changed) = offloadBase64Attachments(in: decoded[sIdx].messages)
                if changed {
                    decoded[sIdx].messages = compacted
                    didMigrate = true
                }
            }
            self.sessions = sortSessions(decoded)
            rebuildSearchIndex()
            if didMigrate {
                saveToDisk()
            }
        }
    }

    private func sortSessions(_ list: [ConversationSession]) -> [ConversationSession] {
        list.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    private func rebuildSearchIndex() {
        var idx: [UUID: String] = [:]
        idx.reserveCapacity(sessions.count)
        for s in sessions {
            idx[s.id] = buildSearchBlob(for: s)
        }
        searchIndex = idx
    }

    private func buildSearchBlob(for session: ConversationSession) -> String {
        var parts: [String] = [session.displayTitle.lowercased()]
        for m in session.messages where !m.content.isEmpty {
            parts.append(m.content.lowercased())
        }
        return parts.joined(separator: "\n")
    }

    /// Fast pre-indexed search across all sessions (O(1) string scan per session instead of re-lowercasing every message).
    public func filteredSessions(matching query: String) -> [ConversationSession] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return sessions }
        return sessions.filter { session in
            if let blob = searchIndex[session.id] {
                return blob.contains(q)
            }
            return session.displayTitle.lowercased().contains(q)
        }
    }

    private func offloadBase64Attachments(in messages: [ChatMessage]) -> ([ChatMessage], Bool) {
        var out = messages
        var changed = false
        let fm = FileManager.default

        for mIdx in out.indices where !out[mIdx].attachedImages.isEmpty {
            for iIdx in out[mIdx].attachedImages.indices {
                let img = out[mIdx].attachedImages[iIdx]
                guard !img.base64Data.isEmpty else { continue }

                let ext: String
                switch img.mimeType.lowercased() {
                case "image/png": ext = "png"
                case "image/gif": ext = "gif"
                case "image/webp": ext = "webp"
                default: ext = "jpg"
                }
                let targetURL = attachmentsDirectory.appendingPathComponent("\(img.id.uuidString).\(ext)")
                if !fm.fileExists(atPath: targetURL.path),
                   let raw = Data(base64Encoded: img.base64Data) {
                    try? raw.write(to: targetURL, options: .atomic)
                }
                if fm.fileExists(atPath: targetURL.path) {
                    out[mIdx].attachedImages[iIdx].localFilePath = targetURL.path
                    out[mIdx].attachedImages[iIdx].base64Data = ""
                    changed = true
                }
            }
        }
        return (out, changed)
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

        let (compactedMessages, _) = offloadBase64Attachments(in: messages)
        let now = Date()
        let title = ConversationSession.makeTitle(from: compactedMessages)

        if let index = sessions.firstIndex(where: { $0.id == id }) {
            // Skip redundant disk write if nothing actually changed
            if sessions[index].messages == compactedMessages &&
               sessions[index].provider == provider &&
               sessions[index].model == model &&
               (agyConversationId == nil || sessions[index].agyConversationId == agyConversationId) {
                activeSessionId = id
                return
            }
            sessions[index].title = title
            sessions[index].updatedAt = now
            sessions[index].provider = provider
            sessions[index].model = model
            if let agyId = agyConversationId, !agyId.isEmpty {
                sessions[index].agyConversationId = agyId
            }
            sessions[index].messages = compactedMessages
            searchIndex[id] = buildSearchBlob(for: sessions[index])
        } else {
            let newSession = ConversationSession(
                id: id,
                title: title,
                createdAt: compactedMessages.first?.timestamp ?? now,
                updatedAt: now,
                provider: provider,
                model: model,
                agyConversationId: agyConversationId,
                messages: compactedMessages
            )
            sessions.insert(newSession, at: 0)
            searchIndex[id] = buildSearchBlob(for: newSession)
        }

        sessions = sortSessions(sessions)
        activeSessionId = id
        saveToDisk()

        if let current = sessions.first(where: { $0.id == id }) {
            writeMarkdownLog(for: current)
        }
    }

    public func togglePin(id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].isPinned.toggle()
        sessions = sortSessions(sessions)
        saveToDisk()
    }

    public func renameSession(id: UUID, newTitle: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        sessions[idx].customTitle = trimmed.isEmpty ? nil : trimmed
        searchIndex[id] = buildSearchBlob(for: sessions[idx])
        saveToDisk()
    }

    public func deleteSession(id: UUID) {
        if let session = sessions.first(where: { $0.id == id }) {
            removeMarkdownLog(for: session)
        }
        sessions.removeAll { $0.id == id }
        searchIndex.removeValue(forKey: id)
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
        searchIndex.removeAll()
        activeSessionId = nil
        saveToDisk()
    }

    public func openLogsFolderInFinder() {
        NSWorkspace.shared.open(markdownLogsDirectory)
    }

    /// Formats a session as clean Markdown for export or clipboard copy.
    public func formatSessionMarkdown(_ session: ConversationSession) -> String {
        var md = "# \(session.displayTitle)\n\n"
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
        return md
    }

    private func saveToDisk() {
        let snapshot = sessions
        let url = sessionsFileURL
        ioQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(snapshot) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func writeMarkdownLog(for session: ConversationSession) {
        let logURL = markdownLogURL(for: session)
        let md = formatSessionMarkdown(session)
        ioQueue.async {
            try? md.write(to: logURL, atomically: true, encoding: .utf8)
        }
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
