import Foundation
import MorrowCore

extension AppModel {
    var outboxDrafts: [ComposeDraft] { drafts.filter { ["queued", "sending", "uncertain"].contains($0.state) } }
    var editableDrafts: [ComposeDraft] { drafts.filter { !["sent", "queued", "sending", "uncertain"].contains($0.state) } }
    private func publishDelivery(_ draft: ComposeDraft) {
        if let index = drafts.firstIndex(where: { $0.id == draft.id }) { drafts[index] = draft } else { drafts.append(draft) }
    }
    private func cancelResponderDelivery(_ draft: ComposeDraft, detail: String) async {
        if var receipt = responderReceipts.first(where: { $0.draftID == draft.id }) {
            receipt.state = "cancelled"; receipt.detail = detail
            await saveResponderReceipt(receipt); await finishResponder(receipt)
        }
    }
    private func saveSentCopy(_ raw: Data, draft: ComposeDraft, account: MailAccount) async throws {
        var mail = MIMEParser.parse(raw, accountID: account.id, folder: folders.first { $0.accountID == account.id && $0.role == "sent" }?.path ?? "Sent")
        mail.id = "sent:" + draft.id; mail.isRead = true
        _ = try await store.upsert(mail)
    }
    /// Recovery only updates local records and cache. It never transmits mail.
    func reconcileStoredDeliveries() async {
        do {
            let recovered = try await store.recoverConfirmedDraftDeliveries(accounts: accounts, folders: folders)
            for draft in recovered { publishDelivery(draft); await reconcileResponderDelivery(draft) }
            for draft in drafts where draft.state == "sent" {
                guard let account = accounts.first(where: { $0.id == draft.accountID && !$0.isDemo }),
                      let receipt = try await store.object(DraftDeliveryReceipt.self, kind: "mail-delivery", id: draft.id),
                      try await store.messageSummaries(ids: ["sent:" + draft.id]).isEmpty else { continue }
                try await saveSentCopy(MIMEWriter.encode(draft, account: account, date: receipt.confirmedAt), draft: draft, account: account)
            }
        } catch { await log("本机投递记录待修复", detail: error.localizedDescription, kind: "delivery") }
    }
    func sendPending() async {
        guard !outboundBusy else { return }; outboundBusy = true; defer { outboundBusy = false }
        for candidate in drafts where candidate.state == "queued" && (candidate.scheduledAt ?? Date()) <= Date() {
            guard let account = accounts.first(where: { $0.id == candidate.accountID && $0.enabled && !$0.isDemo }) else { continue }
            if candidate.automaticResponse == true && !settings.enabled { await cancelSend(candidate); await cancelResponderDelivery(candidate, detail: "伙伴已暂停，自动回复已撤回。"); continue }
            let claimed: ComposeDraft
            do { guard let value = try await store.claimDraft(candidate.id) else { continue }; claimed = value }
            catch {
                if candidate.automaticResponse == true || candidate.responderID != nil { await cancelSend(candidate); await cancelResponderDelivery(candidate, detail: error.localizedDescription) }
                else { self.error = error.localizedDescription }
                continue
            }
            var draft = claimed; publishDelivery(draft)
            var delivered = false, transmissionStarted = false
            do {
                let secret = sendMailOverride == nil ? try await credentials.credential(account) : nil
                if draft.automaticResponse == true || draft.responderID != nil {
                    guard settings.enabled else { throw MailError.message("伙伴已暂停，自动投递已停止。") }
                    try await store.validateResponderDelivery(draft)
                }
                transmissionStarted = true
                let raw: Data
                if let sendMailOverride { raw = try await sendMailOverride(account, draft) }
                else { raw = try await transport.send(account, draft: draft, password: secret!) }
                delivered = true
                draft = try await store.finishDraftDelivery(claimed, outcome: .sent)
                publishDelivery(draft); await reconcileResponderDelivery(draft)
                try await saveSentCopy(raw, draft: draft, account: account)
                // Gmail stores SMTP-submitted mail in Sent automatically.
                if account.smtpHost.lowercased() != "smtp.gmail.com", let folder = folders.first(where: { $0.accountID == account.id && $0.role == "sent" }) {
                    do {
                        if let appendSentMailOverride { try await appendSentMailOverride(account, folder.path, raw) }
                        else if let secret { try await transport.append(account, folder: folder.path, raw: raw, password: secret) }
                    } catch { await log("已发送，本机已保存副本", detail: "服务器副本保存失败：" + error.localizedDescription, kind: "delivery") }
                }
                await log("邮件已发送", detail: draft.subject + " → " + draft.to, kind: "delivery")
                await reload()
            } catch {
                let detail = delivered ? "邮件已发送；本机副本暂未保存，未重新投递：" + error.localizedDescription : transmissionStarted ? "发送未取得明确回执：\(error.localizedDescription)。请先核对已发送邮箱，避免重复发送。" : "发送前检查未通过：" + error.localizedDescription
                let outcome: DraftDeliveryOutcome = delivered ? .sent : transmissionStarted ? .uncertain : .cancelled
                do { draft = try await store.finishDraftDelivery(claimed, outcome: outcome, error: detail) }
                catch { draft.state = delivered ? "sent" : "uncertain"; draft.error = detail }
                publishDelivery(draft); self.error = detail
                if !transmissionStarted && (draft.automaticResponse == true || draft.responderID != nil) { await cancelResponderDelivery(draft, detail: detail) }
                else { await reconcileResponderDelivery(draft) }
            }
        }
    }
}
