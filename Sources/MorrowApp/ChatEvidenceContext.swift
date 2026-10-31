import Foundation
import MorrowCore

extension AppModel {
    /// A list supplies a search boundary. Selected content is the only mail
    /// evidence supplied before the agent requests a reading tool.
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
        if context.page == "mail-list", context.mailList == nil { return L10n.t("已固定的邮件检索范围") }
        return context.label
    }
}
