import Foundation

/// The host-owned ceiling captured when a user submits a work request.
/// A model may narrow this ceiling, but cannot add accounts or mail identities.
public struct WorkContextLimit: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case selection, contact, mailbox }
    public var kind: Kind
    public var label: String
    public var existingMailIDs: [String]
    public var accountIDs: [String]
    public var contactEmail: String?
    public var allowsFuture: Bool

    public init(kind: Kind, label: String, existingMailIDs: [String], accountIDs: [String], contactEmail: String? = nil, allowsFuture: Bool = false) {
        self.kind = kind; self.label = label; self.existingMailIDs = Array(Set(existingMailIDs)).sorted(); self.accountIDs = Array(Set(accountIDs)).sorted(); self.contactEmail = contactEmail?.lowercased(); self.allowsFuture = allowsFuture
    }
    public func containsExisting(_ mail: MailMessage) -> Bool {
        accountIDs.contains(mail.accountID) && (existingMailIDs.contains(mail.id) || existingMailIDs.contains(mail.canonicalID))
    }
    public func contains(_ mail: MailMessage) -> Bool {
        guard accountIDs.contains(mail.accountID) else { return false }
        if existingMailIDs.contains(mail.id) || existingMailIDs.contains(mail.canonicalID) { return true }
        guard allowsFuture else { return false }
        switch kind {
        case .selection: return false
        case .mailbox: return true
        case .contact:
            guard let contactEmail else { return false }
            return ContactProfileBuilder.participants(mail).contains { $0.email.caseInsensitiveCompare(contactEmail) == .orderedSame }
        }
    }
    public func constrain(_ value: WorkScope, against inventory: [MailMessage]) -> WorkScope {
        var scope = value
        let allowed = Set(inventory.filter(containsExisting).flatMap { [$0.id, $0.canonicalID] })
        scope.sourceMailIDs = scope.sourceMailIDs.filter { allowed.contains($0) }
        if !allowsFuture || kind == .selection { scope.subjectTerms = []; scope.senderEmails = [] }
        let selectedCanonical = Set(inventory.filter { scope.sourceMailIDs.contains($0.id) || scope.sourceMailIDs.contains($0.canonicalID) }.map(\.canonicalID))
        scope.excludedExistingIDs = Array(Set(inventory.map(\.canonicalID)).subtracting(selectedCanonical)).sorted()
        return scope
    }
    public var boundary: String { "资料范围上限：" + label + "；其他邮箱和对象不会自行加入。" + (allowsFuture && kind != .selection ? "仅按已确认条件关注此范围内的新邮件。" : "只使用提交时选定的邮件，不自动加入新邮件。") }
}
