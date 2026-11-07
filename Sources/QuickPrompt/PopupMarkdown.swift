import AppKit
import SwiftUI
import Textual

/// How Markdown from a model looks in the popup: the body size and colour come from the popup, headings stay close to
/// the body size (the popup is small), and the other blocks use Textual's defaults in their dark variant.
struct PopupMarkdownStyle: StructuredText.Style {
    let lineSpacing: CGFloat

    let inlineStyle: InlineStyle = .default
    var headingStyle: PopupHeadingStyle { PopupHeadingStyle(lineSpacing: lineSpacing) }
    var paragraphStyle: PopupParagraphStyle { PopupParagraphStyle(lineSpacing: lineSpacing) }
    let blockQuoteStyle: StructuredText.DefaultBlockQuoteStyle = .default
    let codeBlockStyle: StructuredText.DefaultCodeBlockStyle = .default
    let listItemStyle: StructuredText.DefaultListItemStyle = .default(markerSpacing: .fontScaled(0.45))
    let unorderedListMarker = PopupBulletMarker()
    let orderedListMarker = PopupNumberMarker()
    let tableStyle: StructuredText.DefaultTableStyle = .default
    let tableCellStyle: StructuredText.DefaultTableCellStyle = .default
    let thematicBreakStyle: StructuredText.DividerThematicBreakStyle = .divider
}

/// A list marker starts at the same edge as the popup's title and text, not indented as in Textual's default; a
/// nested list starts where its parent item's text starts.
struct PopupBulletMarker: StructuredText.UnorderedListMarker {
    func makeBody(configuration: Configuration) -> some View {
        Text("•")
    }
}

struct PopupNumberMarker: StructuredText.OrderedListMarker {
    func makeBody(configuration: Configuration) -> some View {
        // A width of "9." keeps the text of items 1 to 9 in one column.
        Text("\(configuration.ordinal).")
            .monospacedDigit()
            .textual.frame(minWidth: .fontScaled(0.95), alignment: .leading)
    }
}

struct PopupParagraphStyle: StructuredText.ParagraphStyle {
    let lineSpacing: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineSpacing(lineSpacing)
            .textual.blockSpacing(.init(top: lineSpacing + 9))
    }
}

struct PopupHeadingStyle: StructuredText.HeadingStyle {
    let lineSpacing: CGFloat
    private static let fontScales: [CGFloat] = [1.3, 1.18, 1.08, 1, 1, 1]

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textual.fontScale(Self.fontScales[min(max(configuration.headingLevel, 1), 6) - 1])
            .lineSpacing(lineSpacing)
            .textual.blockSpacing(.fontScaled(top: 0.9, bottom: 0.2))
            .fontWeight(.semibold)
    }
}

/// The result text of the popup, with Markdown shown as formatting.
struct MarkdownBody: View {
    let text: String
    let fontSize: CGFloat
    let lineSpacing: CGFloat
    let color: Color

    var body: some View {
        StructuredText(markdown: PopupMarkdown.keepingLineBreaks(text))
            .textual.structuredTextStyle(PopupMarkdownStyle(lineSpacing: lineSpacing))
            // List items and paragraphs stand apart more clearly than the lines inside them, whatever the line
            // spacing set in Settings.
            .textual.listItemSpacing(.fontScaled(top: 0.5 + lineSpacing / max(fontSize, 1)))
            .font(.system(size: fontSize))
            .foregroundStyle(color)
            .environment(\.colorScheme, .dark)
    }
}

enum PopupMarkdown {
    /// In Markdown a single line break joins two lines into one paragraph. Results such as a translated address or a
    /// poem must keep their lines, so every single line break outside code blocks and tables becomes a hard break.
    static func keepingLineBreaks(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        var inFence = false
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                // Textual draws a "math" code block with its formula package, whose fonts the app does not ship
                // (it would stop the app); such a block is shown as ordinary code.
                if !inFence, trimmed.dropFirst(3).lowercased().hasPrefix("math") {
                    lines[index] = String(trimmed.prefix(3)) + "text"
                }
                inFence.toggle()
                continue
            }
            guard !inFence, index + 1 < lines.count, !trimmed.isEmpty, !trimmed.hasPrefix("|") else { continue }
            let next = lines[index + 1].trimmingCharacters(in: .whitespaces)
            // A break before a new block (an empty line, a list item, a heading, a quote, a table, a fence) is
            // already a break.
            if next.isEmpty || startsBlock(next) { continue }
            if !lines[index].hasSuffix("  ") && !lines[index].hasSuffix("\\") { lines[index] += "  " }
        }
        return lines.joined(separator: "\n")
    }

    private static func startsBlock(_ line: String) -> Bool {
        if line.hasPrefix("#") || line.hasPrefix(">") || line.hasPrefix("|") || line.hasPrefix("```")
            || line.hasPrefix("~~~") { return true }
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") { return true }
        if let dot = line.firstIndex(where: { $0 == "." || $0 == ")" }), dot > line.startIndex,
           line[line.startIndex..<dot].allSatisfy(\.isNumber), line[line.index(after: dot)...].hasPrefix(" ") {
            return true
        }
        return false
    }
}

