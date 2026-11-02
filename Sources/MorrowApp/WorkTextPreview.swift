import Foundation

/// Small index excerpts only. Full reports and exports keep their original source.
final class WorkTextPreview: @unchecked Sendable {
    enum Role: String { case brief, artifact }
    static let shared = WorkTextPreview()
    static let maximumSourceCharacters = 1600
    private let cache = NSCache<NSString, NSString>()
    private let inlineCode = try! NSRegularExpression(pattern: #"`[^`\n]+`"#)
    private let emphasisRules: [(NSRegularExpression, String)] = [
        (#"(?<![A-Za-z0-9_*])(\*\*|__)(?=[^\s*/_])(.+?)(?<=\S)\1(?![A-Za-z0-9_*/]|\.[A-Za-z0-9])"#, "$2"),
        (#"(?<![A-Za-z0-9_*])\*(?=[^\s*/])([^*\n]+?)(?<=\S)\*(?![A-Za-z0-9_*/]|\.[A-Za-z0-9])"#, "$1"),
        (#"(?<![A-Za-z0-9_*])_(?=[^\s/_])([^_\n]+?)(?<=\S)_(?![A-Za-z0-9_*/]|\.[A-Za-z0-9])"#, "$1")
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
    private let rules: [(NSRegularExpression, String)] = [
        (#"!\[([^\]]*)\]\([^\n)]*\)"#, "$1"),
        (#"\[([^\]]+)\]\([^\n)]*\)"#, "$1"),
        (#"\[([^\]]+)\]\[[^\]]*\]"#, "$1"),
        (#"`([^`\n]+)`"#, "$1"),
        (#"(?m)^\s*(?:>\s*|[-*+]\s+|\d+[.)]\s+)"#, ""),
        (#"[\t ]+"#, " ")
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
    init() { cache.countLimit = 128; cache.totalCostLimit = 1024 * 1024 }

    static func text(_ source: String, role: Role, limit: Int = 300) -> String { shared.excerpt(source, role: role, limit: limit) }
    func excerpt(_ source: String, role: Role, limit: Int = 300) -> String {
        let limit = min(600, max(1, limit))
        let bounded = String(source.prefix(Self.maximumSourceCharacters))
        let key = (role.rawValue + ":" + String(limit) + ":" + bounded) as NSString
        if let cached = cache.object(forKey: key) { return cached as String }
        let normalized = bounded.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var paragraph: [String] = [], fallback: String?, fenced = false
        for value in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("```") || line.hasPrefix("~~~") { fenced.toggle(); continue }
            if fenced { continue }
            if line.isEmpty { if !paragraph.isEmpty { break }; continue }
            let headingMarker = line.prefix(while: { $0 == "#" })
            if (1...6).contains(headingMarker.count), line.dropFirst(headingMarker.count).first?.isWhitespace == true {
                if fallback == nil { fallback = String(line.dropFirst(headingMarker.count)).trimmingCharacters(in: .whitespaces) }
                if !paragraph.isEmpty { break }; continue
            }
            let ruleCharacters = CharacterSet(charactersIn: "-_*:| ")
            if line.unicodeScalars.allSatisfy(ruleCharacters.contains) { continue }
            let plain = line.hasPrefix("|") ? line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " / ") : line
            paragraph.append(plain)
        }
        var result = paragraph.joined(separator: " ")
        if result.isEmpty { result = fallback ?? "" }
        result = removeEmphasisPreservingCode(result)
        for (rule, replacement) in rules {
            result = rule.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.count > limit { result = String(result.prefix(max(0, limit - 1))) + "…" }
        cache.setObject(result as NSString, forKey: key, cost: bounded.utf8.count + result.utf8.count)
        return result
    }
    private func removeEmphasisPreservingCode(_ source: String) -> String {
        func clean(_ text: String) -> String {
            var value = text
            for (rule, replacement) in emphasisRules { value = rule.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: replacement) }
            return value
        }
        var result = "", cursor = source.startIndex
        for match in inlineCode.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            guard let range = Range(match.range, in: source) else { continue }
            result += clean(String(source[cursor..<range.lowerBound]))
            result += source[range]; cursor = range.upperBound
        }
        return result + clean(String(source[cursor...]))
    }
}
