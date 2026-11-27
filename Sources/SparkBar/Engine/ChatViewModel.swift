import Foundation
import Combine
import AppKit
import ImageIO

/// Isolated observable holder for live prompt typing so keystrokes NEVER trigger `ChatViewModel.objectWillChange`
/// or re-evaluate the chat message stream / sidebar views.
@MainActor
public final class PromptInputState: ObservableObject {
    @Published public var text: String = ""
    public init() {}
}

/// Hardware-accelerated downsampled thumbnail cache using ImageIO (`CGImageSourceCreateThumbnailAtIndex`).
/// Prevents decoding full-resolution multi-megabyte base64 PNGs into 400+ MB of `Image IO` RAM on every SwiftUI body pass.
public final class ThumbnailImageCache: @unchecked Sendable {
    public static let shared = ThumbnailImageCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 80
    }

    public func thumbnail(for img: AttachedImage, maxPixelSize: Int) -> NSImage? {
        let key = "\(img.id.uuidString)_\(maxPixelSize)" as NSString
        if let hit = cache.object(forKey: key) {
            return hit
        }

        // Prefer reading directly from localFilePath if present (avoids base64 decoding huge strings in RAM)
        var source: CGImageSource?
        if let localPath = img.localFilePath, FileManager.default.fileExists(atPath: localPath) {
            source = CGImageSourceCreateWithURL(URL(fileURLWithPath: localPath) as CFURL, nil)
        }
        if source == nil, let data = Data(base64Encoded: img.base64Data) {
            source = CGImageSourceCreateWithData(data as CFData, nil)
        }
        guard let cgSource = source else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(cgSource, 0, options as CFDictionary) else {
            return nil
        }
        let nsImg = NSImage(cgImage: cgThumb, size: NSSize(width: cgThumb.width, height: cgThumb.height))
        cache.setObject(nsImg, forKey: key)
        return nsImg
    }
}

@MainActor
public final class ChatViewModel: ObservableObject {
    public static let shared = ChatViewModel()

    @Published public var currentSessionId: UUID = UUID()
    @Published public var messages: [ChatMessage] = []
    @Published public var attachedImages: [AttachedImage] = []
    public let inputState = PromptInputState()

    public var inputText: String {
        get { inputState.text }
        set {
            inputState.text = newValue
            guard !isSanitizingInput else { return }
            sanitizeDroppedImagePathsInInputText()
        }
    }
    @Published public var isStreaming: Bool = false
    @Published public var activeToolStatus: String? = nil
    @Published public var errorMessage: String? = nil
    @Published public var showSettings: Bool = false
    @Published public var showHistory: Bool = false
    @Published public var pendingModelSwitchBanner: String? = nil

    private let client = LLMStreamingClient()
    private var currentTask: Task<Void, Never>?
    private var isSanitizingInput: Bool = false
    public let scrollToMessageTrigger = PassthroughSubject<UUID, Never>()
    private var pendingModelSwitchNote: String? = nil
    private var pendingModelId: String? = nil
    private var currentAGYConversationId: String? = nil

    public init() {}

    /// Detects if macOS dropped a screenshot/image path (like `/var/folders/.../NSIRD_screencaptureui_.../Screenshot...png`)
    /// into `inputText`, attaches the image, and strips the path from the text box.
    private func sanitizeDroppedImagePathsInInputText() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("/var/folders/") || trimmed.hasPrefix("/") else { return }

        let unescaped = trimmed
            .replacingOccurrences(of: "\\ ", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        let ext = (unescaped as NSString).pathExtension.lowercased()
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "webp", "gif", "heic", "tiff", "bmp"]

