import Foundation

public enum MailEvidence {
    public static let version = "mail-evidence-v1:" + AttachmentTextExtractor.version
    public static func forAnalysis(_ mail: MailMessage, store: MailStore) async -> MailMessage {
        var evidence = mail
        var text = mail.text
        for attachment in mail.attachments {
            let result: AttachmentText
            do { result = try await AttachmentTextExtractor.shared.extract(attachment, store: store) }
            catch { result = .init(text: "", source: "未提取", failure: "本机附件不可读，请重新同步或导入。") }
            text += "\n\n<attachment-data name=\"\(attachment.name)\">\n"
            text += result.text.isEmpty ? (result.failure ?? "没有可提取文字。") : result.text
            if result.truncated { text += "\n（提取达到限制，未覆盖完整附件）" }
            text += "\n</attachment-data>"
        }
        evidence.text = text; return evidence
    }
}