/// Measures how tall the formatted text is at a given width, so the popup gets its height before it is drawn.
@MainActor
final class MarkdownMeasurer {
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 400),
                                  styleMask: [.borderless], backing: .buffered, defer: true)

    init() {
        window.contentView = hosting
        window.isReleasedWhenClosed = false
    }

    func height(of text: String, width: CGFloat, fontSize: CGFloat, lineSpacing: CGFloat) -> CGFloat {
        hosting.rootView = AnyView(
            MarkdownBody(text: text, fontSize: fontSize, lineSpacing: lineSpacing, color: .white)
                .frame(width: width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true))
        var height: CGFloat = 0
        // The text is parsed and the block spacing settled in later update passes; repeat until the size is stable.
        for _ in 0..<4 {
            hosting.layoutSubtreeIfNeeded()
            let next = hosting.fittingSize.height
            if next == height { break }
            height = next
        }
        return ceil(height)
    }
}

/// What a result puts on the clipboard. Formatting the model added (bold, lists, tables) goes as rich text for apps
/// that keep it, such as Notes and Mail, and as clean text without the marks for plain fields. A result whose
/// selected text was already Markdown, for example a README, is copied exactly as the model wrote it.
struct ClipboardResult {
    let plain: String
    let html: String?

    init(result: String, source: String) {
        guard !PopupMarkdown.hasMarkup(source), let parsed = PopupMarkdown.parse(result),
              PopupMarkdown.hasMarkup(parsed) else {
            plain = result
            html = nil
            return
        }
        let converted = MarkdownConverter(parsed)
        plain = converted.plain
        html = converted.html
    }

    @MainActor func write(to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        guard let html else {
            pasteboard.setString(plain, forType: .string)
            return
        }
        let page = "<html><head><meta charset=\"utf-8\"></head>"
            + "<body style=\"font-family: -apple-system, 'Helvetica Neue', sans-serif\">\(html)</body></html>"
        pasteboard.declareTypes([.html, .rtf, .string], owner: nil)
        pasteboard.setString(page, forType: .html)
        if let rich = NSAttributedString(html: Data(page.utf8), options: [.characterEncoding: String.Encoding.utf8.rawValue],
                                         documentAttributes: nil),
           let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:]) {
            pasteboard.setData(rtf, forType: .rtf)
        }
        pasteboard.setString(plain, forType: .string)
    }
}

extension PopupMarkdown {
    static func parse(_ text: String) -> AttributedString? {
        try? AttributedString(markdown: keepingLineBreaks(text), options: .init(interpretedSyntax: .full))
    }

    static func hasMarkup(_ text: String) -> Bool {
        parse(text).map(hasMarkup) ?? false
    }

    /// True when the text has any formatting: a block other than a plain paragraph, a link, or bold, italic, code or
    /// strikethrough. Line breaks alone do not count.
    static func hasMarkup(_ parsed: AttributedString) -> Bool {
        let marks: InlinePresentationIntent = [.emphasized, .stronglyEmphasized, .code, .strikethrough]
        return parsed.runs.contains { run in
            if let inline = run.inlinePresentationIntent, !inline.intersection(marks).isEmpty { return true }
            if run.link != nil { return true }
            return run.presentationIntent?.components.contains { $0.kind != .paragraph } ?? false
        }
    }
}

/// Turns parsed Markdown into HTML and into plain text without the marks: list items start with "•" or their number,
/// table cells are separated by tabs, and blocks by an empty line.
struct MarkdownConverter {
    private(set) var html = ""
    private(set) var plain = ""

    private var open: [PresentationIntent.IntentType] = []
    private var lastLeaf: [PresentationIntent.IntentType] = []

    init(_ parsed: AttributedString) {
        for run in parsed.runs {
            let path = Array((run.presentationIntent?.components ?? []).reversed())
            enter(path)
            appendInline(String(parsed[run.range].characters), run: run, path: path)
        }
        enter([])
        plain = plain.trimmingCharacters(in: .newlines)
    }

    // MARK: Blocks

    private mutating func enter(_ path: [PresentationIntent.IntentType]) {
        var common = 0
        while common < min(open.count, path.count), open[common].identity == path[common].identity { common += 1 }
        if common == open.count && common == path.count { return }
        for component in open[common...].reversed() { html += closeTag(component.kind, parent: parentKind(of: component)) }
        open.removeSubrange(common...)
        for index in common..<path.count {
            let component = path[index]
            html += openTag(component.kind, parent: index > 0 ? path[index - 1].kind : nil)
            open.append(component)
        }
        if !path.isEmpty { startPlainBlock(path) }
    }