        if imageExts.contains(ext), FileManager.default.fileExists(atPath: unescaped) {
            isSanitizingInput = true
            inputText = ""
            isSanitizingInput = false
            attachImage(from: URL(fileURLWithPath: unescaped))
        } else if unescaped.contains("screencaptureui") {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: unescaped, isDirectory: &isDir), isDir.boolValue,
               let items = try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: unescaped), includingPropertiesForKeys: nil),
               let firstImg = items.first(where: { imageExts.contains($0.pathExtension.lowercased()) }) {
                isSanitizingInput = true
                inputText = ""
                isSanitizingInput = false
                attachImage(from: firstImg)
            }
        }
    }

    public func sendCurrentPrompt() {
        let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !attachedImages.isEmpty else { return }
        inputText = ""
        sendPrompt(prompt)
    }

    public func sendPrompt(_ prompt: String) {
        currentTask?.cancel()
        errorMessage = nil
        showHistory = false

        let imagesToSend = attachedImages
        attachedImages = []

        if let queuedModelId = pendingModelId {
            SettingsStore.shared.currentModel = queuedModelId
            pendingModelId = nil
        }
        pendingModelSwitchBanner = nil

        let switchNote = pendingModelSwitchNote
        pendingModelSwitchNote = nil

        let userMsg = ChatMessage(role: .user, content: prompt, attachedImages: imagesToSend, systemNote: switchNote)
        messages.append(userMsg)
        persistCurrentSession()

        isStreaming = true
        PanelController.shared.syncPanelHeight(hasMessages: true)

        currentTask = Task { [weak self] in
            guard let self = self else { return }
            await self.runAgentLoop()
        }
    }

    public func stopGeneration() {
        let wasActive = isStreaming || currentTask != nil
        currentTask?.cancel()
        currentTask = nil
        AGYCLIRunner.shared.cancelCurrentProcess()
        isStreaming = false
        activeToolStatus = nil
        if wasActive {
            persistCurrentSession()
        }
    }

    public func attachImage(data: Data, mimeType: String, fileName: String? = nil) {
        let id = UUID()
        let name = fileName ?? "image_\(String(id.uuidString.prefix(6))).png"
        let ws = JobManager.shared.workspaceDirectory
        let localPath = (ws as NSString).appendingPathComponent(name)
        try? data.write(to: URL(fileURLWithPath: localPath))

        // Compact large screenshots (> 512 KB) to <= 1600px JPEG for base64 payload & session storage
        // so sessions.json and RAM stay featherweight while localPath keeps the original full-res file.
        var payloadData = data
        var payloadMime = mimeType
        if data.count > 512 * 1024,
           let src = CGImageSourceCreateWithData(data as CFData, nil) {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600
            ]
            if let cgImg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                let rep = NSBitmapImageRep(cgImage: cgImg)
                if let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]),
                   jpeg.count < data.count {
                    payloadData = jpeg
                    payloadMime = "image/jpeg"
                }
            }
        }

        let b64 = payloadData.base64EncodedString()
        let item = AttachedImage(
            id: id,
            base64Data: b64,
            mimeType: payloadMime,
            fileName: name,
            localFilePath: localPath
        )
        attachedImages.append(item)
        PanelController.shared.syncPanelHeight(hasMessages: !messages.isEmpty || showHistory)
    }

    public func attachImage(from url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let ext = url.pathExtension.lowercased()
        let mime: String
        switch ext {
        case "png": mime = "image/png"
        case "gif": mime = "image/gif"
        case "webp": mime = "image/webp"
        default: mime = "image/jpeg"
        }
        attachImage(data: data, mimeType: mime, fileName: url.lastPathComponent)
    }

    public func removeAttachedImage(id: UUID) {
        attachedImages.removeAll { $0.id == id }
        PanelController.shared.syncPanelHeight(hasMessages: !messages.isEmpty || showHistory)
    }

    @Published public var isPickingFile: Bool = false

    @discardableResult
    public func checkAndAttachPasteboardImage() -> Bool {
        let pb = NSPasteboard.general
        // 1. Check copied file URLs FIRST (so copying an image file in Finder reads the actual image bytes, NOT the Finder .icns file icon!)
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            var found = false
            for url in urls {
                let ext = url.pathExtension.lowercased()
                if ["png", "jpg", "jpeg", "webp", "gif", "heic", "tiff", "bmp"].contains(ext) {
                    attachImage(from: url)
                    found = true
                }
            }
            if found { return true }
        }
        // 2. Direct bitmap data from screenshots or "Copy Image" in browsers/Preview
        if let pngData = pb.data(forType: .png) {
            attachImage(data: pngData, mimeType: "image/png", fileName: "Screenshot.png")
            return true
        }
        if let tiffData = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiffData),
           let png = rep.representation(using: .png, properties: [:]) {
            attachImage(data: png, mimeType: "image/png", fileName: "Screenshot.png")
            return true
        }
        return false
    }

    /// Archives the current conversation into `ConversationStore` and starts a fresh empty chat (`⌘N` / `New Chat`).
    public func startNewConversation() {
        stopGeneration()
        persistCurrentSession()
        currentSessionId = UUID()
        currentAGYConversationId = nil
        messages.removeAll()
        attachedImages.removeAll()
        errorMessage = nil
        showHistory = false
        ConversationStore.shared.activeSessionId = nil
        PanelController.shared.syncPanelHeight(hasMessages: false)
    }

    /// Backwards-compatible alias used by shortcuts/menus: archives current conversation and resets the bar.
    public func clearConversation() {
        startNewConversation()
    }

    /// Restores a saved conversation from `ConversationStore` so the user can review or continue it.
    public func loadSession(_ session: ConversationSession) {
        let wasStreaming = isStreaming
        stopGeneration()
        if !wasStreaming && !messages.isEmpty && currentSessionId != session.id {
            persistCurrentSession()
        }
        currentSessionId = session.id
        currentAGYConversationId = session.agyConversationId
        messages = session.messages
        errorMessage = nil
        showHistory = false
        pendingModelSwitchNote = nil
        ConversationStore.shared.activeSessionId = session.id
        PanelController.shared.syncPanelHeight(hasMessages: !messages.isEmpty)
    }

    /// Re-runs the last user turn by trimming everything after the last user message and re-invoking the agent loop.
    public func regenerateLastResponse() {
        guard !isStreaming else { return }
        guard let lastUserIdx = messages.lastIndex(where: { $0.role == .user }) else { return }
        if lastUserIdx < messages.count - 1 {
            messages.removeSubrange((lastUserIdx + 1)..<messages.count)
        }
        errorMessage = nil
        isStreaming = true
        activeToolStatus = nil
        persistCurrentSession()
        currentTask = Task { [weak self] in
            guard let self = self else { return }
            await self.runAgentLoop()
        }
    }

    /// Moves the last user message back into the prompt box and removes that turn so the user can edit & resend it.
    public func editLastUserMessage() {
        guard !isStreaming else { return }
        guard let lastUserIdx = messages.lastIndex(where: { $0.role == .user }) else { return }
        let lastUser = messages[lastUserIdx]
        messages.removeSubrange(lastUserIdx..<messages.count)
        inputText = lastUser.content
        if !lastUser.attachedImages.isEmpty {
            attachedImages = lastUser.attachedImages
        }
        errorMessage = nil
        persistCurrentSession()
        PanelController.shared.focusTrigger.send()
    }

    /// Exports the active conversation as clean Markdown and copies it to the macOS pasteboard.
    @discardableResult
    public func copyCurrentConversationMarkdown() -> Bool {
        guard !messages.isEmpty else { return false }
        let tempSession = ConversationSession(
            id: currentSessionId,
            title: ConversationSession.makeTitle(from: messages),
            createdAt: messages.first?.timestamp ?? Date(),
            updatedAt: Date(),
            provider: SettingsStore.shared.selectedProvider.rawValue,
            model: SettingsStore.shared.effectiveModelIdForExecution,
            agyConversationId: currentAGYConversationId,
            messages: messages
        )
        let md = ConversationStore.shared.formatSessionMarkdown(tempSession)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
        return true
    }

    /// Inserts or replaces an inline divider when the user switches models mid-conversation,
    /// queues a context note for the next turn, and defers live model mutation if currently streaming.
    public func handleModelSwitch(from oldModel: String, to newModel: String, newModelId: String) {
        guard !newModel.isEmpty, oldModel != newModel else { return }

        if isStreaming {
            pendingModelId = newModelId
            pendingModelSwitchBanner = "Model switch to \(newModel) will be performed on next turn"
        } else {
            SettingsStore.shared.currentModel = newModelId
            pendingModelId = nil
            pendingModelSwitchBanner = nil
        }

        guard !messages.isEmpty else { return }

        // If the user switched models again without sending a turn in between, replace the previous divider
        if let last = messages.last, last.role == .system, last.content.hasPrefix("Switched to:") {
            messages.removeLast()
        }

        let dividerMsg = ChatMessage(role: .system, content: "Switched to: \(newModel)")
        messages.append(dividerMsg)
        pendingModelSwitchNote = "The user switched the active model from '\(oldModel)' to '\(newModel)'. Continue the conversation seamlessly with full awareness of this model change."
        persistCurrentSession()
    }

    public func toggleHistory() {
        showHistory.toggle()
        let shouldExpand = !messages.isEmpty || errorMessage != nil || activeToolStatus != nil || showHistory
        PanelController.shared.syncPanelHeight(hasMessages: shouldExpand)
    }

    public func persistCurrentSession() {
        let meaningfulMessages = messages.filter { msg in
            switch msg.role {
            case .user, .tool:
                return true
            case .assistant:
                return !msg.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !(msg.reasoningContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || !(msg.toolCalls ?? []).isEmpty
            case .system:
                return false
            }
        }
        guard !meaningfulMessages.isEmpty else { return }
        let settings = SettingsStore.shared
        ConversationStore.shared.upsertSession(
            id: currentSessionId,
            messages: meaningfulMessages,
            provider: settings.selectedProvider.rawValue,
            model: settings.currentModel,
            agyConversationId: currentAGYConversationId
        )
    }

    private func runAgentLoop() async {
        let settings = SettingsStore.shared

        if settings.selectedProvider == .antigravity {
            await runAGYTurn()
            return
        }

        let maxToolTurns = 6
        var turnCount = 0

        while turnCount < maxToolTurns {
            turnCount += 1
            if Task.isCancelled { break }

            let assistantPlaceholder = ChatMessage(role: .assistant, content: "")
            messages.append(assistantPlaceholder)
            let assistantIndex = messages.count - 1

            let historySnapshot = Array(messages.dropLast())
            let provider = settings.selectedProvider
            let model = settings.currentModel
            let baseURL = settings.currentBaseURL
            let apiKey = settings.apiKey(for: provider)
            let effort: String? = settings.effectiveReasoningEffortForAPI

            do {
                let result = try await client.streamTurn(
                    messages: historySnapshot,
                    provider: provider,
                    model: model,
                    baseURL: baseURL,
                    apiKey: apiKey,
                    systemPrompt: settings.effectiveSystemPrompt(),
                    temperature: settings.temperature,
                    reasoningEffort: effort,
                    enableServerSideSearch: settings.enableServerSideSearch
                ) { [weak self] partialContent, partialReasoning in
                    guard let self = self, assistantIndex < self.messages.count else { return }
                    self.messages[assistantIndex].content = partialContent
                    if !partialReasoning.isEmpty {
                        self.messages[assistantIndex].reasoningContent = partialReasoning
                    }
                }

                if Task.isCancelled { break }

                messages[assistantIndex].content = result.content
                if !result.reasoningContent.isEmpty {
                    messages[assistantIndex].reasoningContent = result.reasoningContent
                }
                persistCurrentSession()

                if !result.toolCalls.isEmpty {
                    messages[assistantIndex].toolCalls = result.toolCalls

                    for call in result.toolCalls {
                        if Task.isCancelled { break }
                        activeToolStatus = Self.friendlyToolStatus(for: call.name)
                        let record = await ToolExecutor.execute(call)
                        if Task.isCancelled { break }

                        let toolResultMsg = ChatMessage(
                            role: .tool,
                            content: record.output,
                            toolCallId: call.id,
                            toolName: call.name,
                            toolRecords: [record]
                        )
                        messages.append(toolResultMsg)
                        persistCurrentSession()
                    }
                    activeToolStatus = nil
                    continue
                } else {
                    break
                }
            } catch is CancellationError {
                persistCurrentSession()
                break
            } catch {
                if assistantIndex < messages.count && messages[assistantIndex].content.isEmpty {
                    messages.remove(at: assistantIndex)
                }
                errorMessage = error.localizedDescription
                persistCurrentSession()
                break
            }
        }

        activeToolStatus = nil
        isStreaming = false
        if let queuedModelId = pendingModelId {
            SettingsStore.shared.currentModel = queuedModelId
            pendingModelId = nil
            pendingModelSwitchBanner = nil
        }
        persistCurrentSession()
    }

    /// Executes a single turn via the local `agy` CLI (`--output-format stream-json`),
    /// streaming tokens and tool calls chronologically with 0 MB idle RAM after the turn ends.
    private func runAGYTurn() async {
        let settings = SettingsStore.shared
        guard let lastUserMsg = messages.last(where: { $0.role == .user }) else {
            isStreaming = false
            return
        }

        var promptParts: [String] = []
        if currentAGYConversationId == nil {
            promptParts.append("[Host Context: \(settings.sparkBarContextNoteForAGY)]")
        }
        if let note = lastUserMsg.systemNote, !note.isEmpty {
            promptParts.append("[System Note: \(note)]")
        }
        if !lastUserMsg.attachedImages.isEmpty {
            let paths = lastUserMsg.attachedImages.compactMap { $0.localFilePath }.filter { !$0.isEmpty }
            if !paths.isEmpty {
                promptParts.append("[Attached image file(s) — inspect with view_file if needed: \(paths.joined(separator: ", "))]")
            }
        }
        if !lastUserMsg.content.isEmpty {
            promptParts.append(lastUserMsg.content)
        }
        let fullPrompt = promptParts.joined(separator: "\n\n")

        // Insert initial streaming placeholder
        let placeholder = ChatMessage(role: .assistant, content: "")
        messages.append(placeholder)
        var stepToMessageId: [Int: UUID] = [:]
        var initialPlaceholderId: UUID? = placeholder.id
        var sawAnyText = false

        do {
            try await AGYCLIRunner.shared.streamTurn(
                prompt: fullPrompt,
                model: settings.effectiveModelIdForExecution,
                conversationId: currentAGYConversationId,
                allowTools: settings.enableTools,
                customBinaryPath: settings.agyCustomBinaryPath,
                portableRoot: settings.agyPortableRootPath,
                workingDirectory: JobManager.shared.currentWorkingDirectory
            ) { [weak self] event in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    switch event {
                    case .initialized(let convId):
                        self.currentAGYConversationId = convId

                    case .textDelta(let stepIndex, let delta):
                        sawAnyText = true
                        self.activeToolStatus = nil

                        if let msgId = stepToMessageId[stepIndex],
                           let idx = self.messages.firstIndex(where: { $0.id == msgId }) {
                            self.messages[idx].content += delta
                        } else if let placeholderId = initialPlaceholderId,
                                  let idx = self.messages.firstIndex(where: { $0.id == placeholderId }),
                                  self.messages[idx].content.isEmpty {
                            self.messages[idx].content = delta
                            stepToMessageId[stepIndex] = placeholderId
                            initialPlaceholderId = nil
                        } else {
                            let newMsg = ChatMessage(role: .assistant, content: delta)
                            self.messages.append(newMsg)
                            stepToMessageId[stepIndex] = newMsg.id
                        }

                    case .toolStarted(_, let toolName, _):
                        // Remove unused empty placeholder if the model went straight into a tool call
                        if let placeholderId = initialPlaceholderId,
                           let idx = self.messages.firstIndex(where: { $0.id == placeholderId }),
                           self.messages[idx].content.isEmpty {
                            self.messages.remove(at: idx)
                            initialPlaceholderId = nil
                        }
                        self.activeToolStatus = Self.friendlyToolStatus(for: toolName)

                    case .toolCompleted(_, let record):
                        self.activeToolStatus = nil
                        if let placeholderId = initialPlaceholderId,
                           let idx = self.messages.firstIndex(where: { $0.id == placeholderId }),
                           self.messages[idx].content.isEmpty {
                            self.messages.remove(at: idx)
                            initialPlaceholderId = nil
                        }
                        let toolMsg = ChatMessage(
                            role: .tool,
                            content: record.output,
                            toolCallId: record.toolCallId,
                            toolName: record.toolName,
                            toolRecords: [record]
                        )
                        self.messages.append(toolMsg)
                        self.persistCurrentSession()

                    case .finished(let convId, let finalResponse, _):
                        if let convId = convId, !convId.isEmpty {
                            self.currentAGYConversationId = convId
                        }
                        if !sawAnyText, let response = finalResponse, !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            if let placeholderId = initialPlaceholderId,
                               let idx = self.messages.firstIndex(where: { $0.id == placeholderId }) {
                                self.messages[idx].content = response
                                initialPlaceholderId = nil
                            } else {
                                self.messages.append(ChatMessage(role: .assistant, content: response))
                            }
                        }
                        self.persistCurrentSession()
                    }
                }
            }
        } catch is CancellationError {
            persistCurrentSession()
        } catch {
            if let placeholderId = initialPlaceholderId,
               let idx = messages.firstIndex(where: { $0.id == placeholderId }),
               messages[idx].content.isEmpty {
                messages.remove(at: idx)
            }
            errorMessage = error.localizedDescription
            persistCurrentSession()
        }

        // Clean up any trailing empty placeholder
        if let placeholderId = initialPlaceholderId,
           let idx = messages.firstIndex(where: { $0.id == placeholderId }),
           messages[idx].content.isEmpty {
            messages.remove(at: idx)
        }

        activeToolStatus = nil
        isStreaming = false
        if let queuedModelId = pendingModelId {
            SettingsStore.shared.currentModel = queuedModelId
            pendingModelId = nil
            pendingModelSwitchBanner = nil
        }
        persistCurrentSession()
    }

    private static func friendlyToolStatus(for toolName: String) -> String {
        switch toolName.lowercased() {
        case "web_search", "search_web":
            return "Searching…"
        case "fetch_url", "read_url_content":
            return "Reading page…"
        case "run_command":
            return "Running command…"
        default:
            return "Running \(toolName)…"
        }
    }
}
