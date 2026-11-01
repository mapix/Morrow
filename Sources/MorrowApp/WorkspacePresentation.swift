import Foundation
import MorrowCore

extension AppModel {
    func openWorkspace(_ page: WorkspacePage) {
        dismissInlineTools(); workspacePage = page
        if page == .desk { selectedRunID = nil }
        if page == .mail { chooseMailbox(nil) }
    }
    func openSettings() { dismissInlineTools(); navigate(.settings) }
    func prepareWorkChat(for mail: MailMessage) {
        var context = WorkspaceContext(page: "mail", label: mail.subject, mailIDs: [mail.id]); context.accountID = mail.accountID
        context.scopeMode = "hint"
        chatPinnedContext = context; newChatWork = true; chatExpanded = true
        if chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { chatInput = "推进这封邮件里的事项，先准备可用的成果。" }
        chatFocusNonce += 1; persistCurrentSessionDraft()
    }
}
