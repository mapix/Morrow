import Foundation
import MorrowCore

extension AppModel {
    func openDraft(_ value: ComposeDraft) {
        let draft = drafts.first(where: { $0.id == value.id }) ?? value
        if draft.state == "sent", let mail = mails.filter({ mail in
            mail.accountID == draft.accountID && mail.messageID == "<" + draft.id + "@morrow.local>" &&
                (folders.contains { $0.accountID == mail.accountID && $0.path == mail.folder && $0.role == "sent" } || mail.id == "sent:" + draft.id)
        }).sorted(by: { $0.uid > $1.uid }).first {
            dismissInlineTools(); navigate(.sent); selectedID = mail.id; return
        }
        workspacePage = .mail; destination = .drafts; selectedAccount = nil; selectedFolder = nil; selectedID = nil
        composer = draft
    }
    func createAgentDraft(_ operation: PartnerOperation, stableID: String? = nil) async throws -> ComposeDraft {
        if let stableID, let existing = try await store.object(ComposeDraft.self, kind: "draft", id: stableID) { return existing }
        guard let body = operation.text, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MailError.message("写作方案没有提供邮件正文，草稿尚未完成。") }
        let mail = operation.messageID.flatMap(mailByID)
        var draft = ComposeDraft()
        if let stableID { draft.id = stableID }
        draft.accountID = operation.accountID.flatMap { id in accounts.first { $0.id == id }?.id } ?? mail?.accountID ?? realAccounts.first?.id ?? accounts.first?.id ?? ""
        draft.to = operation.recipient ?? mail?.from.email ?? ""
        draft.subject = operation.subject ?? mail.map { "Re: " + $0.normalizedSubject } ?? "待补充主题"
        draft.body = body; draft.inReplyTo = mail?.messageID ?? ""
        draft.references = mail.map { ($0.references + " " + $0.messageID).trimmingCharacters(in: .whitespaces) } ?? ""
        // Creation is not delivery. The user can edit, preview and review it.
        await saveDraft(draft)
        guard let stored = try await store.object(ComposeDraft.self, kind: "draft", id: draft.id) else { throw MailError.message("草稿未保存，尚未完成写作。") }
        return stored
    }
    func followPreparedDraft(_ draft: ComposeDraft, submittedContext: WorkspaceContext?, sessionID: String) {
        guard activeSessionID == sessionID, composer == nil, let submittedContext, currentContext == submittedContext else { return }
        openDraft(draft)
    }
}
