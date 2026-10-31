import Foundation

/// Compiled once, reused for each inventory row instead of compiling two
/// regular expressions per UID or materializing the joined server response.
enum IMAPFlagRow {
    private static let row = try! NSRegularExpression(pattern: #"^\*\s+\d+\s+FETCH\s+\("#, options: .caseInsensitive)
    private static let uid = try! NSRegularExpression(pattern: #"\bUID\s+(\d+)\b"#, options: .caseInsensitive)
    private static let flags = try! NSRegularExpression(pattern: #"\bFLAGS\s*\(([^)]*)\)"#, options: .caseInsensitive)
    static func parse(_ line: String) -> (uid: UInt64, read: Bool, starred: Bool)? {
        let range = NSRange(line.startIndex..., in: line)
        guard row.firstMatch(in: line, range: range) != nil,
              let match = uid.firstMatch(in: line, range: range), let uidRange = Range(match.range(at: 1), in: line),
              let value = UInt64(line[uidRange]), value > 0, value <= UInt64(UInt32.max) else { return nil }
        var words: [Substring] = []
        if let match = flags.firstMatch(in: line, range: range), let flagRange = Range(match.range(at: 1), in: line) { words = line[flagRange].lowercased().split(whereSeparator: \.isWhitespace) }
        return (value, words.contains("\\seen"), words.contains("\\flagged"))
    }
}
