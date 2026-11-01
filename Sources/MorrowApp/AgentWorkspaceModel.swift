import Foundation
import MorrowCore

extension AppModel {
    var selectedRun: AgentRun? { agentRuns.first { $0.id == selectedRunID } }
    var pendingDecisions: [AgentDecision] { agentDecisions.filter { $0.state == "pending" } }
    var selectedArtifacts: [AgentArtifact] { agentArtifacts.filter { $0.runID == selectedRunID }.sorted { $0.createdAt > $1.createdAt } }
    func selectRun(_ run: AgentRun) { selectedRunID = run.id; selectedID = nil; workspacePage = .desk; inspectorPage = .artifacts }
    func proposeWork(_ text: String, source: MailMessage? = nil, context: WorkspaceContext? = nil, userInstruction: String? = nil) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !partnerBusy else { return }; partnerBusy = true; defer { partnerBusy = false }
        error = nil
        do {
            let authority = userInstruction ?? text
            let limit = try workContextLimit(context, instruction: authority)
            if isResponderSetup(authority) {
                guard context == nil || context?.scopeMode == "hint" || context?.page == "global" else { throw MailError.message("当前固定范围不会自动变成响应器条件。请到“响应器”独立设置，或先选择“使用整个邮箱”再明确设置邮箱、发件人和条件；本次没有启用规则。") }
                partnerBusy = false; await proposeResponderInteraction(text); return
            }
            let inventory = limit.map { ceiling in primaryMails.filter(CompiledWorkContext(ceiling).containsExisting) } ?? primaryMails
            var related: [MailMessage]
            if let source { related = inventory.filter { $0.canonicalID == source.canonicalID } }
            else if context?.page != "global", limit != nil { related = Array(inventory.prefix(8)) }
            else {
                let hits: [SearchHit]
                do { try await index.load(directory: settings.embeddingDirectory); hits = try await index.search(text, store: store) } catch { hits = (try? await store.keywordSearch(text)) ?? [] }
                let eligible = hits.filter { hit in limit?.containsExisting(hit.message) ?? true }
                related = eligible.isEmpty ? Array(inventory.prefix(8)) : Array(eligible.prefix(8).map(\.message))
            }
            for i in related.indices where related[i].contentAvailability != nil && related[i].contentAvailability != .complete {
                guard let full = try await store.message(related[i].id) else { throw MailError.message("工作所需邮件正文未在本机，请同步后重试。") }; related[i] = full
            }
            let request = text + (limit.map { "\n本次指定资料对象：" + $0.label + ($0.contactEmail.map { "；联系人邮箱：" + $0 } ?? "") + "。只有这一范围的资料可用；当前实际有" + String(inventory.count) + "封已同步邮件。" } ?? "")
            var agreement = try await partner.proposeAgreement(request, mails: related, settings: settings)
            agreement.hostScope = limit
            let resolved = try await partner.resolveScope(agreement.scope, mails: inventory, settings: settings)
            agreement.resolvedScope = limit?.constrain(resolved, against: primaryMails) ?? resolved
            if let limit { agreement.boundaries.append(limit.boundary) }
            var delegation = Delegation(); delegation.title = agreement.goal; delegation.instruction = text; delegation.match = agreement.match; delegation.kind = agreement.kind; delegation.intervalHours = agreement.intervalHours; delegation.recipient = agreement.recipient ?? ""; delegation.active = false; delegation.includeExisting = true; delegation.action = agreement.kind == "reply" || agreement.recipient != nil ? "draft" : "notify"
            await saveDelegation(delegation)
            guard var run = agentRuns.first(where: { $0.delegationID == delegation.id }) else { return }; run.agreement = agreement; run.phase = .waitingUser; run.steps = [AgentStep(title: "形成可审阅的工作约定", tool: "计划", detail: agreement.goal, state: .completed, sourceMailIDs: related.map(\.id))]; run.summary = "工作约定已准备，等你调整或交给我。"; run.sourceMailIDs = related.map(\.id); await saveRun(run); selectedRunID = run.id; workspacePage = .desk
            var decision = AgentDecision(runID: run.id, title: "按这份约定交给我吗？", detail: agreement.doneWhen); decision.kind = "agreement"; decision.delegationID = delegation.id; await saveDecision(decision)
        } catch { self.error = error.localizedDescription }
    }
    func updateAgreement(_ proposed: WorkAgreement, runID: String) async {
        guard var run = agentRuns.first(where: { $0.id == runID }) else { return }
        var agreement = proposed
        // The editor and model may narrow the submitted scope; neither replaces its host ceiling.
        agreement.hostScope = run.agreement?.hostScope
        if agreement.resolvedScope == nil { agreement.resolvedScope = run.agreement?.resolvedScope }
        let inventory = agreement.hostScope.map { ceiling in primaryMails.filter(CompiledWorkContext(ceiling).containsExisting) } ?? primaryMails
        if settings.enabled && (agreement.resolvedScope?.excludedExistingIDs == nil || agreement.scope != run.agreement?.scope) {
            do { agreement.resolvedScope = try await partner.resolveScope(agreement.scope, mails: inventory, settings: settings) }
            catch { self.error = error.localizedDescription; return }
        }
        if let limit = agreement.hostScope {
            agreement.resolvedScope = limit.constrain(agreement.resolvedScope ?? WorkScope(), against: primaryMails)
            agreement.boundaries.removeAll { $0.hasPrefix("资料范围上限：") }
            agreement.boundaries.append(limit.boundary)
        }
        run.agreement = agreement; run.title = agreement.goal; run.instruction = agreement.goal; await saveRun(run)
        if let id = run.delegationID, var delegation = delegations.first(where: { $0.id == id }) {
            delegation.title = agreement.goal; delegation.match = agreement.match; delegation.kind = agreement.kind; delegation.intervalHours = max(1, min(168, agreement.intervalHours)); delegation.recipient = agreement.recipient ?? delegation.recipient
            delegation.instruction = "目标：\(agreement.goal)\n完成条件：\(agreement.doneWhen)\n资料范围：\(agreement.scope)\n计划：\n" + agreement.steps.joined(separator: "\n") + "\n边界：\n" + agreement.boundaries.joined(separator: "\n")
            await saveDelegation(delegation)
        }
    }
    func saveInlineDraft(_ draft: ComposeDraft, artifactID: String) async {
        await saveDraft(draft); guard var artifact = agentArtifacts.first(where: { $0.id == artifactID }) else { return }; artifact.content = draft.body; artifact.title = draft.subject; await saveArtifact(artifact)
    }
    func saveReportEdit(_ text: String, artifactID: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, var artifact = agentArtifacts.first(where: { $0.id == artifactID }), artifact.isBrief else { return }
        guard text != artifact.content else { return }
        var revision = ArtifactRevision(content: artifact.content, sourceMailIDs: artifact.sourceMailIDs, createdAt: artifact.updatedAt ?? artifact.createdAt); revision.briefDocument = artifact.briefDocument
        artifact.revisions = (artifact.revisions ?? []) + [revision]
        artifact.content = text; artifact.briefDocument = nil; artifact.updatedAt = Date(); await saveArtifact(artifact)
        await addStep(artifact.runID, title: "你修改了这份简报", tool: "共同工作稿", detail: "修改保留在同一份简报，之前的内容留在版本中。", sourceIDs: artifact.sourceMailIDs)
    }
    func saveRun(_ run: AgentRun) async {
        do { try await store.save(run, kind: "agent-run", id: run.id); if let i = agentRuns.firstIndex(where: { $0.id == run.id }) { agentRuns[i] = run } else { agentRuns.append(run) } } catch { self.error = error.localizedDescription }
    }
    @discardableResult func ensureRun(_ delegation: Delegation) async -> String {
        if let run = agentRuns.first(where: { $0.delegationID == delegation.id }) { return run.id }
        var run = AgentRun(title: delegation.title, instruction: delegation.instruction, phase: delegation.active ? .queued : .paused, summary: delegation.status, isDemo: isDemo)
        run.delegationID = delegation.id; run.steps = [AgentStep(title: "接下委托", tool: "委托", detail: delegation.instruction, state: .completed)]
        await saveRun(run); return run.id
    }
    func updateRun(_ id: String, phase: AgentPhase, summary: String? = nil) async {
        guard var run = agentRuns.first(where: { $0.id == id }) else { return }; run.phase = phase; if let summary { run.summary = summary }; run.updatedAt = Date(); await saveRun(run)
    }
    func addStep(_ id: String, title: String, tool: String, detail: String, state: AgentStepState = .completed, sourceIDs: [String] = []) async {
        guard var run = agentRuns.first(where: { $0.id == id }) else { return }
        run.steps.append(AgentStep(title: title, tool: tool, detail: detail, state: state, sourceMailIDs: sourceIDs)); run.sourceMailIDs = Array(Set(run.sourceMailIDs + sourceIDs)); run.updatedAt = Date(); await saveRun(run)
    }
    func saveArtifact(_ artifact: AgentArtifact) async {
        do {
            try await store.save(artifact, kind: "agent-artifact", id: artifact.id)
            if let i = agentArtifacts.firstIndex(where: { $0.id == artifact.id }) { agentArtifacts[i] = artifact } else { agentArtifacts.append(artifact) }
            if var run = agentRuns.first(where: { $0.id == artifact.runID }) { if !run.artifactIDs.contains(artifact.id) { run.artifactIDs.append(artifact.id) }; await saveRun(run) }
        } catch { self.error = error.localizedDescription }
    }
    func saveDecision(_ decision: AgentDecision) async {
        do { try await store.save(decision, kind: "agent-decision", id: decision.id); if let i = agentDecisions.firstIndex(where: { $0.id == decision.id }) { agentDecisions[i] = decision } else { agentDecisions.append(decision) } } catch { self.error = error.localizedDescription }
    }
    func completeRunOutput(_ id: String, draft: ComposeDraft?, text: String, sourceIDs: [String]) async {
        var artifact = AgentArtifact(runID: id, title: draft?.subject ?? ((agentRuns.first { $0.id == id }?.title ?? "工作") + "简报"), kind: draft == nil ? .report : .draft, content: draft?.body ?? text, sourceMailIDs: sourceIDs, linkedDraftID: draft?.id)
        if draft == nil, let previous = agentArtifacts.filter({ $0.runID == id && $0.kind == .report }).max(by: { $0.createdAt < $1.createdAt }) {
            artifact.id = previous.id
            artifact.revisions = (previous.revisions ?? []) + [ArtifactRevision(content: previous.content, sourceMailIDs: previous.sourceMailIDs, createdAt: previous.createdAt)]
        }
        await saveArtifact(artifact)
        if draft != nil {
            for var previous in pendingDecisions where previous.runID == id && previous.artifactID != artifact.id {
                if previous.artifactID.flatMap({ key in agentArtifacts.first { $0.id == key } })?.kind == .draft { previous.state = "superseded"; previous.answer = "已有更新的回复草稿"; await saveDecision(previous) }
            }
            await saveDecision(AgentDecision(runID: id, title: "这份回复可以采用吗？", detail: "我已保留需要你确认的事项。你可以编辑内容或交给我继续改。", artifactID: artifact.id))
            await updateRun(id, phase: .waitingUser, summary: "回复草稿已准备，等你决定下一步。")
        } else {
            if openUIInteractions.contains(where: { $0.runID == id && $0.completedAt == nil }) { await updateRun(id, phase: .waitingUser, summary: "有一项信息需要你选择或补充，完成后我会接着推进。"); return }
            let ongoing = agentRuns.first(where: { $0.id == id })?.delegationID.flatMap { key in delegations.first { $0.id == key && $0.active } }
            await updateRun(id, phase: ongoing == nil ? .completed : .monitoring, summary: ongoing == nil ? "简报已准备，原邮件和证据可随时查看。" : "这轮简报已更新。我会继续关注范围内的邮件，直到你确认这件事完成。")
        }
    }
    func workspaceCommand(_ text: String) async {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !partnerBusy else { return }
        let id: String; let created = selectedRunID == nil; let previousDelegations = Set(delegations.map(\.id))
        if let selectedRunID { id = selectedRunID }
        else { let run = AgentRun(title: String(text.prefix(28)), instruction: text, phase: .queued, isDemo: isDemo); id = run.id; await saveRun(run); selectedRunID = id }
        executingRunIDs.insert(id)
        defer { executingRunIDs.remove(id) }
        await updateRun(id, phase: .reading, summary: "正在读取相关邮件与工作上下文。")
        await addStep(id, title: "接下你的新要求", tool: "委托", detail: text)
        let before = Set(drafts.map(\.id)); let previousChat = chat.count
        await askPartner(text, runID: id)
        if agentRuns.first(where: { $0.id == id })?.phase == .paused { return }
        guard chat.count > previousChat, let response = chat.last else { await updateRun(id, phase: .failed, summary: "这次没有取得完整结果。请重试。"); return }
        await addStep(id, title: "核对邮件与资料", tool: "邮件检索", detail: "本轮引用\(response.messageIDs.count)封邮件。", sourceIDs: response.messageIDs)
        if response.text.contains("还没有完成") { await updateRun(id, phase: .failed, summary: response.text); return }
        if created, let delegation = delegations.first(where: { !previousDelegations.contains($0.id) }), var actual = agentRuns.first(where: { $0.delegationID == delegation.id }) {
            if let temporary = agentRuns.first(where: { $0.id == id }) { actual.steps = temporary.steps + actual.steps; actual.sourceMailIDs = Array(Set(actual.sourceMailIDs + temporary.sourceMailIDs)) }
            await saveRun(actual); try? await store.remove(kind: "agent-run", id: id); agentRuns.removeAll { $0.id == id }; selectedRunID = actual.id; return
        }
        let prepared = drafts.filter { !before.contains($0.id) }
        if let draft = prepared.first { await addStep(id, title: "准备回复草稿", tool: "写作", detail: draft.subject, sourceIDs: response.messageIDs); await completeRunOutput(id, draft: draft, text: response.text, sourceIDs: response.messageIDs) }
        else { await addStep(id, title: "整理本轮结论", tool: "分析", detail: response.text, sourceIDs: response.messageIDs); await completeRunOutput(id, draft: nil, text: response.text, sourceIDs: response.messageIDs) }
    }
    func answerDecision(_ decision: AgentDecision, adopt: Bool) async {
        guard agentDecisions.first(where: { $0.id == decision.id })?.state == "pending" else { return }
        guard !agentRuns.contains(where: { $0.id == decision.runID && [.queued, .reading, .working].contains($0.phase) }) else { return }
        var value = decision; value.state = adopt ? "accepted" : "dismissed"; value.answer = adopt ? "采用" : "暂缓"
        if decision.kind == "agreement", let id = decision.delegationID, var delegation = delegations.first(where: { $0.id == id }) {
            if adopt, let agreement = agentRuns.first(where: { $0.id == decision.runID })?.agreement, agreement.resolvedScope == nil, settings.enabled {
                await updateAgreement(agreement, runID: decision.runID)
                guard agentRuns.first(where: { $0.id == decision.runID })?.agreement?.resolvedScope != nil else { return }
                delegation = delegations.first(where: { $0.id == id }) ?? delegation
            }
            delegation.active = adopt; if adopt && ["briefing", "followUp"].contains(delegation.kind) { delegation.nextRun = Date() }; await saveDelegation(delegation); await saveDecision(value); await updateRun(decision.runID, phase: adopt ? .queued : .paused, summary: adopt ? "工作约定已确认，我会接着推进。" : "工作约定已暂缓。"); if adopt { await runDelegations(forceID: id) }; return
        }
        if adopt, let artifactID = value.artifactID, let artifact = agentArtifacts.first(where: { $0.id == artifactID }), let draftID = artifact.linkedDraftID, let draft = drafts.first(where: { $0.id == draftID }) {
            if isDemo {
                guard let account = accounts.first(where: { $0.id == draft.accountID }) else { return }
                do {
                    let raw = try MIMEWriter.encode(draft, account: account); var mail = MIMEParser.parse(raw, accountID: account.id, folder: "Sent"); mail.id = "demo-delivery:" + draft.id; mail.isRead = true; try await store.upsert(mail); await saveDecision(value)
                    var completed = draft; completed.state = "sent"; await saveDraft(completed)
                    await addStep(value.runID, title: "完成演示投递", tool: "邮件", detail: "仅写入演示邮箱，不连接真实SMTP。", sourceIDs: [mail.id]); await updateRun(value.runID, phase: .waitingReply, summary: "演示回复已投递，继续等对方的新邮件。"); await reload()
                } catch { self.error = error.localizedDescription }
            } else { await saveDecision(value); composer = draft; await updateRun(value.runID, phase: .waitingUser, summary: "已打开草稿，请确认内容并发送。") }
        } else { await saveDecision(value); await updateRun(value.runID, phase: .paused, summary: "这一步已暂缓，你可以补充要求后继续。") }
    }
    func toggleRun(_ run: AgentRun) async {
        guard !pendingDecisions.contains(where: { $0.runID == run.id && $0.kind == "agreement" }) else { return }
        if let id = run.responderID, let rule = responders.first(where: { $0.id == id }) { await setResponderEnabled(rule, !rule.enabled); await updateRun(run.id, phase: rule.enabled ? .paused : .monitoring, summary: rule.enabled ? "响应器已暂停。" : "响应器已恢复，继续关注匹配来信。"); return }
        if let id = run.delegationID, var d = delegations.first(where: { $0.id == id }) { d.active.toggle(); await saveDelegation(d); await updateRun(run.id, phase: d.active ? .queued : .paused, summary: d.active ? "已恢复，我会接着整理这项工作。" : "委托已暂停。"); if d.active { await runDelegations(forceID: id) } }
        else { await updateRun(run.id, phase: run.phase == .paused ? .queued : .paused, summary: run.phase == .paused ? "已恢复。" : "工作已暂停。") }
    }
    func workMatches(_ mail: MailMessage, delegation: Delegation) -> Bool {
        if agentRuns.contains(where: { $0.delegationID == delegation.id && $0.isDemo }), accounts.first(where: { $0.id == mail.accountID })?.isDemo != true { return false }
        if let agreement = agentRuns.first(where: { $0.delegationID == delegation.id })?.agreement, agreement.resolvedScope != nil || agreement.hostScope != nil { return agreement.contains(mail) }
        return WorkScope.matches(delegation.match, mail: mail)
    }
    func finishWork(_ id: String) async {
        guard let run = agentRuns.first(where: { $0.id == id }) else { return }
        if let key = run.delegationID, var delegation = delegations.first(where: { $0.id == key }) { delegation.active = false; await saveDelegation(delegation) }
        if let key = run.responderID, let rule = responders.first(where: { $0.id == key }) { await setResponderEnabled(rule, false) }
        for var decision in pendingDecisions where decision.runID == id { decision.state = "dismissed"; decision.answer = "用户结束委托"; await saveDecision(decision) }
        await addStep(id, title: "用户确认结束这项委托", tool: "工作约定", detail: run.agreement?.doneWhen ?? "保留已有成果，停止后续触发。")
        await updateRun(id, phase: .completed, summary: "你已确认结束这项委托，成果与原邮件已保留。")
    }
}
