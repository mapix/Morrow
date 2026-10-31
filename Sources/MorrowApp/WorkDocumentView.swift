// Hallmark v2.0.0: Coral native work document. The prepared content is the working surface.
import SwiftUI
import MorrowCore

struct WorkDocumentView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    let run: AgentRun
    var isHandoff = false
    @EnvironmentObject var model: AppModel
    @State private var sourceMail: MailMessage?
    @State private var agreementExpanded = false
    @State private var historyExpanded = false

    private var currentRun: AgentRun { model.agentRuns.first { $0.id == run.id } ?? run }
    private var artifacts: [AgentArtifact] { model.agentArtifacts.filter { $0.runID == run.id }.sorted { $0.createdAt > $1.createdAt } }
    private var currentDraft: AgentArtifact? { let reportDate = artifacts.first { $0.kind == .report }?.createdAt ?? .distantPast; return artifacts.first { $0.kind == .draft && $0.createdAt >= reportDate } }
    private var currentArtifacts: [AgentArtifact] { artifacts.filter { $0.kind != .draft || $0.id == currentDraft?.id } }
    private var earlierDrafts: [AgentArtifact] { artifacts.filter { $0.kind == .draft && $0.id != currentDraft?.id } }
    private var decisions: [AgentDecision] { model.agentDecisions.filter { $0.runID == run.id }.sorted { $0.createdAt < $1.createdAt } }
    private var agreementPending: Bool { decisions.contains { $0.kind == "agreement" && $0.state == "pending" } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                heading
                ForEach(model.openUIInteractions.filter { $0.runID == run.id }) { interaction in
                    if interaction.completedAt == nil { NativeOpenUIView(interaction: interaction) }
                    else { DisclosureGroup(currentRun.responderID == nil ? L10n.t("之前的结构化选择") : L10n.t("最初确认的响应设置")) { NativeOpenUIView(interaction: interaction) }.font(Theme.label) }
                }
                if artifacts.isEmpty && !model.openUIInteractions.contains(where: { $0.runID == run.id }) {
                    if let agreement = currentRun.agreement {
                        agreementDocument(agreement)
                    } else {
                        preparingContent
                    }
                } else {
                    ForEach(currentArtifacts) { artifact in
                        artifactDocument(artifact)
                        WorkDocumentRule()
                    }
                    if !earlierDrafts.isEmpty {
                        DisclosureGroup(L10n.format("之前的回复（{0}）", "\(earlierDrafts.count)")) { ForEach(earlierDrafts) { artifact in artifactDocument(artifact).padding(.vertical, 16) } }.font(Theme.label)
                    }
                    if let agreement = currentRun.agreement {
                        DisclosureGroup(isExpanded: $agreementExpanded) {
                            agreementDocument(agreement).padding(.top, 12)
                        } label: {
                            Text(L10n.t("工作约定")).font(Theme.body.weight(.medium)).frame(minHeight: 44)
                        }
                    }
                }
                ForEach(decisions.filter { $0.artifactID == nil && $0.kind != "agreement" }) { decision in
                    WorkDecisionContent(decision: decision)
                }
                history
            }
            .frame(maxWidth: 900, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.top, 20)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .font(Theme.body)
        .foregroundStyle(Theme.ink)
        .background(Theme.paper)
        .tint(Theme.accent2)
        .sheet(item: $sourceMail) { mail in
            WorkSourceReader(mail: mail).environmentObject(model)
        }
        .onAppear { agreementExpanded = agreementPending }
        .onChange(of: agreementPending) { agreementExpanded = agreementPending }
        .onChange(of: run.id) {
            agreementExpanded = agreementPending
            historyExpanded = false
            sourceMail = nil
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                if !isHandoff {
                    Button { model.selectedRunID = nil } label: { Label(L10n.t("工作首页"), systemImage: "chevron.left") }.buttonStyle(.plain).font(Theme.label).foregroundStyle(Theme.secondary)
                }
                if model.agentRuns.count > 1 { Menu(L10n.t("切换工作")) {
                    ForEach(model.agentRuns.sorted { $0.updatedAt > $1.updatedAt }) { other in
                        Button(other.title + "（" + other.phase.label + "）") { model.selectRun(other) }
                    }
                }.menuStyle(.borderlessButton).fixedSize().font(Theme.label) }
                Spacer()
                if !agreementPending && (currentRun.delegationID != nil || currentRun.responderID != nil) && currentRun.phase != .completed {
                    Menu {
                        Button(currentRun.phase == .paused ? L10n.t("恢复关注") : L10n.t("暂停关注")) { Task { await model.toggleRun(currentRun) } }
                        if let id = currentRun.delegationID, currentRun.phase != .paused { Button(L10n.t("重新整理")) { Task { await model.runDelegations(forceID: id) } }.disabled(model.delegationBusy) }
                    } label: { Image(systemName: "ellipsis").frame(width: 30, height: 28) }.menuStyle(.borderlessButton).frame(width: 30).help(L10n.t("工作操作")).accessibilityLabel(L10n.t("工作操作"))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 20) {
                Text(currentRun.title)
                    .font(Theme.title)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Text(L10n.t(currentRun.phase.label))
                    .font(Theme.label)
                    .foregroundStyle(currentRun.phase == .failed ? Theme.error : Theme.secondary)
                    .fixedSize()
                    .accessibilityLabel(L10n.t("当前状态：") + L10n.t(currentRun.phase.label))
            }
            if !currentRun.summary.isEmpty && (artifacts.isEmpty || [.failed, .paused, .reading, .working].contains(currentRun.phase)) {
                WorkMarkdownContent(text: currentRun.summary)
                    .foregroundStyle(currentRun.phase == .failed ? Theme.error : Theme.secondary)
            }
        }
    }

    private var preparingContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            if currentRun.phase == .reading || currentRun.phase == .working {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text(L10n.t("正在准备可供你接手的内容"))
                }
            } else if currentRun.phase != .failed {
                Text(L10n.t("这项工作还没有形成产出。"))
                    .foregroundStyle(Theme.secondary)
            }
            if !currentRun.instruction.isEmpty {
                Text(currentRun.instruction)
                    .font(Theme.reader)
                    .lineSpacing(6)
                    .textSelection(.enabled)
            }
            WorkSourceLinks(ids: currentRun.sourceMailIDs, open: openSource)
        }
    }

    @ViewBuilder private func artifactDocument(_ artifact: AgentArtifact) -> some View {
        let related = decisions.filter { $0.artifactID == artifact.id }
        if let draftID = artifact.linkedDraftID,
           let draft = model.drafts.first(where: { $0.id == draftID }) {
            WorkInlineDraft(artifact: artifact, initial: draft, decisions: related, openSource: openSource, isPrimary: artifact.id == currentDraft?.id)
                .id(artifact.id)
        } else {
            VStack(alignment: .leading, spacing: 20) {
                Text(artifact.title).font(Theme.heading).textSelection(.enabled)
                if artifact.kind == .draft {
                    Text(L10n.t("关联的可编辑草稿暂不可用，已保留的正文如下。"))
                        .font(Theme.label).foregroundStyle(Theme.secondary)
                }
                if artifact.kind == .report { WorkReportContent(artifact: artifact) }
                else { WorkMarkdownContent(text: artifact.content) }
                if let revisions = artifact.revisions, !revisions.isEmpty {
                    DisclosureGroup(L10n.format("之前的版本（{0}）", "\(revisions.count)")) {
                        ForEach(revisions.reversed()) { revision in
                            VStack(alignment: .leading, spacing: 12) { Text(revision.createdAt.uiFormatted(date: .abbreviated, time: .shortened)).font(Theme.label).foregroundStyle(Theme.muted); WorkMarkdownContent(text: revision.content); WorkSourceLinks(ids: revision.sourceMailIDs, open: openSource) }.padding(.vertical, 16)
                        }
                    }.font(Theme.label)
                }
                ForEach(related) { decision in
                    WorkDecisionContent(decision: decision)
                }
                WorkSourceLinks(ids: artifact.sourceMailIDs, open: openSource)
            }
        }
    }

    private func agreementDocument(_ agreement: WorkAgreement) -> some View {
        WorkInlineAgreement(initial: agreement, runID: run.id, decisions: decisions.filter { $0.kind == "agreement" })
            .id("agreement:" + run.id)
    }

    private var history: some View {
        DisclosureGroup(isExpanded: $historyExpanded) {
            VStack(alignment: .leading, spacing: 24) {
                if !currentRun.sourceMailIDs.isEmpty {
                    WorkSourceLinks(ids: currentRun.sourceMailIDs, open: openSource)
                }
                if !currentRun.steps.isEmpty {
                    VStack(alignment: .leading, spacing: 18) {
                        Text(L10n.t("已记录的执行事实")).font(Theme.body.weight(.medium))
                        ForEach(currentRun.steps.sorted { $0.date < $1.date }) { step in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .firstTextBaseline, spacing: 16) {
                                    Text(step.title).font(Theme.body.weight(.medium))
                                    Spacer(minLength: 0)
                                    Text(stepLabel(step.state)).font(Theme.label)
                                        .foregroundStyle(step.state == .failed ? Theme.error : Theme.secondary)
                                }
                                if !step.detail.isEmpty { WorkMarkdownContent(text: step.detail) }
                                HStack(spacing: 16) {
                                    Text(step.tool)
                                    Text(step.date.uiFormatted(date: .abbreviated, time: .shortened)).monospacedDigit()
                                }.font(Theme.label).foregroundStyle(Theme.secondary)
                                WorkSourceLinks(ids: step.sourceMailIDs, open: openSource)
                            }
                        }
                    }
                }
                if !decisions.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(L10n.t("决定记录")).font(Theme.body.weight(.medium))
                        ForEach(decisions) { decision in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(decision.title)
                                Text(decision.answer ?? (decision.state == "pending" ? L10n.t("等待决定") : decision.state))
                                    .font(Theme.label).foregroundStyle(Theme.secondary)
                                Text(L10n.t("提出于 ") + decision.createdAt.uiFormatted(date: .abbreviated, time: .shortened))
                                    .font(Theme.label).foregroundStyle(Theme.secondary)
                            }
                        }
                    }
                }
                let events = model.events.filter { currentRun.delegationID != nil && $0.delegationID == currentRun.delegationID }.sorted { $0.date < $1.date }
                if !events.isEmpty {
                    ForEach(events) { event in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(event.title).font(Theme.body.weight(.medium))
                            WorkMarkdownContent(text: event.detail)
                            Text(event.date.uiFormatted(date: .abbreviated, time: .shortened))
                                .font(Theme.label).foregroundStyle(Theme.secondary)
                            WorkSourceLinks(ids: event.messageIDs, open: openSource)
                        }
                    }
                }
                if currentRun.steps.isEmpty && decisions.isEmpty && events.isEmpty {
                    Text(L10n.t("目前还没有执行或决定记录。"))
                        .foregroundStyle(Theme.secondary)
                }
            }
            .padding(.top, 16)
        } label: {
            Text(L10n.t("原邮件与工作记录")).font(Theme.body).frame(minHeight: 44)
        }
    }

    private func openSource(_ mail: MailMessage) { model.selectedID = mail.id; sourceMail = mail }
    private func stepLabel(_ state: AgentStepState) -> String {
        switch state {
        case .pending: return L10n.t("尚未开始")
        case .active: return L10n.t("正在处理")
        case .completed: return L10n.t("已完成")
        case .failed: return L10n.t("未完成")
        }
    }
}

