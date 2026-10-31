import Foundation

/// Build once per inventory pass; membership checks must not rescan ID arrays.
public struct CompiledWorkScope: Sendable {
    private let included: Set<String>, excluded: Set<String>, senders: Set<String>
    private let subjects: [String]
    public init(_ source: WorkScope) { included = Set(source.sourceMailIDs); excluded = Set(source.excludedExistingIDs ?? []); senders = Set(source.senderEmails.map { $0.lowercased() }); subjects = source.subjectTerms }
    public func contains(_ mail: MailMessage) -> Bool {
        if included.contains(mail.id) || included.contains(mail.canonicalID) { return true }
        if excluded.contains(mail.id) || excluded.contains(mail.canonicalID) { return false }
        guard !subjects.isEmpty || !senders.isEmpty else { return false }
        return (senders.isEmpty || senders.contains(mail.from.email.lowercased())) && (subjects.isEmpty || subjects.contains { mail.normalizedSubject.localizedCaseInsensitiveContains($0) })
    }
}
public struct CompiledWorkContext: Sendable {
    private let accounts: Set<String>, included: Set<String>
    private let kind: WorkContextLimit.Kind, future: Bool, contact: String?
    public init(_ source: WorkContextLimit) { accounts = Set(source.accountIDs); included = Set(source.existingMailIDs); kind = source.kind; future = source.allowsFuture; contact = source.contactEmail }
    public func containsExisting(_ mail: MailMessage) -> Bool { accounts.contains(mail.accountID) && (included.contains(mail.id) || included.contains(mail.canonicalID)) }
    public func contains(_ mail: MailMessage) -> Bool {
        guard accounts.contains(mail.accountID) else { return false }; if containsExisting(mail) { return true }
        guard future else { return false }
        switch kind { case .selection: return false; case .mailbox: return true; case .contact: return contact.map { target in ContactProfileBuilder.participants(mail).contains { $0.email.caseInsensitiveCompare(target) == .orderedSame } } ?? false }
    }
}
public struct CompiledWorkAgreement: Sendable {
    private let resolved: CompiledWorkScope?, host: CompiledWorkContext?
    public init(_ source: WorkAgreement) { resolved = source.resolvedScope.map(CompiledWorkScope.init); host = source.hostScope.map(CompiledWorkContext.init) }
    public func contains(_ mail: MailMessage) -> Bool { (resolved?.contains(mail) ?? false) && (host?.contains(mail) ?? true) }
}
