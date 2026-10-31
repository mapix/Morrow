import Foundation

public struct MailResponder: Codable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var title = ""
    public var accountID = ""
    public var sender = ""
    public var subjectContains = ""
    public var bodyContains = ""
    public var response = ""
    public var useAI = false
    public var delivery = "draft"
    public var enabled = false
    public var archived = false
    public var dailyLimit = 20
    public var processedIDs: [String] = []
    public var createdAt = Date()
    public var updatedAt = Date()
    public var status = "尚未启用"
    public init() {}
    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MailError.message("为响应器起个名字。") }
        guard !sender.isEmpty || !subjectContains.isEmpty || !bodyContains.isEmpty else { throw MailError.message("至少设定一个邮件条件。") }
        guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MailError.message(useAI ? "填写 AI 回复要求。" : "填写回复正文。") }
        guard ["draft", "send"].contains(delivery) else { throw MailError.message("响应方式无效。") }
        guard (1...100).contains(dailyLimit) else { throw MailError.message("每天的响应上限须为1到100封。") }
        if !sender.isEmpty && !Self.validSender(sender) { throw MailError.message("发件人须为邮箱地址或 @example.com 形式的域名。") }
    }
    public static func validSender(_ value: String) -> Bool { MailAddress.isValid(value) || value.range(of: #"^@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil }
    public func matches(_ mail: MailMessage) -> Bool {
        guard accountID.isEmpty || mail.accountID == accountID else { return false }
        let senderMatch = sender.isEmpty || (sender.hasPrefix("@") ? mail.from.email.lowercased().hasSuffix(sender.lowercased()) : mail.from.email.caseInsensitiveCompare(sender) == .orderedSame)
        return senderMatch && (subjectContains.isEmpty || mail.subject.localizedCaseInsensitiveContains(subjectContains)) && (bodyContains.isEmpty || mail.text.localizedCaseInsensitiveContains(bodyContains))
    }
    public func body(for mail: MailMessage, account: MailAccount) -> String {
        response.replacingOccurrences(of: "{{senderName}}", with: mail.from.name.isEmpty ? mail.from.email : mail.from.name).replacingOccurrences(of: "{{subject}}", with: mail.normalizedSubject).replacingOccurrences(of: "{{myName}}", with: account.name)
    }
}

public struct ResponderReceipt: Codable, Identifiable, Sendable {
    public var id: String
    public var responderID: String
    public var mailID: String
    public var canonicalID: String
    public var draftID: String?
    public var state = "preparing"
    public var detail = ""
    public var createdAt = Date()
    public init(responderID: String, mail: MailMessage) { self.responderID = responderID; self.mailID = mail.id; self.canonicalID = mail.canonicalID; self.id = "responder-" + MailStore.hash(responderID + ":" + mail.canonicalID) }
}

public enum ResponderPolicy {
    public static func isAutomatic(_ mail: MailMessage, raw: Data = Data()) -> Bool {
        let sender = mail.from.email.lowercased()
        if ["noreply", "no-reply", "mailer-daemon", "postmaster"].contains(where: sender.contains) { return true }
        let header = String(decoding: raw.prefix(32768), as: UTF8.self).components(separatedBy: "\r\n\r\n").first ?? ""
        let lines = header.replacingOccurrences(of: "\r\n ", with: " ").replacingOccurrences(of: "\r\n\t", with: " ").components(separatedBy: .newlines)
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            guard parts.count == 2 else { continue }
            if parts[0] == "auto-submitted" && parts[1] != "no" { return true }
            if parts[0] == "list-id" { return true }
            if parts[0] == "precedence" && ["bulk", "list", "junk"].contains(parts[1]) { return true }
            if parts[0] == "x-auto-response-suppress" && (parts[1].contains("all") || parts[1].contains("autoreply")) { return true }
        }
        return false
    }
    public static func canSend(_ draft: ComposeDraft, rule: MailResponder, mail: MailMessage) -> Bool {
        let recipients = draft.addresses(draft.to) + draft.addresses(draft.cc) + draft.addresses(draft.bcc)
        return rule.enabled && rule.delivery == "send" && rule.matches(mail) && MailAddress.isValid(mail.from.email) && recipients.count == 1 && recipients[0].email.caseInsensitiveCompare(mail.from.email) == .orderedSame
    }
}