private struct WorkReportContent: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    let artifact: AgentArtifact
    @EnvironmentObject var model: AppModel
    @State private var editing = false
    @State private var content = ""
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if editing {
                WorkDocumentEditor(title: L10n.t("简报正文"), text: $content, height: 440)
                HStack {
                    WorkDocumentButton(primary: true) { saving = true; Task { await model.saveReportEdit(content, artifactID: artifact.id); saving = false; if model.agentArtifacts.first(where: { $0.id == artifact.id })?.content == content { editing = false } } } label: { Text(saving ? L10n.t("正在保存") : L10n.t("保存简报修改")) }.disabled(saving || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    WorkDocumentButton { editing = false } label: { Text(L10n.t("取消修改")) }.disabled(saving)
                }
            } else {
                WorkMarkdownContent(text: artifact.content)
                WorkDocumentButton { content = artifact.content; editing = true } label: { Text(L10n.t("修改这份简报")) }
            }
        }.onChange(of: artifact.content) { if !editing { content = artifact.content } }
    }
}

private struct WorkInlineDraft: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    let artifact: AgentArtifact
    let initial: ComposeDraft
    let decisions: [AgentDecision]
    let openSource: (MailMessage) -> Void
    let isPrimary: Bool
    @EnvironmentObject var model: AppModel
    @State private var draft: ComposeDraft
    @State private var saved: ComposeDraft
    @State private var saving = false
    @State private var message: String?
    @State private var error: String?


    init(artifact: AgentArtifact, initial: ComposeDraft, decisions: [AgentDecision], openSource: @escaping (MailMessage) -> Void, isPrimary: Bool) {
        self.artifact = artifact; self.initial = initial; self.decisions = decisions; self.openSource = openSource; self.isPrimary = isPrimary
        _draft = State(initialValue: initial); _saved = State(initialValue: initial)
    }
    private var visibleDraft: ComposeDraft { model.workingArtifactID == artifact.id && model.workingDraft?.id == draft.id ? model.workingDraft ?? draft : draft }
    private var editable: Bool { model.draftIsEditable(initial) && (model.drafts.first(where: { $0.id == draft.id }).map(model.draftIsEditable) ?? true) }
    private var changed: Bool { !model.sameDraftContent(visibleDraft, saved) }
    private func editBinding(_ path: WritableKeyPath<ComposeDraft, String>, clearsHTML: Bool = false) -> Binding<String> {
        Binding(get: { visibleDraft[keyPath: path] }, set: { value in
            var update = visibleDraft; update[keyPath: path] = value; if clearsHTML { update.htmlBody = nil }
            draft = update; message = nil; model.activateWorkingDraft(update, artifactID: artifact.id)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(initial.state == "sent" ? L10n.t("已投递的回复") : L10n.t("回复草稿")).font(Theme.heading)
                Spacer(minLength: 0)
                if let account = model.accounts.first(where: { $0.id == draft.accountID }) {
                    Text(L10n.t("发件人：") + account.email).font(Theme.label).foregroundStyle(Theme.secondary).textSelection(.enabled)
                }
            }
            if editable {
                VStack(spacing: 6) {
                    WorkDraftField(title: L10n.t("收件人"), text: editBinding(\.to)).disabled(saving)
                    if !draft.cc.isEmpty { WorkDraftField(title: L10n.t("抄送"), text: editBinding(\.cc)).disabled(saving) }
                    if !draft.bcc.isEmpty { WorkDraftField(title: L10n.t("密送"), text: editBinding(\.bcc)).disabled(saving) }
                    WorkDraftField(title: L10n.t("主题"), text: editBinding(\.subject)).disabled(saving)
                }
            } else {
                WorkRecordField(title: L10n.t("收件人"), value: draft.to)
                if !draft.cc.isEmpty { WorkRecordField(title: L10n.t("抄送"), value: draft.cc) }
                if !draft.bcc.isEmpty { WorkRecordField(title: L10n.t("密送"), value: draft.bcc) }
                WorkRecordField(title: L10n.t("主题"), value: draft.subject)
            }
            if editable {
                WorkDocumentEditor(title: L10n.t("回复正文"), text: editBinding(\.body, clearsHTML: true), height: editorHeight, showsTitle: false).disabled(saving)
            } else {
                Text(draft.body).font(Theme.reader).lineSpacing(7).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
            }
            if !draft.attachments.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.t("随邮件附上")).font(Theme.label).foregroundStyle(Theme.secondary)
                    ForEach(draft.attachments) { attachment in
                        WorkDocumentButton {
                            Task { await model.attachment(attachment) }
                        } label: {
                            HStack(spacing: 12) {
                                Label(attachment.name, systemImage: "paperclip")
                                Text(attachment.size).font(Theme.label).foregroundStyle(Theme.secondary)
                            }
                        }
                        .accessibilityLabel(L10n.t("查看附件：") + attachment.name)
                    }
                }
            }
            if editable && (changed || saving) {
                HStack(spacing: 16) {
                    WorkDocumentButton {
                        saving = true
                        Task { _ = await saveEdits(validate: false); saving = false }
                    } label: {
                        HStack(spacing: 8) {
                            if saving { ProgressView().controlSize(.small) }
                            Text(L10n.t("保存修改"))
                        }
                    }
                    .disabled(!changed || saving || model.partnerBusy)
                }
            }
            if let message { Text(message).font(Theme.label).foregroundStyle(Theme.secondary) }
            draftReceipt
            if let error { Text(error).font(Theme.body).foregroundStyle(Theme.error).textSelection(.enabled) }
            ForEach(decisions) { decision in
                WorkDecisionContent(decision: decision, adoptTitle: model.isDemo ? L10n.t("采用并模拟投递") : L10n.t("采用并继续审阅"), blocked: saving, canAdopt: editable) { adopt in
                    saving = true
                    defer { saving = false }
                    return await saveEdits(validate: adopt)
                }
            }
            WorkSourceLinks(ids: artifact.sourceMailIDs, open: openSource)
        }
        .onChange(of: draft.body) { draft.htmlBody = nil; message = nil }
        .onChange(of: draft.subject) { message = nil }
        .onChange(of: draft.to) { message = nil }
        .onChange(of: initial.updatedAt) {
            if !editable {
                draft = initial; saved = initial
                if model.workingArtifactID == artifact.id { model.workingDraft = nil; model.workingArtifactID = nil }
            } else if !changed { draft = initial; saved = initial }
        }
        .onAppear {
            if editable && isPrimary && model.workingArtifactID != artifact.id { model.activateWorkingDraft(draft, artifactID: artifact.id) }
        }
        .onChange(of: model.workingDraft?.updatedAt) {
            if model.workingArtifactID == artifact.id, let value = model.workingDraft, value.id == draft.id { draft = value; saved = value }
        }
        .onDisappear {
            let local = draft, baseline = saved
            Task { await model.finishWorkingDraft(local, baseline: baseline, artifactID: artifact.id) }
        }
    }

    private var editorHeight: CGFloat {
        min(440, max(240, CGFloat(draft.body.components(separatedBy: .newlines).count) * 24 + 44))
    }
    @ViewBuilder private var draftReceipt: some View {
        if initial.state == "sent" {
            Text(model.accounts.first(where: { $0.id == draft.accountID })?.isDemo == true ? L10n.t("演示投递已完成，等待对方回复。") : L10n.t("邮件已发送。"))
                .font(Theme.body).foregroundStyle(Theme.secondary)
        } else if initial.state == "queued" {
            Text(L10n.t("邮件已加入发件队列。"))
                .font(Theme.body).foregroundStyle(Theme.secondary)
        } else if initial.state == "sending" {
            Text(L10n.t("正在发送这封邮件。"))
                .font(Theme.body).foregroundStyle(Theme.secondary)
        } else if initial.state == "uncertain" {
            Text(initial.error ?? L10n.t("上一次发送的结果需要核对。"))
                .font(Theme.body).foregroundStyle(Theme.error)
        }
    }
    private func saveEdits(validate: Bool) async -> Bool {
        error = nil
        if validate {
            do { try visibleDraft.validate() } catch { self.error = error.localizedDescription; return false }
        }
        guard changed else { return true }
        guard editable else { error = L10n.t("这份邮件当前不能修改。"); return false }
        var snapshot = visibleDraft
        if snapshot.body != saved.body { snapshot.htmlBody = nil }
        do { _ = try await model.persistWorkingDraft(snapshot, artifactID: artifact.id) } catch { self.error = error.localizedDescription; return false }
        guard let value = model.drafts.first(where: { $0.id == draft.id }),
              value.subject == snapshot.subject, value.to == snapshot.to, value.cc == snapshot.cc, value.bcc == snapshot.bcc, value.body == snapshot.body,
              let output = model.agentArtifacts.first(where: { $0.id == artifact.id }), output.content == snapshot.body, output.title == snapshot.subject else {
            error = model.error ?? L10n.t("修改还没有保存，请再试一次。"); return false
        }
        if model.workingArtifactID == artifact.id, let current = model.workingDraft, model.sameDraftContent(current, snapshot) { model.workingDraft = value }
        draft = visibleDraft; saved = value; message = L10n.t("修改已保存")
        return true
    }
}

