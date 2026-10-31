import Foundation

/// Derived metadata built once per published mailbox snapshot. No file I/O.
public struct MailProjectionCache: Sendable {
    private struct SubjectKey: Sendable { var subject: String; var key: String }
    private var subjectKeys: [String: SubjectKey] = [:]
    private var threadKeys: [String: String] = [:]
    private var threadIDs: [String: [String]] = [:]
    public private(set) var byID: [String: MailMessage] = [:]
    public private(set) var positions: [String: Int] = [:]
    public private(set) var primary: [MailMessage] = []
    public private(set) var attachments: [MailAttachmentRecord] = []
    public private(set) var normalizationCount = 0
    public init() {}

    public mutating func rebuild(_ mails: [MailMessage]) {
        var nextKeys: [String: SubjectKey] = [:], nextThreads: [String: String] = [:]
        var groups: [String: [String]] = [:], canonical: [String: MailMessage] = [:]
        var nextByID: [String: MailMessage] = [:], nextPositions: [String: Int] = [:]
        for (position, mail) in mails.enumerated() {
            if nextByID[mail.id] == nil { nextByID[mail.id] = mail; nextPositions[mail.id] = position }
            let key: SubjectKey
            if let existing = subjectKeys[mail.id], existing.subject == mail.subject { key = existing }
            else { key = SubjectKey(subject: mail.subject, key: mail.threadKey); normalizationCount += 1 }
            nextKeys[mail.id] = key
            let thread = mail.accountID + "\u{1f}" + key.key
            nextThreads[mail.id] = thread; groups[thread, default: []].append(mail.id)
            if canonical[mail.canonicalID] == nil || mail.folder.uppercased() == "INBOX" { canonical[mail.canonicalID] = mail }
        }
        subjectKeys = nextKeys; threadKeys = nextThreads; threadIDs = groups
        byID = nextByID; positions = nextPositions
        primary = canonical.values.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
        attachments = MailAttachmentRecord.index(mails)
    }

    public func related(to mail: MailMessage) -> [MailMessage] {
        let key = threadKeys[mail.id] ?? (mail.accountID + "\u{1f}" + mail.threadKey)
        var unique: [String: MailMessage] = [:]
        for id in threadIDs[key] ?? [] {
            guard let candidate = byID[id], candidate.canonicalID != mail.canonicalID else { continue }
            if unique[candidate.canonicalID] == nil || candidate.folder.uppercased() == "INBOX" { unique[candidate.canonicalID] = candidate }
        }
        return unique.values.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }
}

