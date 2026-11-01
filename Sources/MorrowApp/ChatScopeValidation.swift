import Foundation
import MorrowCore

extension WorkspaceContext {
    var hasMailScope: Bool {
        mailList != nil || hasExplicitMailSelection || ["materials", "mail-list", "mail-results"].contains(page) || contactEmail != nil || !attachmentIDs.isEmpty
    }
    var enforcesMailScope: Bool { scopeMode != "hint" && hasMailScope }
}
extension AppModel {
    func submittedMailIDs(_ context: WorkspaceContext) -> Set<String> {
        if let descriptor = context.mailList {
            let ownEmails = Dictionary(accounts.map { ($0.id, $0.email) }, uniquingKeysWith: { _, last in last })
            return Set(mails.filter { mail in
                (context.accountID.map { $0 == mail.accountID } ?? true) && descriptor.matches(mail, ownEmail: ownEmails[mail.accountID])
            }.map(\.id))
        }
        let chosen = Set(context.mailIDs)
        let canonical = Set(mails.filter { chosen.contains($0.id) || chosen.contains($0.canonicalID) }.map(\.canonicalID))
        return Set(mails.filter { chosen.contains($0.id) || canonical.contains($0.canonicalID) }.map(\.id))
    }
    func validateChatOperation(_ operation: PartnerOperation, context: WorkspaceContext?, agreement: WorkAgreement? = nil, capturedMailIDs: Set<String>? = nil) throws {
        if let id = operation.messageID {
            guard let mail = mails.first(where: { $0.id == id }) else { throw MailError.message("邮件已不存在，未执行操作。") }
            if operation.type == "draft", let account = operation.accountID, account != mail.accountID { throw MailError.message("回复草稿的发件邮箱与原邮件来源不同；请在草稿中明确选择发件邮箱。") }
            if let agreement, !agreement.contains(mail) { throw MailError.message("所指邮件不在这项工作的已确认范围内。") }
            if let context, context.enforcesMailScope, !(capturedMailIDs ?? submittedMailIDs(context)).contains(id) { throw MailError.message("所指邮件不在本轮明确限定的范围内。") }
        }
        guard let context else { return }
        if context.enforcesMailScope && context.page == "materials", !["navigate", "draft", "compose", "calendar"].contains(operation.type) { throw MailError.message("本轮仅使用带入资料，未执行邮箱操作；可恢复跟随左侧后再提出要求。") }
        if context.scopeMode != "hint", let draftID = context.draftID, operation.type == "updateDraft", operation.kind != draftID { throw MailError.message("这份建议不属于本轮固定的草稿。") }
        if context.enforcesMailScope, let accountID = context.accountID, let target = operation.accountID, target != accountID { throw MailError.message("操作邮箱与本轮明确限定的邮箱不一致。") }
        if context.enforcesMailScope, let descriptor = context.mailList, let target = operation.accountID, !descriptor.accountIDs.contains(target) { throw MailError.message("操作邮箱不在本轮明确限定的检索范围内。") }
        if operation.type == "delegate", context.enforcesMailScope { throw MailError.message("请选择“形成新委托”，一起确认当前范围和后续邮件条件后开始持续工作。") }
        if ["readAttachment", "saveAttachment"].contains(operation.type), let id = operation.text {
            guard let entry = attachmentRecords.first(where: { $0.id == id }) else { throw MailError.message("附件不存在。") }
            if context.enforcesMailScope, !context.attachmentIDs.isEmpty, !context.attachmentIDs.contains(id) { throw MailError.message("附件不在本轮选择范围内。") }
            if context.enforcesMailScope, context.page == "attachments", context.attachmentIDs.isEmpty {
                if let kind = context.filter, kind != "全部", kind != entry.kind { throw MailError.message("附件不在当前类型筛选范围内。") }
                if let query = context.query, !query.isEmpty, !(entry.attachment.name + entry.mail.subject + entry.mail.from.display).localizedCaseInsensitiveContains(query) { throw MailError.message("附件不在当前查询范围内。") }
            }
            if context.enforcesMailScope && context.page != "attachments", !(capturedMailIDs ?? submittedMailIDs(context)).contains(entry.mail.id) { throw MailError.message("附件来源邮件不在本轮范围内。") }
        }
    }
}
