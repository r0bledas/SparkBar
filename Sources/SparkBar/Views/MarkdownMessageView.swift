import SwiftUI
import AppKit
import WebKit

/// Native KaTeX WebKit MathView for crisp, real LaTeX mathematical typesetting (fractions, matrices, integrals, roots).
public struct NativeLaTeXBlockView: NSViewRepresentable {
    public let latex: String
    @Binding public var dynamicHeight: CGFloat

    public init(latex: String, dynamicHeight: Binding<CGFloat>) {
        self.latex = latex
        self._dynamicHeight = dynamicHeight
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let wv = NonScrollingWKWebView(frame: .zero, configuration: config)
        wv.setValue(false, forKey: "drawsBackground")
        wv.navigationDelegate = context.coordinator
        context.coordinator.lastLoadedLatex = latex
        wv.loadHTMLString(Self.htmlTemplate(for: latex), baseURL: URL(string: "https://cdn.jsdelivr.net"))
        return wv
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {
        if context.coordinator.lastLoadedLatex != latex {
            context.coordinator.lastLoadedLatex = latex
            nsView.loadHTMLString(Self.htmlTemplate(for: latex), baseURL: URL(string: "https://cdn.jsdelivr.net"))
        }
    }

    public final class NonScrollingWKWebView: WKWebView {
        public override func scrollWheel(with event: NSEvent) {
            nextResponder?.scrollWheel(with: event)
        }
    }

    public final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: NativeLaTeXBlockView
        var lastLoadedLatex: String = ""

        init(_ parent: NativeLaTeXBlockView) {
            self.parent = parent
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                if let h = try? await webView.evaluateJavaScript("document.getElementById('math-root').scrollHeight") as? CGFloat, h > 10 {
                    parent.dynamicHeight = min(max(h + 16, 44), 320)
                }
            }
        }
    }

    private static func htmlTemplate(for rawLatex: String) -> String {
        let escaped = rawLatex
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css">
        <script src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
        <style>
            * { box-sizing: border-box; }
            html, body {
                margin: 0;
                padding: 0;
                background: transparent;
                color: rgba(255, 255, 255, 0.94);
                font-family: -apple-system, BlinkMacSystemFont, serif;
                overflow-x: auto;
                overflow-y: hidden;
            }
            #math-root {
                display: flex;
                justify-content: center;
                align-items: center;
                padding: 8px 12px;
                font-size: 1.08em;
            }
        </style>
        </head>
        <body>
        <div id="math-root"></div>
        <script>
            try {
                katex.render(`\(escaped)`, document.getElementById('math-root'), {
                    displayMode: true,
                    throwOnError: false
                });
            } catch (e) {
                document.getElementById('math-root').innerText = `\(escaped)`;
            }
        </script>
        </body>
        </html>
        """
    }
}

public struct MathBlockContainerView: View {
    public let latex: String
    @State private var height: CGFloat = 56

    public var body: some View {
        NativeLaTeXBlockView(latex: latex, dynamicHeight: $height)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
            )
    }
}

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
    case heading(id: Int, level: Int, title: String)
    case horizontalRule(id: Int)
    case blockquote(id: Int, content: String)
    case mathBlock(id: Int, latex: String)
    case code(id: Int, language: String, code: String)
    case table(id: Int, headers: [String], rows: [[String]], rawText: String)
    case asciiArt(id: Int, content: String)

    public var id: Int {
        switch self {
        case .text(let id, _): return id
        case .heading(let id, _, _): return id
        case .horizontalRule(let id): return id
        case .blockquote(let id, _): return id
        case .mathBlock(let id, _): return id
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

                case .heading(_, let level, let title):
                    renderedHeading(level: level, title: title)

                case .horizontalRule:
                    // Subtle bot-sent horizontal rule (`---`), matching the gentle separator style
                    Divider()
                        .opacity(0.35)
                        .padding(.vertical, 4)

                case .blockquote(_, let quoteText):
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.accentColor.opacity(0.75))
                            .frame(width: 3)
                        inlineMarkdownText(quoteText, font: .system(size: 13.5, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)

                case .mathBlock(_, let latex):
                    MathBlockContainerView(latex: latex)

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
    private func renderedHeading(level: Int, title: String) -> some View {
        let size: CGFloat = switch level {
        case 1: 18
        case 2: 16
        case 3: 14.5
        default: 13.5
        }
        inlineMarkdownText(title, font: .system(size: size, weight: .bold))
            .padding(.top, level <= 2 ? 4 : 2)
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
        let processed = Self.convertInlineLaTeXInText(raw)
        if let attributed = try? AttributedString(
            markdown: processed,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .font(font)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        } else {
            Text(processed)
                .font(font)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func renderedParagraph(_ paragraph: String) -> some View {
        let processed = Self.convertInlineLaTeXInText(paragraph)
        if let attributed = try? AttributedString(
            markdown: processed,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .font(.system(size: 14, weight: .regular))
                .lineSpacing(3)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        } else {
            Text(processed)
                .font(.system(size: 14, weight: .regular))
                .lineSpacing(3)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

    // MARK: - LaTeX to Unicode Mathematical Formatter

    public static func convertInlineLaTeXInText(_ input: String) -> String {
        var result = input

        // Replace `\[ ... \]` and `$$ ... $$` inline occurrences
        result = replaceRegexMatches(in: result, pattern: #"\$\$([\s\S]*?)\$\$"#) { inner in
            renderLaTeXToUnicode(inner)
        }
        result = replaceRegexMatches(in: result, pattern: #"\\\[([\s\S]*?)\\\]"#) { inner in
            renderLaTeXToUnicode(inner)
        }
        // Replace `\(...\)`
        result = replaceRegexMatches(in: result, pattern: #"\\\((.*?)\\\)"#) { inner in
            renderLaTeXToUnicode(inner)
        }
        // Replace `$ ... $` (single-line inline math, avoiding currency like `$100` followed by space)
        result = replaceRegexMatches(in: result, pattern: #"\$([^\$\n]+?)\$"#) { inner in
            renderLaTeXToUnicode(inner)
        }
        return result
    }

    private static func replaceRegexMatches(in text: String, pattern: String, transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var out = text
        let matches = regex.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed()
        for match in matches {
            if match.numberOfRanges >= 2,
               let fullRange = Range(match.range(at: 0), in: out),
               let innerRange = Range(match.range(at: 1), in: out) {
                let inner = String(out[innerRange])
                let replacement = transform(inner)
                out.replaceSubrange(fullRange, with: replacement)
            }
        }
        return out
    }

    public static func renderLaTeXToUnicode(_ latex: String) -> String {
        var s = latex.trimmingCharacters(in: .whitespacesAndNewlines)

        let symbolMap: [(String, String)] = [
            ("\\left(", "("), ("\\right)", ")"),
            ("\\left[", "["), ("\\right]", "]"),
            ("\\left\\{", "{"), ("\\right\\}", "}"),
            ("\\leftrightarrow", "↔"), ("\\Leftrightarrow", "⇔"),
            ("\\rightarrow", "→"), ("\\to", "→"), ("\\Rightarrow", "⇒"),
            ("\\leftarrow", "←"), ("\\Leftarrow", "⇐"),
            ("\\mapsto", "↦"), ("\\implies", "⟹"), ("\\iff", "⟺"),
            ("\\approx", "≈"), ("\\neq", "≠"), ("\\ne", "≠"),
            ("\\leq", "≤"), ("\\le", "≤"), ("\\geq", "≥"), ("\\ge", "≥"),
            ("\\pm", "±"), ("\\mp", "∓"), ("\\times", "×"), ("\\cdot", "·"), ("\\div", "÷"),
            ("\\infty", "∞"), ("\\partial", "∂"), ("\\nabla", "∇"),
            ("\\sum", "∑"), ("\\prod", "∏"), ("\\int", "∫"), ("\\oint", "∮"),
            ("\\forall", "∀"), ("\\exists", "∃"), ("\\nexists", "∄"),
            ("\\in", "∈"), ("\\notin", "∉"), ("\\subset", "⊂"), ("\\subseteq", "⊆"),
            ("\\cup", "∪"), ("\\cap", "∩"), ("\\emptyset", "∅"),
            ("\\mathbb{R}", "ℝ"), ("\\mathbb{N}", "ℕ"), ("\\mathbb{Z}", "ℤ"), ("\\mathbb{Q}", "ℚ"), ("\\mathbb{C}", "ℂ"),
            ("\\alpha", "α"), ("\\beta", "β"), ("\\gamma", "γ"), ("\\delta", "δ"),
            ("\\epsilon", "ϵ"), ("\\varepsilon", "ε"), ("\\zeta", "ζ"), ("\\eta", "η"),
            ("\\theta", "θ"), ("\\iota", "ι"), ("\\kappa", "κ"), ("\\lambda", "λ"),
            ("\\mu", "μ"), ("\\nu", "ν"), ("\\xi", "ξ"), ("\\pi", "π"),
            ("\\rho", "ρ"), ("\\sigma", "σ"), ("\\tau", "τ"), ("\\upsilon", "υ"),
            ("\\phi", "ϕ"), ("\\varphi", "φ"), ("\\chi", "χ"), ("\\psi", "ψ"), ("\\omega", "ω"),
            ("\\Gamma", "Γ"), ("\\Delta", "Δ"), ("\\Theta", "Θ"), ("\\Lambda", "Λ"),
            ("\\Xi", "Ξ"), ("\\Pi", "Π"), ("\\Sigma", "Σ"), ("\\Phi", "Φ"), ("\\Psi", "Ψ"), ("\\Omega", "Ω"),
            ("\\dots", "…"), ("\\ldots", "…"), ("\\cdots", "⋯"),
            ("\\quad", "  "), ("\\,", " "), ("\\;", " "), ("\\!", "")
        ]

        for (cmd, sym) in symbolMap {
            s = s.replacingOccurrences(of: cmd, with: sym)
        }

        // Superscripts `^{...}` and `^x`
        s = replaceRegexMatches(in: s, pattern: #"\^\{([^{}]+)\}"#) { exp in
            mapSuperscript(exp)
        }
        s = replaceRegexMatches(in: s, pattern: #"\^([0-9a-zA-Z\+\-\=])"#) { exp in
            mapSuperscript(exp)
        }

        // Subscripts `_{...}` and `_x`
        s = replaceRegexMatches(in: s, pattern: #"_\{([^{}]+)\}"#) { sub in
            mapSubscript(sub)
        }
        s = replaceRegexMatches(in: s, pattern: #"_([0-9a-zA-Z\+\-\=])"#) { sub in
            mapSubscript(sub)
        }

        // Text / formatting macros `\text{...}`, `\mathrm{...}`, `\mathbf{...}`
        for macro in ["\\text", "\\mathrm", "\\mathbf", "\\mathit", "\\mathcal", "\\operatorname"] {
            s = replaceOneArgMacro(in: s, macro: macro) { $0 }
        }

        // `\sqrt{x}` -> `√(x)` (inside-out)
        s = replaceOneArgMacro(in: s, macro: "\\sqrt") { x in
            x.count <= 2 ? "√\(x)" : "√(\(x))"
        }

        // `\frac{a}{b}` -> `(a)/(b)` (inside-out)
        s = replaceTwoArgMacro(in: s, macro: "\\frac") { a, b in
            let left = a.count <= 2 ? a : "(\(a))"
            let right = b.count <= 2 ? b : "(\(b))"
            return "\(left)/\(right)"
        }

        // Remove leftover curly braces used for grouping
        s = s.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        return s
    }

    private static func replaceOneArgMacro(in text: String, macro: String, transform: (String) -> String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: macro)
        var out = text
        for _ in 0..<5 {
            let next = replaceRegexMatches(in: out, pattern: "\(escaped)\\{([^{}]*)\\}", transform: transform)
            if next == out { break }
            out = next
        }
        return out
    }

    private static func replaceTwoArgMacro(in text: String, macro: String, transform: (String, String) -> String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: macro)
        guard let regex = try? NSRegularExpression(pattern: "\(escaped)\\{([^{}]*)\\}\\{([^{}]*)\\}") else { return text }
        var out = text
        for _ in 0..<5 {
            let matches = regex.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed()
            if matches.isEmpty { break }
            for match in matches {
                if match.numberOfRanges >= 3,
                   let fullRange = Range(match.range(at: 0), in: out),
                   let r1 = Range(match.range(at: 1), in: out),
                   let r2 = Range(match.range(at: 2), in: out) {
                    let rep = transform(String(out[r1]), String(out[r2]))
                    out.replaceSubrange(fullRange, with: rep)
                }
            }
        }
        return out
    }

    private static func mapSuperscript(_ str: String) -> String {
        let map: [Character: Character] = [
            "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
            "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
            "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
            "n": "ⁿ", "i": "ⁱ", "x": "ˣ", "y": "ʸ", "T": "ᵀ"
        ]
        var result = ""
        for ch in str {
            if let mapped = map[ch] {
                result.append(mapped)
            } else {
                return "^(\(str))"
            }
        }
        return result
    }

    private static func mapSubscript(_ str: String) -> String {
        let map: [Character: Character] = [
            "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄",
            "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
            "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎",
            "a": "ₐ", "e": "ₑ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ",
            "m": "ₘ", "n": "ₙ", "o": "ₒ", "p": "ₚ", "r": "ᵣ",
            "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ"
        ]
        var result = ""
        for ch in str {
            if let mapped = map[ch] {
                result.append(mapped)
            } else {
                return "_(\(str))"
            }
        }
        return result
    }

    // MARK: - Block Parser (Code blocks, Display Math, Headings, Rules, Blockquotes, Tables, ASCII art, and prose)

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
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 1. Horizontal Rule (`---`, `***`, `___`)
            if isHorizontalRuleLine(trimmed) {
                flushNormalBuffer()
                blocks.append(.horizontalRule(id: nextId))
                nextId += 1
                idx += 1
                continue
            }

            // 2. Markdown Heading (`# `, `## `, `### `, `#### `)
            if let (level, title) = parseHeadingLine(trimmed) {
                flushNormalBuffer()
                blocks.append(.heading(id: nextId, level: level, title: title))
                nextId += 1
                idx += 1
                continue
            }

            // 3. Display Math Block (`$$ ... $$` or `\[ ... \]`)
            if trimmed.hasPrefix("$$") || trimmed.hasPrefix("\\[") {
                let closingToken = trimmed.hasPrefix("$$") ? "$$" : "\\]"
                let openToken = trimmed.hasPrefix("$$") ? "$$" : "\\["
                if trimmed.count > openToken.count && trimmed.hasSuffix(closingToken) {
                    flushNormalBuffer()
                    let inner = String(trimmed.dropFirst(openToken.count).dropLast(closingToken.count))
                    blocks.append(.mathBlock(id: nextId, latex: inner))
                    nextId += 1
                    idx += 1
                    continue
                } else {
                    var mathLines: [String] = [String(trimmed.dropFirst(openToken.count))]
                    var j = idx + 1
                    while j < lines.count {
                        let candidate = lines[j].trimmingCharacters(in: .whitespaces)
                        if candidate.hasSuffix(closingToken) {
                            mathLines.append(String(candidate.dropLast(closingToken.count)))
                            j += 1
                            break
                        } else {
                            mathLines.append(lines[j])
                            j += 1
                        }
                    }
                    flushNormalBuffer()
                    blocks.append(.mathBlock(id: nextId, latex: mathLines.joined(separator: "\n")))
                    nextId += 1
                    idx = j
                    continue
                }
            }

            // 3b. Standalone single-line `$ ... $` equation line -> render in full KaTeX MathBlock
            if trimmed.hasPrefix("$") && trimmed.hasSuffix("$") && !trimmed.hasPrefix("$$") && trimmed.count > 2 {
                let inner = String(trimmed.dropFirst().dropLast())
                if !inner.contains("$") {
                    flushNormalBuffer()
                    blocks.append(.mathBlock(id: nextId, latex: inner))
                    nextId += 1
                    idx += 1
                    continue
                }
            }

            // 4. Blockquote (`> ...`)
            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                var j = idx
                while j < lines.count {
                    let qt = lines[j].trimmingCharacters(in: .whitespaces)
                    if qt.hasPrefix(">") {
                        quoteLines.append(String(qt.dropFirst()).trimmingCharacters(in: .whitespaces))
                        j += 1
                    } else {
                        break
                    }
                }
                flushNormalBuffer()
                blocks.append(.blockquote(id: nextId, content: quoteLines.joined(separator: "\n")))
                nextId += 1
                idx = j
                continue
            }

            // 5. Check for ASCII box-drawing or `+---+---+` table blocks
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

            // 6. Check for Markdown Pipe Table (`| Header | ... |` followed by `| --- | --- |`)
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

    private static func isHorizontalRuleLine(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        let chars = Set(trimmed.filter { !$0.isWhitespace })
        if chars.count == 1, let only = chars.first, (only == "-" || only == "*" || only == "_") {
            return trimmed.filter { $0 == only }.count >= 3
        }
        return false
    }

    private static func parseHeadingLine(_ trimmed: String) -> (Int, String)? {
        guard trimmed.hasPrefix("#") else { return nil }
        var level = 0
        for ch in trimmed {
            if ch == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let rest = String(trimmed.dropFirst(level))
        guard rest.first == " " else { return nil }
        let title = rest.trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : (level, title)
    }

    private static func isASCIIBoxTableLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        let boxChars = CharacterSet(charactersIn: "┌┬┐├┼┤└┴┘│─╔╦╗╠╬╣╚╩╝║═")
        if trimmed.unicodeScalars.contains(where: { boxChars.contains($0) }) {
            return true
        }
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