private struct WorkInlineAgreement: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    let initial: WorkAgreement
    let runID: String
    let decisions: [AgentDecision]
    @EnvironmentObject var model: AppModel
    @State private var agreement: WorkAgreement
    @State private var plan: String
    @State private var boundaries: String
    @State private var saved: WorkAgreement
    @State private var planExpanded = false
    @State private var saving = false
    @State private var message: String?
    @State private var error: String?

    init(initial: WorkAgreement, runID: String, decisions: [AgentDecision]) {
        self.initial = initial; self.runID = runID; self.decisions = decisions
        _agreement = State(initialValue: initial); _saved = State(initialValue: initial)
        _plan = State(initialValue: initial.steps.joined(separator: "\n")); _boundaries = State(initialValue: initial.boundaries.joined(separator: "\n"))
    }
    private var edited: WorkAgreement {
        var value = agreement
        value.steps = lines(plan); value.boundaries = lines(boundaries)
        return value
    }
    private var changed: Bool { !same(edited, saved) }
    private var sourceVersion: [String] {
        [initial.goal, initial.doneWhen, initial.scope, String(initial.boundaries.count)] + initial.boundaries + [String(initial.steps.count)] + initial.steps + [initial.kind, initial.match, String(initial.intervalHours), initial.recipient ?? ""]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.t("我们按这份约定推进")).font(Theme.heading)
            WorkDocumentField(title: L10n.t("要推进的事"), text: $agreement.goal)
            WorkDocumentField(title: L10n.t("何时算完成"), text: $agreement.doneWhen)
            WorkDocumentField(title: L10n.t("可使用的资料和范围"), text: $agreement.scope)
            if let scope = saved.resolvedScope {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.format("实际范围：{0}封当前邮件", "\(model.primaryMails.filter { saved.contains($0) }.count)")).font(Theme.label).foregroundStyle(Theme.secondary)
                    if !scope.subjectTerms.isEmpty { Text(L10n.t("后续主题包含任一项：") + scope.subjectTerms.joined(separator: "、")).font(Theme.label).foregroundStyle(Theme.secondary) }
                    if !scope.senderEmails.isEmpty { Text(L10n.t("同时来自：") + scope.senderEmails.joined(separator: "、")).font(Theme.label).foregroundStyle(Theme.secondary) }
                    if scope.subjectTerms.isEmpty && scope.senderEmails.isEmpty { Text(L10n.t("只使用选定邮件，后续新邮件不自动加入。")).font(Theme.label).foregroundStyle(Theme.secondary) }
                    DisclosureGroup(L10n.t("当前会使用的邮件")) {
                        ForEach(model.primaryMails.filter { saved.contains($0) }) { mail in
                            Text(mail.subject + "（" + mail.from.email + "）").font(Theme.label).foregroundStyle(Theme.secondary).textSelection(.enabled).padding(.vertical, 4)
                        }
                    }.font(Theme.label)
                }
            }
            DisclosureGroup(isExpanded: $planExpanded) {
                VStack(alignment: .leading, spacing: 16) {
                    WorkDocumentEditor(title: L10n.t("拟做这些事，每行一项"), text: $plan, height: 140)
                    WorkDocumentEditor(title: L10n.t("需要守住的边界，每行一项"), text: $boundaries, height: 140)
                }.padding(.top, 12)
            } label: {
                Text(L10n.t("计划与边界")).font(Theme.body).frame(minHeight: 44)
            }
            HStack(spacing: 16) {
                WorkDocumentButton {
                    saving = true
                    Task { _ = await saveAgreement(validate: false); saving = false }
                } label: {
                    HStack(spacing: 8) {
                        if saving { ProgressView().controlSize(.small) }
                        Text(L10n.t("保存约定"))
                    }
                }
                .disabled(!changed || saving || model.partnerBusy)
                if let message { Text(message).font(Theme.label).foregroundStyle(Theme.secondary) }
            }
            if let error { Text(error).font(Theme.body).foregroundStyle(Theme.error).textSelection(.enabled) }
            ForEach(decisions) { decision in
                WorkDecisionContent(decision: decision, adoptTitle: L10n.t("按约定交给 Morrow"), blocked: saving) { adopt in
                    saving = true
                    defer { saving = false }
                    return await saveAgreement(validate: adopt)
                }
            }
            if !decisions.contains(where: { $0.state == "pending" }), model.agentRuns.first(where: { $0.id == runID })?.phase != .completed {
                WorkDocumentButton { Task { await model.finishWork(runID) } } label: { Text(L10n.t("结束这项委托，保留成果")) }
            }
        }
        .disabled(saving)
        .onChange(of: agreement.goal) { message = nil }
        .onChange(of: agreement.doneWhen) { message = nil }
        .onChange(of: agreement.scope) { message = nil }
        .onChange(of: plan) { message = nil }
        .onChange(of: boundaries) { message = nil }
        .onChange(of: sourceVersion) {
            if !changed {
                agreement = initial; saved = initial
                plan = initial.steps.joined(separator: "\n"); boundaries = initial.boundaries.joined(separator: "\n")
                message = nil
            }
        }
        .onDisappear {
            if changed && !saving {
                let value = edited
                Task { await model.updateAgreement(value, runID: runID) }
            }
        }
    }

    private func saveAgreement(validate: Bool) async -> Bool {
        error = nil
        let value = edited
        if validate && [value.goal, value.doneWhen, value.scope].contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            error = L10n.t("补上目标、完成条件和范围，再交给 Morrow。"); return false
        }
        guard changed else { return true }
        let priorError = model.error
        await model.updateAgreement(value, runID: runID)
        if let newError = model.error, newError != priorError { error = newError; return false }
        guard let stored = model.agentRuns.first(where: { $0.id == runID })?.agreement, same(value, stored) else {
            error = model.error ?? L10n.t("约定还没有保存，请再试一次。"); return false
        }
        agreement = stored; saved = stored; message = L10n.t("约定已保存")
        return true
    }
    private func lines(_ text: String) -> [String] { text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    private func same(_ a: WorkAgreement, _ b: WorkAgreement) -> Bool {
        a.goal == b.goal && a.doneWhen == b.doneWhen && a.scope == b.scope && a.steps == b.steps && a.boundaries == b.boundaries && a.kind == b.kind && a.match == b.match && a.intervalHours == b.intervalHours && a.recipient == b.recipient
    }
}

