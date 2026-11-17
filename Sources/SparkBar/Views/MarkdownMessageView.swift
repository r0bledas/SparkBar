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
    case table(id: Int, headers: [String], rows: [[String]], rawText: String)
    case asciiArt(id: Int, content: String)

    public var id: Int {
        switch self {
        case .text(let id, _): return id
        case .code(let id, _, _): return id
        case .table(let id, _, _, _): return id
        case .asciiArt(let id, _): return id
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

                case .table(_, let headers, let rows, _):
                    renderedMarkdownTable(headers: headers, rows: rows)

                case .asciiArt(_, let artContent):
                    ScrollView(.horizontal, showsIndicators: true) {
                        Text(artContent)
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(.primary.opacity(0.95))
                            .fixedSize(horizontal: true, vertical: true)
                            .textSelection(.enabled)
                            .padding(10)
                    }
                    .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                    )

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
                                .fixedSize(horizontal: true, vertical: true)
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
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func renderedMarkdownTable(headers: [String], rows: [[String]]) -> some View {
        let colCount = max(headers.count, rows.map(\.count).max() ?? 0)
        if colCount > 0 {
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    // Header Row
                    if !headers.isEmpty {
                        HStack(spacing: 0) {
                            ForEach(0..<colCount, id: \.self) { colIdx in
                                let cellText = colIdx < headers.count ? headers[colIdx] : ""
                                inlineMarkdownText(cellText, font: .system(size: 12.5, weight: .semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)

                                if colIdx < colCount - 1 {
                                    Rectangle()
                                        .fill(Color.primary.opacity(0.14))
                                        .frame(width: 1)
                                }
                            }
                        }
                        .background(Color.primary.opacity(0.08))

                        Rectangle()
                            .fill(Color.primary.opacity(0.18))
                            .frame(height: 1)
                    }

                    // Data Rows with clean horizontal & vertical separators
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                        HStack(spacing: 0) {
                            ForEach(0..<colCount, id: \.self) { colIdx in
                                let cellText = colIdx < row.count ? row[colIdx] : ""
                                inlineMarkdownText(cellText, font: .system(size: 12.5, weight: .regular))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .frame(minWidth: 110, maxWidth: .infinity, alignment: .leading)

                                if colIdx < colCount - 1 {
                                    Rectangle()
                                        .fill(Color.primary.opacity(0.10))
                                        .frame(width: 1)
                                }
                            }
                        }
                        .background(rowIdx.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.035))

                        if rowIdx < rows.count - 1 {
                            Rectangle()
                                .fill(Color.primary.opacity(0.12))
                                .frame(height: 1)
                        }
                    }
                }
                .background(Color.black.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
                )
            }
            .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func inlineMarkdownText(_ raw: String, font: Font) -> some View {
        if let attributed = try? AttributedString(
            markdown: raw,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .font(font)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        } else {
            Text(raw)
                .font(font)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
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

    // MARK: - Block Parser (Code blocks, Markdown pipe tables, ASCII box tables, and prose)

    public static func parseBlocks(from markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = markdown.components(separatedBy: "\n")
        var inCodeBlock = false
        var currentLang = ""
        var currentLines: [String] = []
        var blockIndex = 0

        for line in lines {
            let trimmedFence = line.trimmingCharacters(in: .whitespaces)
            if trimmedFence.hasPrefix("```") {
                if inCodeBlock {
                    blocks.append(.code(id: blockIndex, language: currentLang, code: currentLines.joined(separator: "\n")))
                    blockIndex += 1
                    currentLines.removeAll()
                    currentLang = ""
                    inCodeBlock = false
                } else {
                    if !currentLines.isEmpty {
                        appendNonCodeBlocks(from: currentLines, into: &blocks, nextId: &blockIndex)
                        currentLines.removeAll()
                    }
                    currentLang = String(trimmedFence.dropFirst(3)).trimmingCharacters(in: .whitespaces)
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
                appendNonCodeBlocks(from: currentLines, into: &blocks, nextId: &blockIndex)
            }
        }

        return blocks
    }

    private static func appendNonCodeBlocks(from lines: [String], into blocks: inout [MarkdownBlock], nextId: inout Int) {
        var idx = 0
        var normalBuffer: [String] = []

        func flushNormalBuffer() {
            guard !normalBuffer.isEmpty else { return }
            let joined = normalBuffer.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.text(id: nextId, content: joined))
                nextId += 1
            }
            normalBuffer.removeAll()
        }

        while idx < lines.count {
            let line = lines[idx]

            // 1. Check for ASCII box-drawing or `+---+---+` table blocks
            if isASCIIBoxTableLine(line) {
                var asciiLines: [String] = [line]
                var j = idx + 1
                while j < lines.count && (isASCIIBoxTableLine(lines[j]) || isPipeRowLine(lines[j])) {
                    asciiLines.append(lines[j])
                    j += 1
                }
                if asciiLines.count >= 2 {
                    flushNormalBuffer()
                    blocks.append(.asciiArt(id: nextId, content: asciiLines.joined(separator: "\n")))
                    nextId += 1
                    idx = j
                    continue
                }
            }

            // 2. Check for Markdown Pipe Table (`| Header | ... |` followed by `| --- | --- |`)
            if idx + 1 < lines.count,
               isPipeRowLine(line),
               isMarkdownTableSeparatorLine(lines[idx + 1]) {
                var tableLines: [String] = [line, lines[idx + 1]]
                var j = idx + 2
                while j < lines.count && isPipeRowLine(lines[j]) {
                    tableLines.append(lines[j])
                    j += 1
                }
                flushNormalBuffer()
                let headers = splitPipeCells(tableLines[0])
                var rows: [[String]] = []
                for rowLine in tableLines.dropFirst(2) {
                    if !isMarkdownTableSeparatorLine(rowLine) {
                        rows.append(splitPipeCells(rowLine))
                    }
                }
                blocks.append(.table(id: nextId, headers: headers, rows: rows, rawText: tableLines.joined(separator: "\n")))
                nextId += 1
                idx = j
                continue
            }

            normalBuffer.append(line)
            idx += 1
        }

        flushNormalBuffer()
    }

    private static func isASCIIBoxTableLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        // Box drawing characters: ┌ ┬ ┐ ├ ┼ ┤ └ ┴ ┘ │ ─ ╔ ╦ ╗ ╠ ╬ ╣ ╚ ╩ ╝ ║ ═
        let boxChars = CharacterSet(charactersIn: "┌┬┐├┼┤└┴┘│─╔╦╗╠╬╣╚╩╝║═")
        if trimmed.unicodeScalars.contains(where: { boxChars.contains($0) }) {
            return true
        }
        // Classic ASCII `+---+---+` border line
        if trimmed.hasPrefix("+") && trimmed.hasSuffix("+") && trimmed.contains("-") {
            return true
        }
        return false
    }

    private static func isPipeRowLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return false }
        let pipeCount = trimmed.filter { $0 == "|" }.count
        return pipeCount >= 2 || (trimmed.hasPrefix("|") && trimmed.hasSuffix("|"))
    }

    private static func isMarkdownTableSeparatorLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") && trimmed.contains("-") else { return false }
        let allowed = CharacterSet(charactersIn: "|-: \t")
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    private static func splitPipeCells(_ line: String) -> [String] {
        var working = line.trimmingCharacters(in: .whitespaces)
        if working.hasPrefix("|") { working.removeFirst() }
        if working.hasSuffix("|") { working.removeLast() }
        return working.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
