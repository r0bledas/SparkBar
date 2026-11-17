import SwiftUI
import AppKit

/// Native macOS Visual Effect blur material wrapper for our Spotlight panel.
public struct VisualEffectBlur: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public var blendingMode: NSVisualEffectView.BlendingMode
    public var state: NSVisualEffectView.State

    public init(
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow,
        state: NSVisualEffectView.State = .active
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.state = state
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = true
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

public enum MarkdownBlock: Identifiable, Equatable {
    case text(id: Int, content: String)
    case code(id: Int, language: String, code: String)

    public var id: Int {
        switch self {
        case .text(let id, _): return id
        case .code(let id, _, _): return id
        }
    }
}

public struct MarkdownMessageView: View {
    public let text: String
    @State private var copiedBlockId: Int? = nil

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        let blocks = Self.parseBlocks(from: text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                switch block {
                case .text(_, let content):
                    ForEach(Array(content.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                        let trimmed = paragraph.trimmingCharacters(in: .newlines)
                        if !trimmed.isEmpty {
                            renderedParagraph(trimmed)
                        }
                    }
                case .code(let id, let lang, let codeContent):
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(lang.isEmpty ? "code" : lang.lowercased())
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(codeContent, forType: .string)
                                copiedBlockId = id
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    if copiedBlockId == id {
                                        copiedBlockId = nil
                                    }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: copiedBlockId == id ? "checkmark" : "doc.on.doc")
                                        .font(.system(size: 10, weight: .medium))
                                    Text(copiedBlockId == id ? "Copied" : "Copy")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundStyle(copiedBlockId == id ? Color.green : Color.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Copy code block")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.22))

                        ScrollView(.horizontal, showsIndicators: true) {
                            Text(codeContent)
                                .font(.system(size: 12.5, weight: .regular, design: .monospaced))
                                .foregroundStyle(.primary.opacity(0.95))
                                .textSelection(.enabled)
                                .padding(12)
                        }
                    }
                    .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func renderedParagraph(_ paragraph: String) -> some View {
        if let attributed = try? AttributedString(
            markdown: paragraph,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .font(.system(size: 14, weight: .regular))
                .lineSpacing(3)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        } else {
            Text(paragraph)
                .font(.system(size: 14, weight: .regular))
                .lineSpacing(3)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

    public static func parseBlocks(from markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = markdown.components(separatedBy: "\n")
        var inCodeBlock = false
        var currentLang = ""
        var currentLines: [String] = []
        var blockIndex = 0

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                let fence = line.trimmingCharacters(in: .whitespaces)
                if inCodeBlock {
                    blocks.append(.code(id: blockIndex, language: currentLang, code: currentLines.joined(separator: "\n")))
                    blockIndex += 1
                    currentLines.removeAll()
                    currentLang = ""
                    inCodeBlock = false
                } else {
                    if !currentLines.isEmpty {
                        blocks.append(.text(id: blockIndex, content: currentLines.joined(separator: "\n")))
                        blockIndex += 1
                        currentLines.removeAll()
                    }
                    currentLang = String(fence.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inCodeBlock = true
                }
            } else {
                currentLines.append(line)
            }
        }

        if !currentLines.isEmpty {
            if inCodeBlock {
                blocks.append(.code(id: blockIndex, language: currentLang, code: currentLines.joined(separator: "\n")))
            } else {
                blocks.append(.text(id: blockIndex, content: currentLines.joined(separator: "\n")))
            }
        }

        return blocks
    }
}