private struct WorkDecisionContent: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    let decision: AgentDecision
    var adoptTitle = L10n.t("采用")
    var blocked = false
    var canAdopt = true
    var beforeAnswer: ((Bool) async -> Bool)?
    @EnvironmentObject var model: AppModel
    @State private var busy = false
    @State private var adopting = false
    @State private var error: String?

    private var current: AgentDecision { model.agentDecisions.first { $0.id == decision.id } ?? decision }
    private var updatingWork: Bool { model.agentRuns.contains { $0.id == decision.runID && [.queued, .reading, .working].contains($0.phase) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if current.state == "pending" {
                Text(current.title).font(Theme.body.weight(.medium))
                if !current.detail.isEmpty { WorkMarkdownContent(text: current.detail).foregroundStyle(Theme.secondary) }
                HStack(spacing: 12) {
                    WorkDocumentButton(primary: true) { answer(true) } label: {
                        HStack(spacing: 8) {
                            if busy && adopting { ProgressView().controlSize(.small).tint(Theme.accentInk) }
                            Text(adoptTitle)
                        }
                    }.disabled(!canAdopt)
                    WorkDocumentButton { answer(false) } label: {
                        HStack(spacing: 8) {
                            if busy && !adopting { ProgressView().controlSize(.small) }
                            Text(L10n.t("暂缓"))
                        }
                    }
                    Spacer(minLength: 0)
                }
                .disabled(busy || blocked || model.partnerBusy || updatingWork)
                if model.isDemo && current.kind != "agreement" {
                    Text(L10n.t("这是演示工作区；采用回复只会模拟投递，不会发送真实邮件。"))
                        .font(Theme.label).foregroundStyle(Theme.secondary)
                }
            } else {
                Text(current.state == "accepted" ? L10n.t("已采用这一步") : current.state == "superseded" ? L10n.t("已有更新的回复草稿") : L10n.t("这一步已暂缓"))
                    .font(Theme.body).foregroundStyle(Theme.secondary)
            }
            if let error { Text(error).font(Theme.body).foregroundStyle(Theme.error).textSelection(.enabled) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(current.title)
    }
    private func answer(_ adopt: Bool) {
        guard !busy, current.state == "pending" else { return }
        busy = true; adopting = adopt; error = nil
        Task {
            if let beforeAnswer, !(await beforeAnswer(adopt)) { busy = false; return }
            guard let value = model.agentDecisions.first(where: { $0.id == decision.id }), value.state == "pending" else { busy = false; return }
            let priorError = model.error
            await model.answerDecision(value, adopt: adopt)
            if let newError = model.error, newError != priorError { error = newError }
            else if model.agentDecisions.first(where: { $0.id == decision.id })?.state == "pending" { error = model.error ?? L10n.t("决定还没有完成，请再试一次。") }
            busy = false
        }
    }
}

private struct WorkSourceLinks: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    let ids: [String]
    let open: (MailMessage) -> Void
    @EnvironmentObject var model: AppModel
    private var uniqueIDs: [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
    var body: some View {
        if !ids.isEmpty {
            DisclosureGroup(L10n.format("依据邮件（{0}）", "\(uniqueIDs.count)")) { VStack(alignment: .leading, spacing: 4) {
                ForEach(uniqueIDs, id: \.self) { id in
                    if let mail = model.mails.first(where: { $0.id == id }) {
                        WorkDocumentButton { open(mail) } label: {
                            Label(mail.subject.isEmpty ? L10n.t("打开无主题原邮件") : mail.subject, systemImage: "envelope.open")
                                .lineLimit(2).multilineTextAlignment(.leading)
                        }
                        .accessibilityLabel(L10n.t("查看原邮件：") + mail.subject)
                    } else {
                        Text(L10n.t("一封引用的原邮件暂不可用。"))
                            .font(Theme.label).foregroundStyle(Theme.secondary).padding(.vertical, 12)
                    }
                }
            } }.font(Theme.label)
        }
    }
}

private struct WorkSourceReader: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    let mail: MailMessage
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        ReaderView(mail: model.selected ?? mail)
            .id((model.selected ?? mail).id)
            .frame(width: 760, height: 760)
            .onAppear { model.selectedID = mail.id }
            .onChange(of: model.selectedID) { if model.selectedID == nil { dismiss() } }
            .onDisappear { model.selectedID = nil }
    }
}

