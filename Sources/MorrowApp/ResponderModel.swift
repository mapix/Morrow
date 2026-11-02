import Foundation
import MorrowCore

extension AppModel {
    func saveResponder(_ value: MailResponder) async throws {
        var rule = value
        rule.sender = rule.sender.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        rule.senderAllowlist = Array(Set(rule.sender.isEmpty ? (rule.senderAllowlist ?? []) : MailResponder.parseAllowlist(rule.sender))).sorted()
        rule.sender = rule.senderAllowlist?.joined(separator: ", ") ?? ""
        rule.trustedAuthService = rule.trustedAuthService?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let account = accounts.first(where: { $0.id == rule.accountID && $0.enabled }) else { throw MailError.message("请选择一个可用的已连接邮箱。") }
        rule.boundAccountFingerprint = ResponderPolicy.accountFingerprint(account)
        rule.boundAccountEmail = account.email
        try rule.validate()
        if account.imapHost == "imap.gmail.com", rule.requireAuthentication != false, rule.trustedAuthService != "mx.google.com" { throw MailError.message("Gmail 的来源验证必须使用接收服务 mx.google.com。") }
        guard folders.contains(where: { $0.accountID == account.id && $0.path == rule.folderPath && !["trash", "junk", "sent"].contains($0.role) }) || (account.isDemo && rule.folderPath == "INBOX") else { throw MailError.message("来源文件夹必须属于绑定邮箱，且不是已发送、垃圾箱或废纸篓。") }
        let existing = responders.first { $0.id == rule.id }
        if existing == nil || existing?.accountID != rule.accountID || existing?.folderPath != rule.folderPath || existing?.allowedSenders != rule.allowedSenders || existing?.boundAccountFingerprint != rule.boundAccountFingerprint || rule.activatedAt == nil {
            let inventory = mails.filter { $0.accountID == rule.accountID && $0.folder == rule.folderPath }
            rule.activatedAt = Date()
            if let newest = inventory.filter({ $0.uid > 0 }).max(by: { $0.uid < $1.uid }) { rule.afterUID = newest.uid; rule.activationUIDValidity = newest.uidValidity }
            let matcher = ResponderSourceMatcher(rule)
            rule.processedIDs = inventory.filter(matcher.contains).map(\.canonicalID)
        }
        rule.updatedAt = Date(); rule.status = rule.enabled ? "已启用，等待绑定来源的新邮件" : "已暂停"
        try await store.save(rule, kind: "responder", id: rule.id)
        if activeResponderID == rule.id { responderExecutionTask?.cancel() }
        if let i = responders.firstIndex(where: { $0.id == rule.id }) { responders[i] = rule } else { responders.append(rule) }
        // Editing any authority cancels queued automatic deliveries. An SMTP
        // attempt already in progress is reconciled by its actual receipt.
        for var receipt in responderReceipts where receipt.responderID == rule.id && receipt.state == "queued" {
            if let draftID = receipt.draftID, let draft = drafts.first(where: { $0.id == draftID && $0.state == "queued" && $0.responderID == rule.id }) {
                await cancelSend(draft); receipt.state = "cancelled"; receipt.detail = "响应器已调整或暂停，自动投递已撤回。"; await saveResponderReceipt(receipt)
                await finishResponder(receipt)
            }
        }
        for run in agentRuns where run.responderID == rule.id && run.sourceMailIDs.isEmpty {
            await updateRun(run.id, phase: rule.enabled ? .monitoring : .paused, summary: rule.status)
        }
        await log("响应器已保存", detail: rule.title + "：" + rule.status, kind: "responder")
    }
    func setResponderEnabled(_ rule: MailResponder, _ enabled: Bool) async {
        var value = rule; value.enabled = enabled
        do { try await saveResponder(value) } catch { self.error = error.localizedDescription }
    }
    func saveResponderReceipt(_ receipt: ResponderReceipt) async {
        var receipt = receipt; receipt.updatedAt = Date()
        do { try await store.save(receipt, kind: "responder-receipt", id: receipt.id); if let i = responderReceipts.firstIndex(where: { $0.id == receipt.id }) { responderReceipts[i] = receipt } else { responderReceipts.append(receipt) } }
        catch { self.error = error.localizedDescription }
    }
    func responderDraft(_ rule: MailResponder, mail summary: MailMessage, runID: String? = nil, live: Bool = false) async throws -> ComposeDraft {
        guard !isQualityPreview else { throw MailError.message("本机界面验收模式不会启动响应器推理。") }
        guard let account = accounts.first(where: { $0.id == rule.accountID && $0.enabled }), let mail = try await store.message(summary.id) else { throw MailError.message("绑定邮箱或来源邮件暂不可用。") }
        if live || rule.boundAccountFingerprint != nil { guard rule.boundAccountFingerprint == ResponderPolicy.accountFingerprint(account) else { throw MailError.message("绑定邮箱的身份或连接配置已变化，请重新确认来源。") } }
        let raw = (try? await store.rawHeader(mail)) ?? Data()
        if let reason = ResponderPolicy.sourceFailure(rule, mail: mail, raw: raw, allowLocalSource: account.isDemo) { throw MailError.message(reason) }
        let fingerprint = rule.configurationFingerprint
        let fixed = rule.useAI ? nil : rule.body(for: mail, account: account)
        let sandbox = try ResponderSandboxRuntime()
        let policy = rule.policy
        func readInSandbox(_ text: String, name: String) async throws -> String {
            try sandbox.stageText(text, name: name)
            let output = try await sandbox.run("cat input/" + name, policy: policy)
            guard output.exitCode == 0, !output.timedOut, !output.truncated else { throw MailError.message("沙箱读取未完成，已停止回复：" + String(output.stderr.prefix(500))) }
            return output.stdout
        }
        let result = try await ResponderAgentLoop.run(mail: mail, attachmentIDs: Set(mail.attachments.map(\.id)), fixedBody: fixed, policy: policy,
            plan: { history in try await self.partner.responderPlan(rule: rule, mail: mail, history: history, settings: self.settings, fixedBody: fixed) },
            tool: { operation in
                switch operation.type {
                case "read":
                    let text = try await self.partner.readEvidence(mail, settings: self.settings)
                    return try await readInSandbox("来源ID：\(mail.id)；发件人：\(mail.from.email)；主题：\(mail.subject)\n实际读取的正文：\n\(text)", name: "mail.txt")
                case "attachments": return try await readInSandbox("触发邮件的附件（\(mail.attachments.count)）：\n" + mail.attachments.map { "附件ID：\($0.id)；文件名：\($0.name)；大小：\($0.byteCount)" }.joined(separator: "\n"), name: "attachment.txt")
                case "readAttachment":
                    guard let attachment = mail.attachments.first(where: { $0.id == operation.text }) else { throw MailError.message("附件超出绑定来源。") }
                    let bytes = try await self.store.attachmentData(attachment, maximumBytes: 32 * 1024 * 1024)
                    let extracted = try await AttachmentTextExtractor.shared.extract(attachment, store: self.store, bytes: bytes)
                    if let failure = extracted.failure { return try await readInSandbox("附件\(attachment.name)未能提取：\(failure)", name: "attachment.txt") }
                    let evidence = MailMessage(accountID: mail.accountID, from: mail.from, subject: attachment.name, text: extracted.text)
                    return try await readInSandbox("附件ID：\(attachment.id)；原邮件ID：\(mail.id)\n" + (try await self.partner.readEvidence(evidence, settings: self.settings)), name: "attachment.txt")
                case "sandbox":
                    let output = try await sandbox.run(operation.text ?? "", policy: policy)
                    guard output.exitCode == 0, !output.timedOut, !output.truncated, output.violations == 0 else { throw MailError.message("沙箱工具失败或越界，已停止回复：" + String(output.stderr.prefix(500))) }
                    return "Anthropic Sandbox Runtime 执行回执（exit=0）：\n" + output.stdout
                default: throw MailError.message("响应器工具未获授权。")
                }
            }, verify: { body, history in
                if rule.useAI && ReplySuggestionPolicy.containsUnverifiedConfirmation(body) { return .init(approved: false, issues: ["回复包含尚未核验的完成确认，请只陈述实际读取或完成的事实。"] ) }
                return try await self.partner.verifyResponder(body: body, rule: rule, history: history, settings: self.settings)
            }, checkpoint: {
                try Task.checkCancellation()
                guard self.settings.enabled else { throw MailError.message("伙伴已暂停，响应未交付。") }
                if live {
                    guard let current = self.responders.first(where: { $0.id == rule.id }), current.enabled, !current.archived, current.configurationFingerprint == fingerprint else { throw MailError.message("响应器已变更或暂停，响应未交付。") }
                }
            }, progress: { stage, detail in
                if live { self.responderStage = detail }
                if let runID {
                    if var run = self.agentRuns.first(where: { $0.id == runID }), let i = run.steps.lastIndex(where: { $0.state == .active }) { run.steps[i].state = .completed; await self.saveRun(run) }
                    await self.updateRun(runID, phase: stage == "reading" || stage == "tool" ? .reading : .working, summary: detail)
                    await self.addStep(runID, title: detail, tool: stage, detail: "仅限绑定邮箱和触发邮件", state: .active, sourceIDs: [mail.id])
                }
            })
        var draft = ComposeDraft(); draft.accountID = account.id; draft.to = mail.from.email; draft.subject = "Re: " + mail.normalizedSubject
        draft.inReplyTo = mail.messageID; draft.references = (mail.references + " " + mail.messageID).trimmingCharacters(in: .whitespaces)
        draft.automaticResponse = true; draft.responderID = rule.id; draft.responderSourceMailID = mail.id; draft.body = result.body
        if let runID {
            if var run = agentRuns.first(where: { $0.id == runID }), let i = run.steps.lastIndex(where: { $0.state == .active }) { run.steps[i].state = .completed; await saveRun(run) }
            await addStep(runID, title: "回复已通过核对", tool: "verify", detail: result.analysis, sourceIDs: [mail.id])
        }
        return draft
    }
    func runResponders(retryReceiptID: String? = nil) async {
        guard !isQualityPreview else { return }
        guard !responderBusy, settings.enabled else { return }
        let activeRules = responders.filter { $0.enabled && !$0.archived && $0.hasBoundSource && $0.boundAccountFingerprint != nil }
        guard !activeRules.isEmpty else { return }; responderBusy = true
        defer { responderBusy = false; activeResponderID = nil; responderStage = ""; responderExecutionTask = nil }
        var processedThisPass = 0
        let existingReceipts = Set(responderReceipts.map(\.id))
        for original in activeRules {
            guard let sourceAccount = accounts.first(where: { $0.id == original.accountID && $0.enabled }) else { continue }
            if original.boundAccountFingerprint != ResponderPolicy.accountFingerprint(sourceAccount) {
                var paused = original; paused.enabled = false; paused.status = "绑定邮箱配置已变化，已暂停；请重新确认来源。"
                try? await store.save(paused, kind: "responder", id: paused.id)
                if let i = responders.firstIndex(where: { $0.id == paused.id }) { responders[i] = paused }; continue
            }
            let processed = Set(original.processedIDs)
            let matcher = ResponderSourceMatcher(original)
            let candidates = mails.filter { matcher.contains($0) && original.isNew($0) && (!processed.contains($0.canonicalID) || retryReceiptID == ResponderReceipt(responderID: original.id, mail: $0).id) && !isOutbound($0) }
            for summary in candidates {
                if processedThisPass >= 4 || Task.isCancelled { return }
                var receipt = ResponderReceipt(responderID: original.id, mail: summary)
                if let retryReceiptID, receipt.id != retryReceiptID { continue }
                if existingReceipts.contains(receipt.id) && retryReceiptID != receipt.id { continue }
                do {
                    guard let mail = try await store.message(summary.id), original.matches(mail) else { continue }
                    guard try await store.claimResponder(receipt, retry: retryReceiptID == receipt.id) else { continue }
                    receipt = try await store.object(ResponderReceipt.self, kind: "responder-receipt", id: receipt.id) ?? receipt
                    processedThisPass += 1
                    if let i = responderReceipts.firstIndex(where: { $0.id == receipt.id }) { responderReceipts[i] = receipt } else { responderReceipts.append(receipt) }
                    let raw = (try? await store.rawHeader(mail)) ?? Data()
                    let today = responderReceipts.filter { $0.responderID == original.id && $0.id != receipt.id && Calendar.current.isDateInToday($0.createdAt) && !["skipped", "failed", "cancelled"].contains($0.state) }.count
                    if let reason = ResponderPolicy.sourceFailure(original, mail: mail, raw: raw, allowLocalSource: sourceAccount.isDemo) { receipt.state = "skipped"; receipt.detail = reason; await saveResponderReceipt(receipt); continue }
                    if today >= original.dailyLimit { receipt.state = "skipped"; receipt.detail = "已达到今天的响应上限。"; await saveResponderReceipt(receipt); continue }
                    var run = AgentRun(title: original.title + " · " + mail.subject, instruction: original.response, phase: .reading, sourceMailIDs: [mail.id], isDemo: accounts.first(where: { $0.id == mail.accountID })?.isDemo == true)
                    run.responderID = original.id; receipt.runID = run.id; receipt.ruleFingerprint = original.configurationFingerprint; receipt.sourceBodyVersion = mail.bodyVersion
                    await saveResponderReceipt(receipt); await saveRun(run); activeResponderID = original.id
                    let execution = Task(priority: .utility) { try await self.responderDraft(original, mail: mail, runID: run.id, live: true) }
                    responderExecutionTask = execution
                    var draft = try await withTaskCancellationHandler { try await execution.value } onCancel: { execution.cancel() }
                    responderExecutionTask = nil; draft.id = receipt.id
                    receipt.agentVerified = true; receipt.sandboxRuntime = "anthropic-srt/0.0.81"
                    guard var rule = responders.first(where: { $0.id == original.id }), rule.enabled, rule.configurationFingerprint == original.configurationFingerprint else { throw MailError.message("响应器已变更，未交付。") }
                    try draft.validate(); receipt.draftID = draft.id; receipt.draftFingerprint = ResponderPolicy.draftFingerprint(draft)
                    let account = accounts.first { $0.id == draft.accountID }
                    let maySend = ResponderPolicy.canSend(draft, rule: rule, mail: mail, allowLocalSource: account?.isDemo == true)
                    if maySend && account?.isDemo == true { draft.state = "sent"; receipt.state = "simulated"; receipt.detail = "Agent 循环已完成，已模拟回复原发件人。" }
                    else if maySend { draft.state = "queued"; draft.scheduledAt = Date().addingTimeInterval(10); receipt.state = "queued"; receipt.detail = "Agent 循环已完成，10秒后回复原发件人。" }
                    else { receipt.state = "draft"; receipt.detail = "Agent 循环已完成，回复已保留为草稿。" }
                    rule.processedIDs = Array(Set(rule.processedIDs + [mail.canonicalID])); rule.status = receipt.detail
                    let event = PartnerEvent(title: "响应器：" + rule.title, detail: receipt.detail, messageIDs: [mail.id], kind: "responder-result")
                    try await store.commitResponder(rule, receipt: receipt, draft: draft, event: event)
                    if let i = responders.firstIndex(where: { $0.id == rule.id }) { responders[i] = rule }
                    if let i = drafts.firstIndex(where: { $0.id == draft.id }) { drafts[i] = draft } else { drafts.append(draft) }
                    if let i = responderReceipts.firstIndex(where: { $0.id == receipt.id }) { responderReceipts[i] = receipt }; events.append(event)
                    await saveArtifact(AgentArtifact(runID: run.id, title: draft.subject, kind: .draft, content: draft.body, sourceMailIDs: [mail.id], linkedDraftID: draft.id))
                    if receipt.state == "simulated", let account { let encoded = try MIMEWriter.encode(draft, account: account); var sent = MIMEParser.parse(encoded, accountID: account.id, folder: "Sent"); sent.id = "demo-responder:" + draft.id; sent.isRead = true; let stored = try await store.upsert(sent); await reload(incoming: [stored]) }
                    await finishResponder(receipt)
                } catch { responderExecutionTask = nil; receipt.state = Task.isCancelled || error is CancellationError ? "cancelled" : "failed"; receipt.detail = receipt.state == "cancelled" ? "响应器已调整或暂停，本轮已取消，未投递。" : error.localizedDescription; await saveResponderReceipt(receipt); await finishResponder(receipt) }
            }
        }
    }
    func finishResponder(_ receipt: ResponderReceipt) async {
        let complete = ["sent", "simulated"].contains(receipt.state)
        if let runID = receipt.runID {
            if var run = agentRuns.first(where: { $0.id == runID }) { for i in run.steps.indices where run.steps[i].state == .active { run.steps[i].state = ["failed", "cancelled", "uncertain"].contains(receipt.state) ? .failed : .completed }; await saveRun(run) }
            await updateRun(runID, phase: complete ? .completed : receipt.state == "queued" ? .queued : receipt.state == "draft" ? .waitingUser : .failed, summary: receipt.detail)
        }
        guard receipt.state != "queued", let rule = responders.first(where: { $0.id == receipt.responderID }), let sessionID = rule.sessionID else { return }
        var message = PartnerChat(role: "partner", text: "响应器“\(rule.title)”：\(receipt.detail)", messageIDs: [receipt.mailID])
        message.id = receipt.id + ":" + receipt.state; message.sessionID = sessionID; message.memoryIDs = []
        do { try await recordChat(message) } catch { self.error = error.localizedDescription }
    }
    func reconcileResponderDelivery(_ draft: ComposeDraft) async {
        guard var receipt = responderReceipts.first(where: { $0.draftID == draft.id }) else { return }
        receipt.state = draft.state == "sent" ? "sent" : "uncertain"
        receipt.detail = draft.state == "sent" ? (draft.responderID != nil ? "已完成 Agent 循环，SMTP 已确认回复原发件人。" : "你审阅后的回复已发送，SMTP 已确认收件人：" + draft.to) : "发送结果尚未确认，已停止重试；请核对已发送邮箱。"
        await saveResponderReceipt(receipt); await finishResponder(receipt)
    }
    func recoverResponderExecutions() async {
        for var receipt in responderReceipts where ["preparing", "queued"].contains(receipt.state) {
            let draft = receipt.draftID.flatMap { id in drafts.first { $0.id == id } }
            if let draft, ["sent", "uncertain"].contains(draft.state) { await reconcileResponderDelivery(draft); continue }
            if receipt.state == "preparing", draft == nil || draft?.state == "draft" {
                receipt.state = "failed"; receipt.detail = "上次 Agent 执行被中断，未完成投递；可以在原来源范围内重新处理。"
                await saveResponderReceipt(receipt); await finishResponder(receipt)
            } else if receipt.state == "queued", draft?.state == "draft" {
                receipt.state = "cancelled"; receipt.detail = "回复已撤回发件队列，没有重新发送。"; await saveResponderReceipt(receipt); await finishResponder(receipt)
            }
        }
    }
}
