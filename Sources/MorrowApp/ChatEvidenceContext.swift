import Foundation
import MorrowCore

extension AppModel {
    var resolvedChatContext: WorkspaceContext {
        if var pinned = chatPinnedContext { if pinned.scopeMode == nil { pinned.scopeMode = "scope" }; return pinned }
        return currentContext
    }
    func pinCurrentChatScope() { var context = currentContext; context.scopeMode = "scope"; chatPinnedContext = context }
    /// Browsing supplies referents; only intentional scopes constrain searches.
    /// Selected content is the only initial mail evidence before a reading tool.
    func initialChatEvidence(_ context: WorkspaceContext?) async throws -> [MailMessage] {
        guard let context, context.hasExplicitMailSelection else { return [] }
        var seen = Set<String>(), result: [MailMessage] = []
        for id in context.mailIDs {
            guard let mail = mailByID(id), seen.insert(mail.canonicalID).inserted else { continue }
            if mail.contentAvailability == nil || mail.contentAvailability == .complete { result.append(mail) }
            else { guard let full = try await store.message(mail.id) else { throw MailError.message("所选邮件完整正文未在本机，请同步后重试。") }; result.append(full) }
            if result.count == 18 { break }
        }
        return result
    }
    func chatContextForModel(_ context: WorkspaceContext) -> WorkspaceContext {
        var value = context
        value.mailIDs = context.hasExplicitMailSelection ? Array(context.mailIDs.prefix(18)) : []
        if var list = value.mailList { list.folderRoles = [:]; value.mailList = list }
        value.label = chatScopeLabel(context)
        return value
    }
    func chatScopeLabel(_ context: WorkspaceContext) -> String {
        if context.scopeMode == "hint" { return L10n.t("界面提示：") + context.label }
        if context.page == "mail-list", context.mailList == nil { return L10n.t("已固定的邮件检索范围") }
        return L10n.t("已限定：") + context.label
    }
}