struct WorkMarkdownContent: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    let text: String
    private var blocks: [String] {
        var result: [String] = []; var paragraph: [String] = []
        for line in text.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !paragraph.isEmpty { result.append(paragraph.joined(separator: "\n")); paragraph = [] }
            } else if headingText(line) != nil {
                if !paragraph.isEmpty { result.append(paragraph.joined(separator: "\n")); paragraph = [] }
                result.append(line)
            } else { paragraph.append(line) }
        }
        if !paragraph.isEmpty { result.append(paragraph.joined(separator: "\n")) }
        return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { item in
                if let title = headingText(item.element) {
                    Text(attributed(title)).font(Theme.heading).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if tableRows(item.element).count > 1 {
                    let rows = tableRows(item.element)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { row in
                            HStack(alignment: .top, spacing: 20) {
                                ForEach(Array(row.element.enumerated()), id: \.offset) { cell in
                                    Text(attributed(cell.element))
                                        .font(row.offset == 0 ? Theme.body.weight(.medium) : Theme.reader)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.padding(.vertical, 12)
                            WorkDocumentRule()
                        }
                    }
                } else {
                    Text(attributed(listText(item.element))).font(Theme.reader).lineSpacing(7).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
    private func listText(_ value: String) -> String {
        value.components(separatedBy: .newlines).map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("* ") || trimmed.hasPrefix("- ") { return "• " + String(trimmed.dropFirst(2)) }
            return line
        }.joined(separator: "\n")
    }
    private func attributed(_ value: String) -> AttributedString {
        (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value)
    }
    private func headingText(_ line: String) -> String? {
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes > 0 && hashes <= 6, line.dropFirst(hashes).first == " " else { return nil }
        return String(line.dropFirst(hashes + 1))
    }
    private func tableRows(_ block: String) -> [[String]] {
        let lines = block.components(separatedBy: .newlines)
        guard lines.count > 1, lines[0].contains("|"), lines[1].contains("-"), lines[1].allSatisfy({ "|-: \t".contains($0) }) else { return [] }
        return lines.enumerated().filter { $0.offset != 1 }.map { item in
            var cells = item.element.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            if cells.first == "" { cells.removeFirst() }
            if cells.last == "" { cells.removeLast() }
            return cells
        }
    }
}

private struct WorkDraftField: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    let title: String
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(Theme.label).foregroundStyle(Theme.muted).frame(width: 48, alignment: .leading)
            TextField("", text: $text, axis: .vertical).textFieldStyle(.plain).font(Theme.body).lineLimit(1...2).focused($focused)
                .padding(.vertical, 6).padding(.horizontal, 4)
                .overlay(alignment: .bottom) { Rectangle().fill(focused ? Theme.focus : Theme.fieldEdge).frame(height: focused ? 2 : 1) }
                .accessibilityLabel(title)
        }.frame(minHeight: 32)
    }
}

