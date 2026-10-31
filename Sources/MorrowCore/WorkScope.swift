import Foundation

/// A reviewable scope, resolved from the user's words against actual mail identities.
public struct WorkScope: Codable, Sendable, Equatable {
    public var sourceMailIDs: [String]
    public var subjectTerms: [String]
    public var senderEmails: [String]
    public var excludedExistingIDs: [String]?
    public init(sourceMailIDs: [String] = [], subjectTerms: [String] = [], senderEmails: [String] = []) {
        self.sourceMailIDs = sourceMailIDs; self.subjectTerms = subjectTerms; self.senderEmails = senderEmails
    }
    public static var schema: Data {
        let strings: [String: Any] = ["type": "array", "items": ["type": "string"]]
        let fields = ["sourceMailIDs": strings, "subjectTerms": strings, "senderEmails": strings]
        return try! JSONSerialization.data(withJSONObject: ["type": "object", "properties": fields, "required": Array(fields.keys), "additionalProperties": false])
    }
    public func contains(_ mail: MailMessage) -> Bool {
        if sourceMailIDs.contains(mail.id) || sourceMailIDs.contains(mail.canonicalID) { return true }
        if excludedExistingIDs?.contains(mail.id) == true || excludedExistingIDs?.contains(mail.canonicalID) == true { return false }
        guard !subjectTerms.isEmpty || !senderEmails.isEmpty else { return false }
        let senderMatches = senderEmails.isEmpty || senderEmails.contains { $0.caseInsensitiveCompare(mail.from.email) == .orderedSame }
        let subjectMatches = subjectTerms.isEmpty || subjectTerms.contains { mail.normalizedSubject.localizedCaseInsensitiveContains($0) }
        return senderMatches && subjectMatches
    }
    public func validated(against mails: [MailMessage]) -> WorkScope {
        let known = Set(mails.flatMap { [$0.id, $0.canonicalID] })
        let sources = mails.filter { sourceMailIDs.contains($0.id) || sourceMailIDs.contains($0.canonicalID) }.map(\.canonicalID)
        var scope = WorkScope(sourceMailIDs: Array(Set(sources + sourceMailIDs.filter { known.contains($0) })), subjectTerms: Array(Set(subjectTerms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted(), senderEmails: Array(Set(senderEmails.filter(MailAddress.isValid).map { $0.lowercased() })).sorted())
        scope.excludedExistingIDs = Array(Set(mails.map(\.canonicalID)).subtracting(Set(sources))).sorted()
        return scope
    }
    public static func terms(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",，、;；\n")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    public static func matches(_ text: String, mail: MailMessage) -> Bool {
        let terms = terms(text)
        let content = mail.subject + " " + mail.text + " " + mail.from.email
        return terms.isEmpty || terms.contains { content.localizedCaseInsensitiveContains($0) }
    }
}
