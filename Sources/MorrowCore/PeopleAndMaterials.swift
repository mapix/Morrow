import Foundation
import CryptoKit

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
    public var analyzedMailVersions: [String: String]?
    public var analysisRetryAt: Date?
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
            var digest = SHA256()
            func append(_ value: String) {
                let bytes = value.utf8; var start = bytes.startIndex
                while start < bytes.endIndex { let end = bytes.index(start, offsetBy: 64 * 1024, limitedBy: bytes.endIndex) ?? bytes.endIndex; digest.update(data: Data(bytes[start..<end])); start = end }
            }
            append("profile-metadata-v1")
            for mail in mails.sorted(by: { $0.canonicalID < $1.canonicalID }) {
                append(mail.canonicalID); append(mail.subject); append(mail.contentRevision ?? MailStore.hash(mail.text))
                for participant in participants(mail) { append(participant.name); append(participant.email) }
            }
            append(name)
            let fingerprint = digest.finalize().map { String(format: "%02x", $0) }.joined()
            var p = ContactProfile(email: email, name: name, aliases: aliases, mailIDs: mails.map(\.id), accountIDs: Array(Set(mails.map(\.accountID))).sorted(), received: mails.filter { $0.from.email.lowercased() == email }.count, sent: mails.filter { own.contains($0.from.email.lowercased()) && ($0.to + $0.cc + ($0.bcc ?? [])).contains { $0.email.lowercased() == email } }.count, copied: mails.filter { $0.cc.contains { $0.email.lowercased() == email } }.count, firstSeen: mails.map(\.date).min(), lastSeen: mails.map(\.date).max(), topics: Array(Set(mails.map(\.normalizedSubject))).sorted(), fingerprint: fingerprint)
            if let old = prior[email] { p.claims = old.claims; p.analysisFingerprint = old.analysisFingerprint; p.analysisStatus = old.analysisStatus; p.analyzedAt = old.analyzedAt; p.analyzedMailVersions = old.analyzedMailVersions; p.analysisRetryAt = old.analysisRetryAt; p.correction = old.correction; if p.fingerprint != old.fingerprint { p.analysisStatus = "历史往来已更新，等待重新整理线索" } }
            return p
        }.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
    }
    public static func canPreserveCompletedAnalysis(_ old: ContactProfile, _ updated: ContactProfile, versions: [String: String]) -> Bool {
        guard old.analysisFingerprint == "profile-ai-v2:" + old.fingerprint, let analyzed = old.analyzedMailVersions,
              Set(old.mailIDs) == Set(updated.mailIDs), updated.mailIDs.allSatisfy({ analyzed[$0] == versions[$0] && versions[$0] != nil }) else { return false }
        return old.name == updated.name && old.aliases == updated.aliases && old.accountIDs == updated.accountIDs && old.received == updated.received && old.sent == updated.sent && old.copied == updated.copied && old.firstSeen == updated.firstSeen && old.lastSeen == updated.lastSeen && old.topics == updated.topics
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
/// A captured list boundary, not a request to preload every message body.
public struct MailListContextDescriptor: Codable, Sendable, Equatable {
    public var accountIDs: [String]
    public var folderPath: String?
    public var destination: String
    public var unreadOnly: Bool
    public var category: MailCategory?
    public var capturedAt: Date
    /// Host-only role metadata. Remove from the bounded model presentation.
    public var folderRoles: [String: String]
    public init(accountIDs: [String], folderPath: String? = nil, destination: String,
                unreadOnly: Bool = false, category: MailCategory? = nil,
                capturedAt: Date = Date(), folderRoles: [String: String] = [:]) {
        self.accountIDs = accountIDs; self.folderPath = folderPath; self.destination = destination
        self.unreadOnly = unreadOnly; self.category = category; self.capturedAt = capturedAt; self.folderRoles = folderRoles
    }
    public static func folderKey(accountID: String, path: String) -> String { accountID + "\u{1f}" + path }
    public var destinationCode: String? {
        let code = destination.lowercased()
        if ["inbox", "focus", "starred", "sent", "trash", "snoozed", "all", "unread", "archive"].contains(code) { return code }
        return ["收件箱": "inbox", "待处理": "focus", "伙伴": "focus", "星标": "starred", "已发送": "sent", "废纸篓": "trash", "稍后处理": "snoozed", "全部邮件": "all", "未读": "unread", "归档": "archive"][destination]
    }
    public func matches(_ mail: MailMessage, ownEmail: String? = nil) -> Bool {
        guard accountIDs.contains(mail.accountID), let code = destinationCode else { return false }
        if let folderPath, mail.folder != folderPath { return false }
        if unreadOnly && mail.isRead { return false }
        if let category, mail.analysis?.category != category { return false }
        let role = folderRoles[Self.folderKey(accountID: mail.accountID, path: mail.folder)]
            ?? (mail.folder.uppercased() == "INBOX" ? "inbox" : nil)
        if folderPath == nil && role == nil && !["all", "unread"].contains(code) { return false }
        let outbound = role == "sent" || (ownEmail.map { own in mail.from.email.lowercased() == own.lowercased() && mail.to.contains { $0.email.lowercased() != own.lowercased() } } ?? false)
        switch code {
        case "focus": return mail.actionable && !outbound && role != "trash" && role != "junk" && (mail.snoozedUntil == nil || mail.snoozedUntil! <= capturedAt)
        case "starred": return mail.isStarred && role != "trash"
        case "snoozed": return mail.snoozedUntil.map { $0 > capturedAt } ?? false
        case "sent": return role == "sent"
        case "trash": return role == "trash"
        case "archive": return role == "archive"
        case "unread": return !mail.isRead && (folderPath != nil || (role != "trash" && role != "junk"))
        case "all": return folderPath != nil || (role != "trash" && role != "junk")
        default: return folderPath != nil || role == "inbox"
        }
    }
}

public struct WorkspaceContext: Codable, Sendable, Equatable {
    /// Browsing supplies referents and optional evidence, never authority.
    /// "scope" is only set for an intentional user restriction.
    public var scopeMode: String?
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
    public var mailList: MailListContextDescriptor?
    public var hasExplicitMailSelection: Bool { mailList == nil && ["mail", "mail-results", "attachments", "desk"].contains(page) && !mailIDs.isEmpty }
    public init(page: String, label: String, mailIDs: [String] = [], contactEmail: String? = nil, attachmentIDs: [String] = [], runID: String? = nil) { self.page = page; self.label = label; self.mailIDs = mailIDs; self.contactEmail = contactEmail; self.attachmentIDs = attachmentIDs; self.runID = runID }
}
