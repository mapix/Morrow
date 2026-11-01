import Foundation

/// Contact membership and statistics use headers and content revisions. Full
/// bodies are fetched only for the small AI evidence batches that need them.
public struct ContactProfileMetadataIndex: Sendable {
    private var records: [String: MailMessage] = [:]
    private var groups: [String: Set<String>] = [:]
    private var own = Set<String>()
    private var manualNames: [String: String] = [:]
    private var initialized = false
    public private(set) var affectedProfileCount = 0
    public private(set) var affectedEmails = Set<String>()
    public init() {}

    private func emails(_ mail: MailMessage) -> Set<String> {
        Set(ContactProfileBuilder.participants(mail).map { $0.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { MailAddress.isValid($0) && !own.contains($0) && $0 != "local@example.com" })
    }
    private func header(_ input: MailMessage) -> MailMessage {
        var mail = input
        mail.contentRevision = input.contentRevision ?? MailStore.hash(input.text)
        mail.text = ""; mail.html = ""; mail.raw = Data(); mail.attachments = []; mail.analysis = nil
        mail.note = ""; mail.labels = []; mail.isRead = false; mail.isStarred = false
        mail.actionDone = false; mail.snoozedUntil = nil; mail.localFlagModifiedAt = nil
        mail.contentAvailability = .preview
        return mail
    }
    public mutating func build(mails: [MailMessage], accounts: [MailAccount], manual: [ContactEntry], previous: [ContactProfile]) -> [ContactProfile] {
        let nextOwn = Set(accounts.map { $0.email.lowercased() })
        let nextManual = Dictionary(manual.filter { MailAddress.isValid($0.email) && !nextOwn.contains($0.email.lowercased()) }
            .map { ($0.email.lowercased(), $0.name) }, uniquingKeysWith: { _, last in last })
        var affected = Set<String>()
        if !initialized || own != nextOwn {
            affected.formUnion(previous.map(\.email)); records = [:]; groups = [:]; own = nextOwn
        }
        var present = Set<String>()
        for input in mails {
            let key = input.canonicalID; present.insert(key)
            let value = header(input)
            if let old = records[key], old == value { continue }
            if let old = records[key] {
                for email in emails(old) { groups[email]?.remove(key); affected.insert(email) }
            }
            records[key] = value
            for email in emails(value) { groups[email, default: []].insert(key); affected.insert(email) }
        }
        for key in Set(records.keys).subtracting(present) {
            if let old = records.removeValue(forKey: key) {
                for email in emails(old) { groups[email]?.remove(key); affected.insert(email) }
            }
        }
        for email in Set(manualNames.keys).union(nextManual.keys) where manualNames[email] != nextManual[email] { affected.insert(email) }
        manualNames = nextManual; initialized = true; affectedProfileCount = affected.count; affectedEmails = affected
        guard !affected.isEmpty else { return previous }
        var result = Dictionary(previous.map { ($0.email, $0) }, uniquingKeysWith: { _, last in last })
        let needed = affected.reduce(into: Set<String>()) { $0.formUnion(groups[$1] ?? []) }
        let built = ContactProfileBuilder.build(mails: needed.compactMap { records[$0] }, accounts: accounts,
            manual: manual.filter { affected.contains($0.email.lowercased()) }, previous: previous)
        for profile in built where affected.contains(profile.email) { result[profile.email] = profile }
        for email in affected where (groups[email]?.isEmpty ?? true) && manualNames[email] == nil { result.removeValue(forKey: email) }
        return result.values.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }
}
