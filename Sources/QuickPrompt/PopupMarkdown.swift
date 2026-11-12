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
