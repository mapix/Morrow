import Foundation

public struct MailQuery: Sendable {
    public var text: String
    public var from: String?
    public var to: String?
    public var subject: String?
    public var after: Date?
    public var before: Date?
    public var unread: Bool = false
    public var starred: Bool = false
    public var attachment: Bool = false
    public var label: String?
    public var hasFilters: Bool { from != nil || to != nil || subject != nil || after != nil || before != nil || unread || starred || attachment || label != nil }
    public init(_ value: String) {
        text = value
        let pattern = #"(from|to|subject|after|before|is|has|label):(?:"([^"]*)"|(\S+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return }
        let matches = regex.matches(in: value, range: NSRange(value.startIndex..., in: value))
        for match in matches.reversed() {
            let ns = value as NSString; let key = ns.substring(with: match.range(at: 1)).lowercased(); let content = ns.substring(with: match.range(at: match.range(at: 2).location != NSNotFound ? 2 : 3))
            switch key { case "from": from = content; case "to": to = content; case "subject": subject = content; case "after": after = Self.date(content); case "before": before = Self.date(content); case "is": if content == "unread" { unread = true }; if content == "starred" { starred = true }; case "has": attachment = content == "attachment"; case "label": label = content; default: break }
            if let range = Range(match.range, in: text) { text.removeSubrange(range) }
        }; text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func date(_ value: String) -> Date? { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f.date(from: value) }
    public func matches(_ mail: MailMessage) -> Bool {
        if let from, !(mail.from.name + mail.from.email).localizedCaseInsensitiveContains(from) { return false }
        if let to, !(mail.to + mail.cc).contains(where: { ($0.name + $0.email).localizedCaseInsensitiveContains(to) }) { return false }
        if let subject, !mail.subject.localizedCaseInsensitiveContains(subject) { return false }
        if let after, mail.date < after { return false }; if let before, mail.date >= before { return false }
        if unread && mail.isRead { return false }; if starred && !mail.isStarred { return false }; if attachment && mail.attachments.isEmpty { return false }
        if let label, !mail.labels.contains(where: { $0.localizedCaseInsensitiveContains(label) }) { return false }; return true
    }
}
