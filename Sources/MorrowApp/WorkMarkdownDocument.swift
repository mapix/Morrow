import Foundation
import Markdown

indirect enum WorkMarkdownBlock {
    case paragraph(AttributedString), heading(Int, AttributedString)
    case listItem(String, Bool?, [WorkMarkdownBlock]), quote([WorkMarkdownBlock])
    case code(String, String), table([[AttributedString]]), rule
}

/// cmark-GFM parses blocks. Inline newlines are appended explicitly, so Text
/// never collapses a list, paragraph break or code block into one long run.
struct WorkMarkdownDocument {
    let blocks: [WorkMarkdownBlock]
    var plainText: String { Self.plainText(blocks) }
    private static func plainText(_ blocks: [WorkMarkdownBlock]) -> String {
        blocks.map { block in
            switch block {
            case .paragraph(let text), .heading(_, let text): return String(text.characters)
            case .listItem(let marker, let checked, let children): return (checked.map { $0 ? "☑" : "☐" } ?? marker) + " " + plainText(children).replacingOccurrences(of: "\n", with: "\n  ")
            case .quote(let children): return plainText(children)
            case .code(_, let content): return content.trimmingCharacters(in: .newlines)
            case .table(let rows): return rows.map { $0.map { String($0.characters) }.joined(separator: "\t") }.joined(separator: "\n")
            case .rule: return "────────"
            }
        }.joined(separator: "\n\n")
    }
    private static let cache: NSCache<NSString, Cached> = { let c = NSCache<NSString, Cached>(); c.countLimit = 128; c.totalCostLimit = 8 * 1024 * 1024; return c }()
    private final class Cached { let blocks: [WorkMarkdownBlock]; init(_ blocks: [WorkMarkdownBlock]) { self.blocks = blocks } }
    init(_ source: String) {
        if let found = Self.cache.object(forKey: source as NSString) { blocks = found.blocks; return }
        var text = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for opener in ["```markdown\n", "```md\n"] where trimmed.hasPrefix(opener) && trimmed.hasSuffix("\n```") { text = String(trimmed.dropFirst(opener.count).dropLast(4)); break }
        let bounded = String(text.prefix(131072))
        let parsed = Document(parsing: bounded)
        blocks = Self.convert(parsed.children, depth: 0)
        Self.cache.setObject(Cached(blocks), forKey: source as NSString, cost: source.utf8.count + bounded.utf8.count)
    }
    private static func inline(_ node: any Markup) -> AttributedString {
        if let node = node as? Markdown.Text { return AttributedString(node.string) }
        if node is SoftBreak || node is LineBreak { return AttributedString("\n") }
        if let code = node as? InlineCode { var a = AttributedString(code.code); a.inlinePresentationIntent = .code; return a }
        if let html = node as? InlineHTML { return AttributedString(html.rawHTML.lowercased().hasPrefix("<br") ? "\n" : html.rawHTML) }
        var result = AttributedString()
        for child in node.children { result.append(inline(child)) }
        let intent: InlinePresentationIntent? = node is Strong ? .stronglyEmphasized : node is Emphasis ? .emphasized : node is Strikethrough ? .strikethrough : nil
        if let intent { for range in Array(result.runs.map(\.range)) { result[range].inlinePresentationIntent = (result[range].inlinePresentationIntent ?? []).union(intent) } }
        if let link = node as? Markdown.Link, let destination = link.destination, let url = URL(string: destination), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") { result.link = url }
        return result
    }
    private static func convert<S: Sequence>(_ nodes: S, depth: Int) -> [WorkMarkdownBlock] where S.Element == any Markup {
        guard depth < 12 else { return [] }
        var result: [WorkMarkdownBlock] = []
        for node in nodes.prefix(512) {
            if let h = node as? Heading { result.append(.heading(h.level, inline(h))) }
            else if let p = node as? Paragraph { result.append(.paragraph(inline(p))) }
            else if let code = node as? CodeBlock { result.append(.code(code.language ?? "", code.code)) }
            else if node is ThematicBreak { result.append(.rule) }
            else if let quote = node as? BlockQuote { result.append(.quote(convert(quote.children, depth: depth + 1))) }
            else if let list = node as? UnorderedList {
                for child in list.children { if let item = child as? ListItem { result.append(.listItem("•", item.checkbox.map { $0 == .checked }, convert(item.children, depth: depth + 1))) } }
            } else if let list = node as? OrderedList {
                for (index, child) in list.children.enumerated() { if let item = child as? ListItem { result.append(.listItem("\(Int(list.startIndex) + index).", item.checkbox.map { $0 == .checked }, convert(item.children, depth: depth + 1))) } }
            } else if let table = node as? Markdown.Table {
                var rows = [table.head.children.map(inline)]
                rows += table.body.children.prefix(200).map { $0.children.map(inline) }
                result.append(.table(rows))
            } else { result += convert(node.children, depth: depth + 1) }
        }
        return result
    }
}
