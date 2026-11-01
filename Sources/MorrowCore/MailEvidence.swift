import Foundation

public enum MailEvidence {
    public static func forAutomaticAnalysis(_ mail: MailMessage) -> MailMessage {
        var evidence = mail
        let names = mail.attachments.map(\.name)
        let encoded = String(decoding: (try? JSONEncoder().encode(names)) ?? Data("[]".utf8), as: UTF8.self)
        evidence.text = String(mail.text.prefix(1000)) + "\n\n附件名称：" + encoded + "\n仅分析正文前1000字符，未读取正文后段或附件内容；不据此声称已覆盖完整邮件。"
        evidence.html = ""; evidence.raw = Data()
        evidence.attachments = mail.attachments.map { value in var item = value; item.data = Data(); item.storedPath = nil; return item }
        evidence.contentAvailability = .complete
        return evidence
    }
    public static let version = "mail-evidence-v1:" + AttachmentTextExtractor.version
    public static func forAnalysis(_ mail: MailMessage, store: MailStore) async throws -> MailMessage {
        let source: MailMessage
        if mail.contentAvailability != nil && mail.contentAvailability != .complete {
            guard let full = try await store.message(mail.id) else { throw MailError.message("邮件完整正文已不在本机，请同步后重试。") }; source = full
        } else { source = mail }
        var evidence = source
        var text = source.text
        for attachment in source.attachments {
            let result: AttachmentText
            do { result = try await AttachmentTextExtractor.shared.extract(attachment, store: store) }
            catch is CancellationError { throw CancellationError() }
            catch { result = .init(text: "", source: "未提取", failure: "本机附件不可读，请重新同步或导入。") }
            text += "\n\n<attachment-data name=\"\(attachment.name)\">\n"
            text += result.text.isEmpty ? (result.failure ?? "没有可提取文字。") : result.text
            if result.truncated { text += "\n（提取达到限制，未覆盖完整附件）" }
            text += "\n</attachment-data>"
        }
        evidence.text = text; return evidence
    }
}
