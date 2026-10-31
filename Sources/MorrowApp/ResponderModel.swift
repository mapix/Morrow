import Foundation
import MorrowCore

extension AppModel {
    func saveResponder(_ value: MailResponder) async throws {
        try value.validate()
        if !value.accountID.isEmpty, !accounts.contains(where: { $0.id == value.accountID }) { throw MailError.message("请选择一个已连接的邮箱。") }
        var rule = value; let existing = responders.first { $0.id == rule.id }
        if existing == nil { rule.processedIDs = primaryMails.map(\.canonicalID) }
        rule.updatedAt = Date(); rule.status = rule.enabled ? "已启用，等待新的匹配邮件" : "已暂停"
        try await store.save(rule, kind: "responder", id: rule.id)
        if let i = responders.firstIndex(where: { $0.id == rule.id }) { responders[i] = rule } else { responders.append(rule) }
        if !rule.enabled {
            for receipt in responderReceipts where receipt.responderID == rule.id {
                if let draftID = receipt.draftID, let draft = drafts.first(where: { $0.id == draftID && $0.state == "queued" }) { await cancelSend(draft) }
            }
        }
        for run in agentRuns where run.responderID == rule.id && run.phase != .completed {
            let phase: AgentPhase = rule.enabled ? (run.phase == .paused ? .monitoring : run.phase) : .paused
            await updateRun(run.id, phase: phase, summary: rule.status)
        }
        await log("响应器已保存", detail: rule.title + "：" + rule.status, kind: "responder")
    }
    func setResponderEnabled(_ rule: MailResponder, _ enabled: Bool) async {
        var value = rule; value.enabled = enabled
        do { try await saveResponder(value) } catch { self.error = error.localizedDescription }
    }
    func saveResponderReceipt(_ receipt: ResponderReceipt) async {
        do { try await store.save(receipt, kind: "responder-receipt", id: receipt.id); if let i = responderReceipts.firstIndex(where: { $0.id == receipt.id }) { responderReceipts[i] = receipt } else { responderReceipts.append(receipt) } }
        catch { self.error = error.localizedDescription }
    }
    func responderDraft(_ rule: MailResponder, mail: MailMessage) async throws -> ComposeDraft {
        guard let account = accounts.first(where: { $0.id == mail.accountID && $0.enabled }) else { throw MailError.message("这个邮箱暂不可用。") }
        var draft = ComposeDraft(); draft.accountID = account.id; draft.to = mail.replyTo.first?.email ?? mail.from.email; draft.subject = "Re: " + mail.normalizedSubject; draft.inReplyTo = mail.messageID; draft.references = mail.references + " " + mail.messageID; draft.automaticResponse = true
        if rule.useAI { let readable = await MailEvidence.forAnalysis(mail, store: store); draft.body = try await partner.draft(instruction: rule.response, mails: [readable], settings: settings).text }
        else { draft.body = rule.body(for: mail, account: account) }
        return draft
    }
    func runResponders() async {
        guard !responderBusy, settings.enabled else { return }; responderBusy = true; defer { responderBusy = false }
        for original in responders where original.enabled && !original.archived {
            let processed = Set(original.processedIDs)
            for mail in primaryMails where original.matches(mail) && !processed.contains(mail.canonicalID) && !isOutbound(mail) {
                let role = folders.first { $0.accountID == mail.accountID && $0.path == mail.folder }?.role
                guard role != "trash", role != "junk", role != "sent" else { continue }
                var receipt = ResponderReceipt(responderID: original.id, mail: mail)
                do {
                    guard try await store.claimResponder(receipt) else { continue }
                    responderReceipts.append(receipt)
                    let raw = (try? await store.rawData(mail)) ?? mail.raw
                    let today = responderReceipts.filter { $0.responderID == original.id && $0.id != receipt.id && Calendar.current.isDateInToday($0.createdAt) && !["skipped", "failed", "cancelled"].contains($0.state) }.count
                    if ResponderPolicy.isAutomatic(mail, raw: raw) || today >= original.dailyLimit {
                        receipt.state = "skipped"; receipt.detail = today >= original.dailyLimit ? "已达到今天的响应上限" : "自动通知或自动回复，已跳过以避免循环"; await saveResponderReceipt(receipt); continue
                    }
                    var draft = try await responderDraft(original, mail: mail); draft.id = receipt.id
                    guard var rule = responders.first(where: { $0.id == original.id }), rule.enabled, rule.updatedAt == original.updatedAt else { receipt.state = "cancelled"; receipt.detail = "准备期间响应器已变更或暂停，未交付"; await saveResponderReceipt(receipt); continue }
                    try draft.validate(); receipt.draftID = draft.id
                    let account = accounts.first { $0.id == draft.accountID }
                    let maySend = ResponderPolicy.canSend(draft, rule: rule, mail: mail) && (!rule.useAI || !ReplySuggestionPolicy.containsUnverifiedConfirmation(draft.body))
                    if maySend && account?.isDemo == true { draft.state = "sent"; receipt.state = "simulated"; receipt.detail = "已自动模拟回复，只写入演示邮箱" }
                    else if maySend { draft.state = "queued"; draft.scheduledAt = Date().addingTimeInterval(10); receipt.state = "queued"; receipt.detail = "已按响应器设置加入发件队列" }
                    else { receipt.state = "draft"; receipt.detail = rule.delivery == "send" ? "收件人或确认内容需要核对，已保留草稿" : "已自动准备回复草稿" }
                    rule.processedIDs = Array(Set(rule.processedIDs + [mail.canonicalID])); rule.status = receipt.detail
                    let event = PartnerEvent(title: "响应器：" + rule.title, detail: receipt.detail, messageIDs: [mail.id], kind: "responder-result")
                    try await store.commitResponder(rule, receipt: receipt, draft: draft, event: event)
                    if let i = responders.firstIndex(where: { $0.id == rule.id }) { responders[i] = rule }; if let i = drafts.firstIndex(where: { $0.id == draft.id }) { drafts[i] = draft } else { drafts.append(draft) }
                    if let i = responderReceipts.firstIndex(where: { $0.id == receipt.id }) { responderReceipts[i] = receipt }; events.append(event)
                    if receipt.state == "simulated", let account {
                        let encoded = try MIMEWriter.encode(draft, account: account); var sent = MIMEParser.parse(encoded, accountID: account.id, folder: "Sent"); sent.id = "demo-responder:" + draft.id; sent.isRead = true; try await store.upsert(sent)
                    }
                    if let run = agentRuns.first(where: { $0.responderID == rule.id }) {
                        await addStep(run.id, title: "响应器匹配新邮件", tool: "响应器", detail: receipt.detail, sourceIDs: [mail.id])
                        await saveArtifact(AgentArtifact(runID: run.id, title: draft.subject, kind: .draft, content: draft.body, sourceMailIDs: [mail.id], linkedDraftID: draft.id))
                        if receipt.state == "draft" { await saveDecision(AgentDecision(runID: run.id, title: "这份响应可以采用吗？", detail: "已按你的响应器条件准备。可以修改或采用。", artifactID: agentArtifacts.last(where: { $0.runID == run.id && $0.linkedDraftID == draft.id })?.id)) }
                        await updateRun(run.id, phase: receipt.state == "draft" ? .waitingUser : .monitoring, summary: receipt.detail + "，继续关注下一封匹配邮件。")
                    }
                } catch { receipt.state = "failed"; receipt.detail = error.localizedDescription; await saveResponderReceipt(receipt) }
            }
        }
        if !responders.isEmpty { await reload() }
    }
}
