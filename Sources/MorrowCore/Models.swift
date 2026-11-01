import Foundation

public enum MailError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

public struct MailAccount: Codable, Identifiable, Hashable, Sendable {
    public var id: String = UUID().uuidString
    public var name: String = ""
    public var email: String = ""
    public var imapHost: String = ""
    public var imapPort: Int = 993
    public var smtpHost: String = ""
    public var smtpPort: Int = 465
    public var smtpStartTLS: Bool = false
    public var signature: String = ""
    public var enabled: Bool = true
    public var isDemo: Bool = false
    public var authMethod: String = "password"
    public var oauthProvider: String = "microsoft"
    public var oauthClientID: String = ""
    public var receiveProtocol: String?
    public var usesPOP: Bool { receiveProtocol == "pop3" }
    public init() {}
    public static func preset(_ provider: String) -> MailAccount {
        var a = MailAccount(); a.name = provider
        switch provider {
        case "网易 163": a.imapHost = "imap.163.com"; a.smtpHost = "smtp.163.com"
        case "网易 126": a.imapHost = "imap.126.com"; a.smtpHost = "smtp.126.com"
        case "QQ 邮箱": a.imapHost = "imap.qq.com"; a.smtpHost = "smtp.qq.com"
        case "iCloud": a.imapHost = "imap.mail.me.com"; a.smtpHost = "smtp.mail.me.com"; a.smtpPort = 587; a.smtpStartTLS = true
        case "Gmail": a.imapHost = "imap.gmail.com"; a.smtpHost = "smtp.gmail.com"; a.oauthProvider = "google"; a.authMethod = "oauth"
        case "Outlook": a.imapHost = "outlook.office365.com"; a.smtpHost = "smtp.office365.com"; a.smtpPort = 587; a.smtpStartTLS = true; a.authMethod = "oauth"
        default: break
        }; return a
    }
    public func validate() throws {
        guard MailAddress.isValid(email), !imapHost.isEmpty, !smtpHost.isEmpty,
              (1...65535).contains(imapPort), (1...65535).contains(smtpPort),
              Self.validHost(imapHost), Self.validHost(smtpHost) else {
            throw MailError.message("请检查邮箱地址、服务器和端口。")
        }
    }
    private static func validHost(_ host: String) -> Bool {
        !host.contains(where: { $0.isWhitespace || "/?#@\\".contains($0) })
    }
}

public struct MailAddress: Codable, Hashable, Sendable {
    public var name: String
    public var email: String
    public init(name: String = "", email: String) { self.name = name; self.email = email }
    public var display: String { name.isEmpty ? email : name }
    public static func isValid(_ value: String) -> Bool {
        !value.contains(where: \.isWhitespace) && value.utf8.count <= 254 && value.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
    }
}

