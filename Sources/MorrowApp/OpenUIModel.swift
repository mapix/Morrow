import Foundation
import MorrowCore

extension AppModel {
    func saveOpenUIInteraction(_ input: OpenUIInteraction) async {
        var value = input; if value.sessionID == nil { value.sessionID = taskSessionID }
        if let i = openUIInteractions.firstIndex(where: { $0.id == value.id }) { openUIInteractions[i] = value } else { openUIInteractions.append(value) }
        do { try await store.save(value, kind: "openui-interaction", id: value.id) }
        catch { self.error = error.localizedDescription }
    }
    func saveOpenUIValues(_ values: [String: OpenUIJSON], interactionID: String, revision: Int) async {
        guard var page = openUIInteractions.first(where: { $0.id == interactionID && $0.completedAt == nil && $0.stateRevision <= revision }) else { return }; page.values = values; page.stateRevision = revision
        if let i = openUIInteractions.firstIndex(where: { $0.id == interactionID }) { openUIInteractions[i] = page }
        do { try await store.updateOpenUIState(values, id: interactionID, revision: revision) } catch { self.error = error.localizedDescription }
    }
    func editOpenUIField(_ value: OpenUIJSON, key: String, interactionID: String, bindingName: String? = nil) -> OpenUIInteraction? {
        guard let i = openUIInteractions.firstIndex(where: { $0.id == interactionID && $0.completedAt == nil }) else { return nil }
        openUIInteractions[i].values[key] = value
        if let bindingName { openUIInteractions[i].values[bindingName] = value }
        openUIInteractions[i].stateRevision += 1
        let page = openUIInteractions[i]
        Task { do { try await store.updateOpenUIState(page.values, id: page.id, revision: page.stateRevision) } catch { self.error = error.localizedDescription } }
        return page
    }
    func proposeResponderInteraction(_ text: String) async {
        guard !partnerBusy else { return }; partnerBusy = true; defer { partnerBusy = false }; error = nil
        let run = AgentRun(title: "设定邮件响应器", instruction: text, phase: .working, summary: "正在把邮件条件与回复方式准备为可调整的交互。", isDemo: isDemo)
        await saveRun(run); selectedRunID = run.id; workspacePage = .desk
        do {
            let source = try await partner.structuredInteraction(text, accounts: accounts, settings: settings)
            await saveOpenUIInteraction(OpenUIInteraction(source: source, runID: run.id))
            await updateRun(run.id, phase: .waitingUser, summary: "条件和回复方式已备好。调整后保存，新来信会按这些条件响应。")
        } catch { self.error = error.localizedDescription; await updateRun(run.id, phase: .failed, summary: "这次结构化交互未能生成，原始要求已保留。") }
    }
    func handleOpenUIAction(_ event: OpenUIActionEvent, interactionID: String, buttonLabel: String) async throws {
        guard var page = openUIInteractions.first(where: { $0.id == interactionID && $0.completedAt == nil && $0.messageStatus == "completed" }) else { throw OpenUIError.message("这个交互已结束。") }
        let encoded = String(data: try JSONEncoder().encode(event), encoding: .utf8) ?? ""
        switch event.type {
        case "continue_conversation":
            if page.chatID != nil {
                try await answerAgentInteraction(interactionID: interactionID, response: "用户通过结构化交互提交的回答：" + event.humanFriendlyMessage + "\n表单与上下文：" + encoded)
            } else {
                guard !partnerBusy, sidebarTask == nil, let runID = page.runID,
                      agentRuns.contains(where: { $0.id == runID && [.waitingUser, .paused, .monitoring].contains($0.phase) }) else { throw OpenUIError.message("这份工作选择已结束或正在处理，请查看当前工作。") }
                page.completedAt = Date(); page.receipt = "选择已提交，正在继续这项工作。"; await saveOpenUIInteraction(page)
                selectedRunID = runID
                await ChatTaskContext.$runIntent.withValue(.newRequest) { await workspaceCommand("用户通过结构化交互提交的要求：" + event.humanFriendlyMessage + "\n表单与上下文：" + encoded) }
            }
        case "SaveResponder":
            guard buttonLabel.contains("响应器") && (buttonLabel.contains("保存") || buttonLabel.contains("启用")), let name = event.formName, let fields = event.formState?[name] else { throw OpenUIError.message("请通过明确的响应器保存按钮提交完整表单。") }
            func text(_ name: String) -> String { fields[name]?.value.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            if page.chatID != nil, !chatSessions.contains(where: { $0.id == page.sessionID && !$0.archived }) { throw OpenUIError.message("会话已归档，不能通过旧交互启用响应器。") }
            var rule = page.responderDraft ?? MailResponder(); rule.title = text("title"); rule.accountID = text("accountID"); rule.sender = text("sender"); rule.subjectContains = text("subject"); rule.bodyContains = text("body"); rule.response = text("response"); rule.delivery = text("delivery").isEmpty ? "send" : text("delivery"); rule.useAI = text("contentMode") == "ai"; rule.enabled = true
            rule.folderPath = text("folder").isEmpty ? "INBOX" : text("folder")
            rule.requireAuthentication = text("authentication") == "dmarc"
            rule.trustedAuthService = text("authService").isEmpty && accounts.first(where: { $0.id == rule.accountID })?.imapHost == "imap.gmail.com" ? "mx.google.com" : text("authService")
            rule.sessionID = page.sessionID
            if !text("dailyLimit").isEmpty { guard let limit = Int(text("dailyLimit")), (1...100).contains(limit) else { throw OpenUIError.message("每天响应上限须为1到100。") }; rule.dailyLimit = limit }
            if text("imageReply") == "image" {
                rule.imageReply = ResponderImageReply(model: text("imageModel").isEmpty ? nil : text("imageModel"), size: text("imageSize").isEmpty ? "1024x1024" : text("imageSize"), quality: text("imageQuality").isEmpty ? "auto" : text("imageQuality"))
                var policy = rule.policy; if !policy.allowedTools.contains("generateImage") { policy.allowedTools.append("generateImage") }; policy.maximumSeconds = max(360, policy.maximumSeconds); rule.executionPolicy = policy
            } else {
                rule.imageReply = nil; var policy = rule.policy; policy.allowedTools.removeAll { $0 == "generateImage" }; rule.executionPolicy = policy
            }
            let snapshot = page.responderDraft
            try await saveResponder(rule, expectedFingerprint: snapshot?.boundAccountFingerprint == nil ? nil : snapshot?.configurationFingerprint, expectNew: snapshot != nil && snapshot?.boundAccountFingerprint == nil)
            page.completedAt = Date(); page.receipt = "“\(rule.title)”已启用，只响应之后到来的匹配邮件。"; await saveOpenUIInteraction(page)
            if let session = page.sessionID, page.chatID != nil {
                var receipt = PartnerChat(role: "partner", text: page.receipt ?? "响应器已保存并启用。")
                receipt.id = page.id + ":saved"; receipt.sessionID = session; receipt.memoryIDs = []
                try await recordChat(receipt)
            }
            if let id = page.runID {
                if var run = agentRuns.first(where: { $0.id == id }) { run.responderID = rule.id; await saveRun(run) }
                await updateRun(id, phase: .monitoring, summary: page.receipt); await addStep(id, title: "响应器已启用", tool: "响应器", detail: "来自\(rule.sender)，主题包含\(rule.subjectContains)，\(rule.delivery == "send" ? "自动回复" : "准备草稿")。")
            }
        case "ConfigureResponder": responderEditor = MailResponder()
        case "OpenDraft":
            guard let id = event.params["draftId"]?.text, let draft = drafts.first(where: { $0.id == id }) else { throw OpenUIError.message("这份草稿暂不可用。") }; composer = draft
        case "OpenMailSource":
            guard let id = event.params["sourceId"]?.text, let mail = mails.first(where: { $0.id == id }) else { throw OpenUIError.message("这封原邮件暂不可用。") }
            if let allowed = page.sourceMailIDs, !allowed.contains(id) { throw OpenUIError.message("这封邮件不在这条回复的依据范围内。") }
            if let runID = page.runID, let scope = agentRuns.first(where: { $0.id == runID })?.agreement?.resolvedScope, !scope.contains(mail) { throw OpenUIError.message("这封邮件不在当前工作范围内。") }
            workspacePage = .mail; selectedID = mail.id; selectedFolder = mail.folder; selectedAccount = mail.accountID
        default: throw OpenUIError.unsupported("动作 " + event.type)
        }
        await log("结构化交互已处理", detail: encoded, kind: "openui-action")
    }
}
