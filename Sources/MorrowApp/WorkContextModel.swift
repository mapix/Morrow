import Foundation
import MorrowCore

extension AppModel {
    func workContextLimit(_ context: WorkspaceContext?, instruction: String) throws -> WorkContextLimit? {
        guard let context else { return nil }
        guard context.scopeMode != "hint" else { return nil }
        if context.page == "materials" { throw MailError.message("仅带入资料暂不支持持续邮箱委托。资料已保留在这条对话中；切回普通对话可先分析资料，或选择原邮件再形成委托。") }
        if context.page == "attachments" || !context.attachmentIDs.isEmpty { throw MailError.message("所选附件可以先在普通对话中分析。持续邮箱委托会读取原邮件，目前不能只关注附件；请打开所需原邮件后再形成委托。你的要求和资料已保留。") }
        if context.draftID != nil { throw MailError.message("当前是草稿范围，可以直接要求润色或修改。持续邮箱委托请先选择相关原邮件；本次要求已保留。") }
        let chosen = context.mailList == nil ? Set(context.mailIDs) : submittedMailIDs(context)
        let canonicalChosen = Set(mails.filter { chosen.contains($0.id) || chosen.contains($0.canonicalID) }.map(\.canonicalID))
        let existing = context.page == "global" ? primaryMails : primaryMails.filter { chosen.contains($0.id) || chosen.contains($0.canonicalID) || canonicalChosen.contains($0.canonicalID) }
        let accountIDs = context.mailList?.accountIDs ?? context.accountID.map { [$0] } ?? Array(Set(accounts.map(\.id) + existing.map(\.accountID)))
        let futureRequested = ["后续", "新邮件", "新来信", "持续", "继续关注", "继续跟进"].contains(where: instruction.contains)
        let existingOnly = ["仅当前", "只用当前", "只看当前", "只使用当前", "只处理已有", "只处理已收到", "仅已有", "不包括后续", "不包含后续", "不关注新邮件", "不要关注新邮件", "不处理新邮件", "不要处理新邮件", "不要持续", "不再跟进"].contains(where: instruction.contains)
        let future = futureRequested && !existingOnly
        let kind: WorkContextLimit.Kind = context.contactEmail != nil ? .contact : ["mail-list", "global"].contains(context.page) ? .mailbox : .selection
        return WorkContextLimit(kind: kind, label: context.label, existingMailIDs: existing.map(\.canonicalID), accountIDs: accountIDs, contactEmail: context.contactEmail, allowsFuture: future && kind != .selection)
    }
    func isResponderSetup(_ text: String) -> Bool {
        text.contains("响应器") || text.contains("自动响应") || (text.contains("自动回复") && !text.contains("不自动") && (text.contains("设置") || text.contains("设定") || text.contains("收到")))
    }
}