private struct WorkDocumentField: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    let title: String
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(Theme.label).foregroundStyle(Theme.secondary)
            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(Theme.body).lineLimit(1...4).focused($focused)
                .padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 44)
                .background(Theme.sheet, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay { RoundedRectangle(cornerRadius: Theme.radius).stroke(focused ? Theme.focus : Theme.fieldEdge, lineWidth: 1) }
                .accessibilityLabel(title)
        }
    }
}

private struct WorkDocumentEditor: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    let title: String
    @Binding var text: String
    let height: CGFloat
    var showsTitle = true
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if showsTitle { Text(title).font(Theme.label).foregroundStyle(Theme.secondary) }
            TextEditor(text: $text).font(Theme.reader).lineSpacing(6).scrollContentBackground(.hidden)
                .focused($focused).padding(12).frame(height: height)
                .background(Theme.sheet, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay { RoundedRectangle(cornerRadius: Theme.radius).stroke(focused ? Theme.focus : Theme.fieldEdge, lineWidth: 1) }
                .accessibilityLabel(title)
        }
    }
}

private struct WorkDocumentButton<Content: View>: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    var primary = false
    var action: () -> Void
    @ViewBuilder var label: () -> Content
    @FocusState private var focused: Bool
    @State private var hovered = false
    var body: some View {
        Button(action: action, label: label)
            .buttonStyle(WorkDocumentButtonStyle(primary: primary, focused: focused, hovered: hovered))
            .focused($focused).onHover { hovered = $0 }
    }
}