public struct MailFolder: Codable, Identifiable, Hashable, Sendable {
    public var accountID: String
    public var path: String
    public var role: String
    public var id: String { accountID + ":" + path }
    public var name: String {
        switch role { case "inbox": return "收件箱"; case "sent": return "已发送"; case "drafts": return "草稿"; case "trash": return "废纸篓"; case "junk": return "垃圾邮件"; case "archive": return "归档"; default: return MailboxCodec.decode(path).components(separatedBy: "/").last ?? path }
    }
    public init(accountID: String, path: String, role: String = "custom") { self.accountID = accountID; self.path = path; self.role = role }
}
public struct MailMoveReceipt: Sendable {
    public var destinationValidity: UInt64?
    public var destinationUID: UInt64?
    public static func parse(_ response: String) -> MailMoveReceipt {
        let validity = MIMEParser.capture(#"COPYUID\s+(\d+)\s+\S+\s+\d+"#, response).flatMap(UInt64.init)
        let uid = MIMEParser.capture(#"COPYUID\s+\d+\s+\S+\s+(\d+)\]"#, response).flatMap(UInt64.init)
        return MailMoveReceipt(destinationValidity: validity, destinationUID: uid)
    }
}

public struct MailAttachment: Codable, Identifiable, Hashable, Sendable {
    public var remoteReference: MailRemoteAttachment?
    public var isRemoteOnly: Bool { remoteReference != nil && data.isEmpty && storedPath == nil }
    public var id: String = UUID().uuidString
    public var name: String
    public var mimeType: String
    public var data: Data
    public var contentID: String?
    public var storedPath: String?
    public var byteCount: Int = 0
    /// Digest of file bytes, retained when a message is saved after a flag edit.
    public var contentRevision: String?
    public init(name: String, mimeType: String, data: Data, contentID: String? = nil) { self.name = name; self.mimeType = mimeType; self.data = data; self.contentID = contentID }
    public var size: String { ByteCountFormatter.string(fromByteCount: Int64(max(data.count, byteCount)), countStyle: .file) }
}
public struct AttachmentTextPreview: Identifiable, Sendable {
    public var id: String
    public var name: String
    public var result: AttachmentText
    public init(id: String, name: String, result: AttachmentText) { self.id = id; self.name = name; self.result = result }
}

public enum MailCategory: String, CaseIterable, Codable, Sendable {
    case work = "工作", personal = "私人", finance = "账单", newsletter = "订阅", notification = "通知", travel = "出行", other = "其他"
}

public struct MailAnalysis: Codable, Hashable, Sendable {
    public var summary: String
    public var category: MailCategory
    public var priority: Int
    public var needsReply: Bool
    public var action: String?
    public var deadline: Date?
    public var deadlineEvidence: String?
    public var evidenceText: String?
    public var evidenceVersion: String?
    public var replySuggestion: String
    public var reasoning: String
    public var source: String
    public var analyzedAt: Date = Date()
    public init(summary: String, category: MailCategory = .other, priority: Int = 0, needsReply: Bool = false, action: String? = nil, deadline: Date? = nil, replySuggestion: String = "", reasoning: String = "", source: String = "规则分析") {
        self.summary = summary; self.category = category; self.priority = priority; self.needsReply = needsReply; self.action = action; self.deadline = deadline; self.replySuggestion = replySuggestion; self.reasoning = reasoning; self.source = source
    }
}

/// Synchronization inventory without retaining text, HTML, raw bytes or files.
public struct MailReadStateChange: Codable, Sendable, Equatable {
    public var id: String
    public var wasRead: Bool
    public init(id: String, wasRead: Bool) { self.id = id; self.wasRead = wasRead }
}

public struct MailFlagStateChange: Codable, Sendable, Equatable {
    public var id: String
    public var wasEnabled: Bool
    public init(id: String, wasEnabled: Bool) { self.id = id; self.wasEnabled = wasEnabled }
}

public struct MailLabelStateChange: Codable, Sendable, Equatable {
    public var id: String
    public var labels: [String]
    public init(id: String, labels: [String]) { self.id = id; self.labels = labels }
}

public struct MailSyncRecord: Identifiable, Equatable, Sendable {
    public var id: String
    public var uid: UInt64
    public var uidValidity: UInt64
    public var popUID: String?
    public init(id: String, uid: UInt64, uidValidity: UInt64, popUID: String? = nil) {
        self.id = id; self.uid = uid; self.uidValidity = uidValidity; self.popUID = popUID
    }
}

public enum MailContentAvailability: String, Codable, Hashable, Sendable {
    case complete, preview, textOnly
}

public struct MailMessage: Codable, Identifiable, Hashable, Sendable {
    public var id: String = UUID().uuidString
    public var accountID: String
    public var folder: String = "INBOX"
    public var uid: UInt64 = 0
    public var uidValidity: UInt64 = 0
    public var messageID: String = ""
    public var inReplyTo: String = ""
    public var references: String = ""
    public var from: MailAddress
    public var to: [MailAddress] = []
    public var cc: [MailAddress] = []
    public var bcc: [MailAddress]?
    public var replyTo: [MailAddress] = []
    public var subject: String
    public var date: Date = Date()
    public var text: String
    public var html: String = ""
    public var raw: Data = Data()
    public var attachments: [MailAttachment] = []
    public var isRead: Bool = false
    public var isStarred: Bool = false
    public var labels: [String] = []
    public var analysis: MailAnalysis?
    public var actionDone: Bool = false
    public var snoozedUntil: Date?
    public var note: String = ""
    public var localFlagModifiedAt: Date?
    public var popUID: String?
    /// Nil is a complete message from databases created before projections.
    public var contentAvailability: MailContentAvailability?
    public var contentRevision: String?
    public var bodyVersion: String { contentRevision ?? "legacy:" + id }
    public init(accountID: String, from: MailAddress, subject: String, text: String) { self.accountID = accountID; self.from = from; self.subject = subject; self.text = text }
    public var preview: String { String(text.replacingOccurrences(of: "\n", with: " ").prefix(180)) }
    public var normalizedSubject: String { subject.replacingOccurrences(of: #"^(?:(?:re|fw|fwd|回复|转发)\s*[:：]\s*)+"#, with: "", options: [.regularExpression, .caseInsensitive]).trimmingCharacters(in: .whitespacesAndNewlines) }
    public var threadKey: String { normalizedSubject.lowercased() }
    public var actionable: Bool { !actionDone && (analysis?.needsReply == true || analysis?.action != nil) }
    public var canonicalID: String { messageID.isEmpty ? id : accountID + ":message:" + messageID.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// A list/profile-navigation value that never retains full body or file bytes.
/// Complete messages can only be obtained through MailStore.message(_:).
public struct MailMessageSummary: Codable, Hashable, Sendable, Identifiable {
    private var projectedMessage: MailMessage
    public let hasHTML: Bool
    public var id: String { projectedMessage.id }
    public var contentRevision: String? { projectedMessage.contentRevision }
    public var displayMessage: MailMessage { projectedMessage }
    public init(message: MailMessage) {
        hasHTML = !message.html.isEmpty
        var value = message
        // CRLF is one grapheme. Replacing only LF splits it into CR + space
        // and can expand a 300-grapheme prefix beyond the cache's limit.
        // Bound both before normalization (allocation) and after (invariant).
        let bounded = String(message.text.prefix(300))
        let normalized = bounded.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        value.text = String(normalized.prefix(300))
        value.html = ""; value.raw = Data(); value.contentAvailability = .preview
        for index in value.attachments.indices { value.attachments[index].data = Data() }
        value.analysis?.evidenceText = nil
        projectedMessage = value
    }
}

public struct ComposeDraft: Codable, Identifiable, Sendable {
    public var id: String = UUID().uuidString
    public var accountID: String = ""
    public var to: String = ""
    public var cc: String = ""
    public var bcc: String = ""
    public var subject: String = ""
    public var body: String = ""
    public var htmlBody: String?
    public var automaticResponse: Bool?
    public var responderID: String?
    public var responderSourceMailID: String?
    public var attachments: [MailAttachment] = []
    public var inReplyTo: String = ""
    public var references: String = ""
    public var scheduledAt: Date?
    public var state: String = "draft"
    public var error: String?
    public var updatedAt: Date = Date()
    public init() {}
    public func addresses(_ text: String) -> [MailAddress] { MIMEParser.parseAddresses(text.replacingOccurrences(of: "；", with: ",").replacingOccurrences(of: ";", with: ",")) }
    public func validate() throws {
        let recipients = addresses(to) + addresses(cc) + addresses(bcc)
        guard !addresses(to).isEmpty, recipients.allSatisfy({ MailAddress.isValid($0.email) }) else { throw MailError.message("请填写有效的收件人地址，多个地址用逗号分隔。") }
        guard !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MailError.message("请填写邮件主题。") }
        guard ![subject, to, cc, bcc].contains(where: { $0.contains("\r") || $0.contains("\n") }) else { throw MailError.message("邮件头不能包含换行。") }
    }
}

public struct AgentSettings: Codable, Sendable {
    public var attachmentAutoDownloadLimitMB: Int?
    public var mailAnalysis: MailAnalysisSettings?
    public var runBudget: AgentRunBudget?
    public var enabled: Bool = true
    public var provider: String = "auto"
    public var ollamaURL: String = "http://127.0.0.1:11434"
    public var model: String = "qwen3.5:4b"
    public var openAIURL: String?
    public var openAIModel: String?
    /// Nonsecret profile reference; all ChatGPT credentials remain in the dedicated Keychain.
    public var chatGPTAccountID: String?
    public var chatGPTModel: String?
    public var replyLanguage: String?
    public var strictJSON: Bool?
    public var useDeveloperRole: Bool?
    public var embeddingDirectory: String = ""
    public var syncInterval: Int = 120
    public var notifications: Bool = false
    public var autoAnalyze: Bool = true
    public var indexAttachments: Bool = true
    /// Optional so configurations written before decision retrieval remain readable.
    public var retrievalDecision: RetrievalDecisionSettings?
    public init() {}
}

public struct SearchHit: Identifiable, Sendable {
    public var message: MailMessage
    public var score: Float
    public var method: String
    public var snippet: String = ""
    public var decisionRelevance: Double?
    public var id: String { message.id }
    public init(message: MailMessage, score: Float, method: String, snippet: String = "") { self.message = message; self.score = score; self.method = method; self.snippet = snippet }
}

public struct Delegation: Codable, Identifiable, Sendable {
    public var id: String = UUID().uuidString
    public var title: String = ""
    public var instruction: String = ""
    public var match: String = ""
    public var kind: String = "watch"
    public var action: String = "draft"
    public var active: Bool = true
    public var createdAt: Date = Date()
    public var nextRun: Date?
    public var intervalHours: Int = 24
    public var lastRun: Date?
    public var processedMessageIDs: [String] = []
    public var status: String = "等待相关邮件"
    public var recipient: String = ""
    public var sendAuthorized: Bool = false
    public var includeExisting: Bool = false
    public init() {}
}

public struct PartnerEvent: Codable, Identifiable, Sendable {
    public var id: String = UUID().uuidString
    public var date: Date = Date()
    public var title: String
    public var detail: String
    public var messageIDs: [String]
    public var delegationID: String?
    public var kind: String
    public init(title: String, detail: String, messageIDs: [String] = [], delegationID: String? = nil, kind: String = "analysis") { self.title = title; self.detail = detail; self.messageIDs = messageIDs; self.delegationID = delegationID; self.kind = kind }
}

public struct PartnerChat: Codable, Identifiable, Sendable {
    public var artifactIDs: [String]?
    public var continuationPrompt: String?
    public var executionTrace: AgentExecutionTrace?
    public var openUIID: String?
    public var draftIDs: [String]?
    public var sessionID: String?
    public var memoryIDs: [String]?
    public var materials: [ChatMaterial]?
    public var context: WorkspaceContext?
    public var id: String = UUID().uuidString
    public var role: String
    public var text: String
    public var date: Date = Date()
    public var messageIDs: [String] = []
    public init(role: String, text: String, messageIDs: [String] = []) { self.role = role; self.text = text; self.messageIDs = messageIDs }
}
