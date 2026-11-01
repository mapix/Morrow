import Foundation

public struct MailResponder: Codable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var title = ""
    public var accountID = ""
    public var boundAccountFingerprint: String?
    public var boundAccountEmail: String?
    public var folderPath: String? = "INBOX"
    public var requireAuthentication: Bool? = true
    public var trustedAuthService: String?
    public var sessionID: String?
    public var activatedAt: Date?
    public var activationUIDValidity: UInt64?
    public var afterUID: UInt64?
    public var sender = ""
    public var senderAllowlist: [String]?
    public var executionPolicy: ResponderExecutionPolicy? = .init()
    public var policy: ResponderExecutionPolicy { executionPolicy ?? .init() }
    public var subjectContains = ""
    public var bodyContains = ""
    public var response = ""
    public var useAI = true
    public var delivery = "send"
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
        guard !accountID.isEmpty, let folderPath, !folderPath.isEmpty else { throw MailError.message("必须绑定一个邮箱和来源文件夹。") }
        guard (1...50).contains(allowedSenders.count), allowedSenders.allSatisfy(Self.validSender) else { throw MailError.message("必须填写发件邮箱白名单，每项一个完整邮箱地址；不支持空白、域名或通配符。最多50个地址。") }
        if requireAuthentication != false {
            guard let service = trustedAuthService, Self.validAuthService(service) else { throw MailError.message("填写接收服务商的可信邮件认证服务名，Gmail 使用 mx.google.com。") }
        }
        try policy.validate()
        guard !response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MailError.message(useAI ? "填写 AI 回复要求。" : "填写回复正文。") }
        guard title.utf8.count <= 1024, response.utf8.count <= 32768, subjectContains.utf8.count <= 4096, bodyContains.utf8.count <= 4096 else { throw MailError.message("响应器名称、筛选条件或处理要求超过长度预算。") }
        guard ["draft", "send"].contains(delivery) else { throw MailError.message("响应方式无效。") }
        guard (1...100).contains(dailyLimit) else { throw MailError.message("每天的响应上限须为1到100封。") }
    }
    public static func parseAllowlist(_ value: String) -> [String] {
        value.components(separatedBy: CharacterSet(charactersIn: ",;\n，；")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
    }
    public var allowedSenders: [String] { senderAllowlist ?? Self.parseAllowlist(sender) }
    public static func validSender(_ value: String) -> Bool {
        if value.hasPrefix("@") || value.contains("*") { return false }
        return MailAddress.isValid(value) && value.split(separator: "@").last.map({ validAuthService(String($0)) }) == true && value == value.trimmingCharacters(in: .whitespacesAndNewlines) && !value.contains("\n") && !value.contains("\r")
    }
    public static func validAuthService(_ value: String) -> Bool {
        value.count <= 253 && value.range(of: #"^(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$"#, options: .regularExpression) != nil
    }
    public var hasBoundSource: Bool { !accountID.isEmpty && folderPath?.isEmpty == false && (1...50).contains(allowedSenders.count) && allowedSenders.allSatisfy(Self.validSender) && (requireAuthentication == false || trustedAuthService.map(Self.validAuthService) == true) }
    public var configurationFingerprint: String {
        let fields = [id, accountID, boundAccountFingerprint ?? "", folderPath ?? "", allowedSenders.sorted().joined(separator: ","), subjectContains, bodyContains, response, String(useAI), delivery, String(dailyLimit), String(requireAuthentication != false), trustedAuthService?.lowercased() ?? "", String(updatedAt.timeIntervalSince1970), String(activationUIDValidity ?? 0), String(afterUID ?? 0)]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return MailStore.hash(String(decoding: (try? encoder.encode(fields)) ?? Data(), as: UTF8.self) + String(decoding: (try? encoder.encode(policy)) ?? Data(), as: UTF8.self))
    }
    public func matches(_ mail: MailMessage) -> Bool {
        matchesSource(mail) && (subjectContains.isEmpty || mail.subject.localizedCaseInsensitiveContains(subjectContains)) && (bodyContains.isEmpty || mail.text.localizedCaseInsensitiveContains(bodyContains))
    }
    public func matchesSource(_ mail: MailMessage) -> Bool {
        guard hasBoundSource, mail.accountID == accountID, mail.folder == folderPath else { return false }
        return allowedSenders.contains { mail.from.email.caseInsensitiveCompare($0) == .orderedSame }
    }
    public func isNew(_ mail: MailMessage) -> Bool {
        if let afterUID, let activationUIDValidity, mail.uid > 0 { return mail.uidValidity == activationUIDValidity && mail.uid > afterUID }
        return activatedAt.map { mail.date >= $0 } ?? false
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
    public var runID: String?
    public var ruleFingerprint: String?
    public var sourceBodyVersion: String?
    public var draftFingerprint: String?
    public var updatedAt: Date?
    public var attempts: Int? = 1
    public var agentVerified: Bool?
    public var sandboxRuntime: String?
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
    public static func canSend(_ draft: ComposeDraft, rule: MailResponder, mail: MailMessage, allowLocalSource: Bool = false) -> Bool {
        let recipients = draft.addresses(draft.to) + draft.addresses(draft.cc) + draft.addresses(draft.bcc)
        return rule.enabled && !rule.archived && (allowLocalSource || isProviderMail(mail)) && rule.delivery == "send" && rule.matches(mail) && draft.accountID == mail.accountID && draft.inReplyTo == mail.messageID && !mail.messageID.isEmpty && MailAddress.isValid(mail.from.email) && recipients.count == 1 && recipients[0].email.caseInsensitiveCompare(mail.from.email) == .orderedSame && draft.cc.isEmpty && draft.bcc.isEmpty && draft.attachments.isEmpty && (draft.htmlBody ?? "").isEmpty
    }
    public static func accountFingerprint(_ account: MailAccount) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return MailStore.hash(String(decoding: (try? encoder.encode(account)) ?? Data(), as: UTF8.self))
    }
    public static func isProviderMail(_ mail: MailMessage) -> Bool {
        !mail.id.hasPrefix("import:") && ((mail.uid > 0 && mail.uidValidity > 0) || mail.popUID?.isEmpty == false)
    }
    public static func draftFingerprint(_ draft: ComposeDraft) -> String {
        let fields = [draft.accountID, draft.to, draft.cc, draft.bcc, draft.subject, draft.body, draft.htmlBody ?? "", draft.inReplyTo, draft.references, String(draft.automaticResponse == true)] + draft.attachments.map(\.id)
        return MailStore.hash(String(decoding: (try? JSONEncoder().encode(fields)) ?? Data(), as: UTF8.self))
    }
    public static func sourceFailure(_ rule: MailResponder, mail: MailMessage, raw: Data, allowLocalSource: Bool = false) -> String? {
        guard rule.matches(mail) else { return "邮件不在响应器绑定的来源范围内。" }
        guard allowLocalSource || isProviderMail(mail) else { return "导入资料或缺少服务商来源标识的邮件不能触发自动回复。" }
        guard MailAddress.isValid(mail.from.email), !mail.messageID.isEmpty else { return "来源邮件缺少有效发件地址或 Message-ID。" }
        if isAutomatic(mail, raw: raw) { return "自动通知、邮件列表或自动回复，已跳过以避免互相响应。" }
        guard unambiguousSender(mail, raw: raw) else { return "来源邮件的 From 不唯一或与白名单地址不一致，未启动响应。" }
        if rule.requireAuthentication != false && !authenticated(mail, raw: raw, service: rule.trustedAuthService ?? "") { return "服务商未确认发件域名通过 DMARC，未启动响应。" }
        return nil
    }
    public static func authenticated(_ mail: MailMessage, raw: Data, service: String) -> Bool {
        guard let fields = headerFields(raw) else { return false }
        let result = fields.first { line in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "authentication-results" else { return false }
            let server = parts[1].split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased()
            return server == service.lowercased()
        }
        guard unambiguousSender(mail, raw: raw) else { return false }
        guard let result, let domain = mail.from.email.split(separator: "@").last?.lowercased() else { return false }
        // The first result from the explicitly trusted receiving service wins;
        // a later injected pass cannot override its fail or missing alignment.
        return result.lowercased().components(separatedBy: ";").contains { clause in
            let c = clause.trimmingCharacters(in: .whitespaces)
            guard c.hasPrefix("dmarc=pass"), c.dropFirst(10).first.map({ $0.isWhitespace || $0 == "(" }) ?? true else { return false }
            guard let range = c.range(of: #"\bheader\.from\s*=\s*([^\s;()]+)"#, options: .regularExpression) else { return false }
            return c[range].split(separator: "=").last?.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) == domain
        }
    }
    private static func headerFields(_ raw: Data) -> [String]? {
        let input = String(decoding: raw.prefix(65536), as: UTF8.self)
        guard input.contains("\r\n\r\n") || input.contains("\n\n") else { return nil }
        let header = String(decoding: raw.prefix(65536), as: UTF8.self).components(separatedBy: "\r\n\r\n").first ?? ""
        var fields: [String] = []
        for line in header.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.isEmpty { break }
            if line.hasPrefix(" ") || line.hasPrefix("\t") { if !fields.isEmpty { fields[fields.count - 1] += " " + line.trimmingCharacters(in: .whitespaces) } }
            else { fields.append(line) }
        }
        return fields
    }
    private static func unambiguousSender(_ mail: MailMessage, raw: Data) -> Bool {
        guard let fields = headerFields(raw) else { return false }
        let fromFields = fields.filter { $0.lowercased().hasPrefix("from:") }
        guard fromFields.count == 1 else { return false }
        let addresses = MIMEParser.parseAddresses(String(fromFields[0].dropFirst(5)))
        return addresses.count == 1 && addresses[0].email.caseInsensitiveCompare(mail.from.email) == .orderedSame
    }
}