private struct WorkDocumentButtonStyle: ButtonStyle {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    let primary: Bool
    let focused: Bool
    let hovered: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let radius = primary ? Theme.controlRadius : Theme.radius
        let background = primary ? Theme.ink.opacity(configuration.isPressed ? 0.85 : (hovered ? 0.95 : 1)) : (configuration.isPressed ? Theme.selected : Theme.sheet)
        return configuration.label.font(Theme.body.weight(primary ? .medium : .regular))
            .foregroundStyle(primary ? Theme.paper : Theme.ink)
            .padding(.horizontal, 14).frame(minWidth: 44, minHeight: 48)
            .background(background, in: RoundedRectangle(cornerRadius: radius))
            .overlay { RoundedRectangle(cornerRadius: radius).stroke(focused ? Theme.focus : primary ? Theme.clear : Theme.rule, lineWidth: 1) }
            .shadow(color: Theme.shadow.opacity(hovered ? 0.10 : 0.06), radius: 2, x: 2, y: 2)
            .contentShape(Rectangle()).opacity(enabled ? 1 : 0.55)
    }
}

private struct WorkDocumentRule: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    var body: some View { Rectangle().fill(Theme.rule).frame(height: 1).accessibilityHidden(true) }
}

private struct WorkRecordField: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    var title: String
    var value: String
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title).font(Theme.label).foregroundStyle(Theme.secondary).frame(width: 72, alignment: .leading)
            Text(value).font(Theme.body).foregroundStyle(Theme.ink).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
