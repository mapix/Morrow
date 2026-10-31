import Foundation

public struct ProfileClaim: Codable, Identifiable, Sendable {
    public var id: String = UUID().uuidString
    public var text: String
    public var mailID: String
    public var quote: String
    public init(text: String, mailID: String, quote: String) { self.text = text; self.mailID = mailID; self.quote = quote }
}
public struct ContactProfile: Codable, Identifiable, Sendable {
    public var id: String { email }
    public var email: String
    public var name: String
    public var aliases: [String]
    public var mailIDs: [String]
    public var accountIDs: [String]
    public var received: Int
    public var sent: Int
    public var copied: Int
    public var firstSeen: Date?
    public var lastSeen: Date?
    public var topics: [String]
    public var fingerprint: String
    public var claims: [ProfileClaim] = []
    public var analysisFingerprint: String = ""
    public var analysisStatus: String = "等待整理邮件线索"
    public var analyzedAt: Date?
    public var correction: String = ""
    public var display: String { name.isEmpty ? email : name }
    public var domain: String { email.components(separatedBy: "@").last ?? "" }
    public var mailCount: Int { mailIDs.count }
}
public enum ContactProfileBuilder {
    public static func participants(_ mail: MailMessage) -> [MailAddress] { [mail.from] + mail.to + mail.cc + (mail.bcc ?? []) + mail.replyTo }
    public static func build(mails: [MailMessage], accounts: [MailAccount], manual: [ContactEntry], previous: [ContactProfile] = []) -> [ContactProfile] {
        let own = Set(accounts.map { $0.email.lowercased() })
        var canonical: [String: MailMessage] = [:]
        for mail in mails { if canonical[mail.canonicalID] == nil || mail.folder.uppercased() == "INBOX" { canonical[mail.canonicalID] = mail } }
        var groups: [String: [MailMessage]] = [:]; var names: [String: [String: Int]] = [:]
        for mail in canonical.values {
            var seen = Set<String>()
            for address in participants(mail) {
                let email = address.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard MailAddress.isValid(email), !own.contains(email), !["local@example.com"].contains(email) else { continue }
                if seen.insert(email).inserted { groups[email, default: []].append(mail) }
                let name = address.name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty && name.lowercased() != email { names[email, default: [:]][name, default: 0] += 1 }
            }
        }
        for contact in manual where MailAddress.isValid(contact.email) && !own.contains(contact.email.lowercased()) { if groups[contact.email.lowercased()] == nil { groups[contact.email.lowercased()] = [] } }
        let prior = Dictionary(uniqueKeysWithValues: previous.map { ($0.email, $0) })
        return groups.map { email, items in
            let mails = items.sorted { $0.date > $1.date }
            let aliases = (names[email] ?? [:]).sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
            let manualName = manual.first { $0.email.lowercased() == email }?.name ?? ""
            let name = manualName.isEmpty ? aliases.first ?? "" : manualName
            let material = mails.sorted { $0.canonicalID < $1.canonicalID }.map { m in m.canonicalID + m.subject + m.text + participants(m).map { $0.name + $0.email }.joined() }.joined()
            let fingerprint = MailStore.hash(Data((material + name).utf8))
            var p = ContactProfile(email: email, name: name, aliases: aliases, mailIDs: mails.map(\.id), accountIDs: Array(Set(mails.map(\.accountID))).sorted(), received: mails.filter { $0.from.email.lowercased() == email }.count, sent: mails.filter { own.contains($0.from.email.lowercased()) && ($0.to + $0.cc + ($0.bcc ?? [])).contains { $0.email.lowercased() == email } }.count, copied: mails.filter { $0.cc.contains { $0.email.lowercased() == email } }.count, firstSeen: mails.map(\.date).min(), lastSeen: mails.map(\.date).max(), topics: Array(Set(mails.map(\.normalizedSubject))).sorted(), fingerprint: fingerprint)
            if let old = prior[email] { p.claims = old.claims; p.analysisFingerprint = old.analysisFingerprint; p.analysisStatus = old.analysisStatus; p.analyzedAt = old.analyzedAt; p.correction = old.correction; if p.fingerprint != old.fingerprint { p.analysisStatus = "历史往来已更新，等待重新整理线索" } }
            return p
        }.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }
    public static func validatedClaims(_ claims: [ProfileClaim], mails: [MailMessage]) -> [ProfileClaim] {
        claims.filter { claim in guard let mail = mails.first(where: { $0.id == claim.mailID }), !claim.quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }; return (mail.subject + "\n" + mail.text).contains(claim.quote) }
    }
}
public struct MailAttachmentRecord: Identifiable, Sendable {
    public var id: String
    public var attachment: MailAttachment
    public var mail: MailMessage
    public var kind: String {
        let ext = URL(fileURLWithPath: attachment.name).pathExtension.lowercased(), mime = attachment.mimeType
        if mime.hasPrefix("image/") { return "图片" }; if mime.hasPrefix("audio/") { return "音频" }; if mime.hasPrefix("video/") { return "视频" }
        if ["xlsx", "xls", "csv", "tsv", "ods"].contains(ext) { return "表格" }; if ["zip", "rar", "7z", "gz"].contains(ext) { return "压缩包" }
        if ["pdf", "doc", "docx", "pptx", "txt", "md", "rtf", "odt"].contains(ext) || mime.hasPrefix("text/") { return "文档" }; return "其他"
    }
    public static func index(_ mails: [MailMessage]) -> [MailAttachmentRecord] {
        var seen = Set<String>(); var records: [MailAttachmentRecord] = []
        for mail in mails.sorted(by: { $0.date > $1.date }) {
            for (slot, attachment) in mail.attachments.enumerated() {
                let id = mail.canonicalID + ":attachment:" + String(slot)
                if seen.insert(id).inserted { records.append(.init(id: id, attachment: attachment, mail: mail)) }
            }
        }
        return records
    }
}
public struct ChatMaterial: Codable, Identifiable, Sendable {
    public var id: String = UUID().uuidString
    public var name: String
    public var mimeType: String
    public var path: String
    public var byteCount: Int
    public var transcript: String?
    public init(name: String, mimeType: String, path: String, byteCount: Int) { self.name = name; self.mimeType = mimeType; self.path = path; self.byteCount = byteCount }
}
public struct WorkspaceContext: Codable, Sendable, Equatable {
    public var page: String
    public var label: String
    public var mailIDs: [String]
    public var contactEmail: String?
    public var attachmentIDs: [String]
    public var runID: String?
    public var draftID: String?
    public var artifactID: String?
    public var query: String?
    public var filter: String?
    public var accountID: String?
    public init(page: String, label: String, mailIDs: [String] = [], contactEmail: String? = nil, attachmentIDs: [String] = [], runID: String? = nil) { self.page = page; self.label = label; self.mailIDs = mailIDs; self.contactEmail = contactEmail; self.attachmentIDs = attachmentIDs; self.runID = runID }
}