    private func parentKind(of component: PresentationIntent.IntentType) -> PresentationIntent.Kind? {
        guard let index = open.firstIndex(where: { $0.identity == component.identity }), index > 0 else { return nil }
        return open[index - 1].kind
    }

    private func openTag(_ kind: PresentationIntent.Kind, parent: PresentationIntent.Kind?) -> String {
        switch kind {
        case .paragraph: return Self.isListItem(parent) || Self.isCell(parent) ? "" : "<p>"
        case .header(let level): return "<h\(level)>"
        case .orderedList: return "<ol>"
        case .unorderedList: return "<ul>"
        case .listItem: return "<li>"
        case .blockQuote: return "<blockquote>"
        case .codeBlock: return "<pre><code>"
        case .thematicBreak: return "<hr>"
        case .table: return "<table border=\"1\" cellpadding=\"4\" style=\"border-collapse: collapse\">"
        case .tableHeaderRow, .tableRow: return "<tr>"
        case .tableCell: return parent == .tableHeaderRow ? "<th>" : "<td>"
        @unknown default: return ""
        }
    }

    private func closeTag(_ kind: PresentationIntent.Kind, parent: PresentationIntent.Kind?) -> String {
        switch kind {
        case .paragraph: return Self.isListItem(parent) || Self.isCell(parent) ? "" : "</p>"
        case .header(let level): return "</h\(level)>"
        case .orderedList: return "</ol>"
        case .unorderedList: return "</ul>"
        case .listItem: return "</li>"
        case .blockQuote: return "</blockquote>"
        case .codeBlock: return "</code></pre>"
        case .table: return "</table>"
        case .tableHeaderRow, .tableRow: return "</tr>"
        case .tableCell: return parent == .tableHeaderRow ? "</th>" : "</td>"
        default: return ""
        }
    }

    private static func isListItem(_ kind: PresentationIntent.Kind?) -> Bool {
        if case .listItem = kind { return true }
        return false
    }

    private static func isCell(_ kind: PresentationIntent.Kind?) -> Bool {
        if case .tableCell = kind { return true }
        return false
    }

    /// Starts a new block of the plain text: a separator from the previous block, then a list marker if this is the
    /// first paragraph of a list item.
    private mutating func startPlainBlock(_ path: [PresentationIntent.IntentType]) {
        defer { lastLeaf = path }
        if !plain.isEmpty {
            let sameTable = path.first { if case .table = $0.kind { return true } else { return false } }
                .map { table in lastLeaf.contains { $0.identity == table.identity } } ?? false
            let sameRow = sameTable && path.dropLast().last.map { row in lastLeaf.contains { $0.identity == row.identity } } == true
            let sameList = path.first { if case .orderedList = $0.kind { return true }; if case .unorderedList = $0.kind { return true }; return false }
                .map { list in lastLeaf.contains { $0.identity == list.identity } } ?? false
            plain += sameRow ? "\t" : (sameTable || sameList) ? "\n" : "\n\n"
        }
        if case .thematicBreak = path.last?.kind { plain += "———"; return }
        // A list item's marker goes before its first paragraph; later paragraphs of the item are only indented.
        let lists = path.filter { if case .orderedList = $0.kind { return true }; if case .unorderedList = $0.kind { return true }; return false }
        guard let item = path.last(where: { if case .listItem = $0.kind { return true } else { return false } }) else { return }
        let indent = String(repeating: "    ", count: max(0, lists.count - 1))
        let firstInItem = !lastLeaf.contains { $0.identity == item.identity }
        guard firstInItem else { plain += indent + "  "; return }
        if case .listItem(let ordinal) = item.kind, let list = lists.last, case .orderedList = list.kind {
            plain += indent + "\(ordinal). "
        } else {
            plain += indent + "• "
        }
    }

    // MARK: Inline text

    private mutating func appendInline(_ text: String, run: AttributedString.Runs.Run, path: [PresentationIntent.IntentType]) {
        let inCode = path.contains { if case .codeBlock = $0.kind { return true } else { return false } }
        var piece = Self.escape(text)
        if inCode {
            html += piece
            plain += text.hasSuffix("\n") ? String(text.dropLast()) : text
            return
        }
        let inline = run.inlinePresentationIntent ?? []
        if inline.contains(.lineBreak) { piece = "<br>" }
        if inline.contains(.code) { piece = "<code>\(piece)</code>" }
        if inline.contains(.strikethrough) { piece = "<s>\(piece)</s>" }
        if inline.contains(.emphasized) { piece = "<i>\(piece)</i>" }
        if inline.contains(.stronglyEmphasized) { piece = "<b>\(piece)</b>" }
        if let link = run.link { piece = "<a href=\"\(Self.escape(link.absoluteString))\">\(piece)</a>" }
        html += piece
        plain += text
        if let link = run.link, link.absoluteString != text { plain += " (\(link.absoluteString))" }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
