// Native inspector for outputs, original sources and pending decisions.
import SwiftUI
import MorrowCore

struct AgentInspectorView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    @State private var answeringDecisionID: String?
    @State private var answeringAdoption = false
    @State private var decisionError: String?
    @State private var decisionReceipt: String?

    var body: some View {
        VStack(spacing: 0) {
            tabs
            InspectorRule()
            if let run = model.selectedRun {
                runContext(run)
                InspectorRule()
            }
            content
        }
        .font(Theme.body)
        .foregroundStyle(Theme.ink)
        .background(Theme.sheet)
        .frame(minWidth: 300, idealWidth: 360, maxWidth: 420, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("工作详情"))
        .onChange(of: model.selectedRunID) {
            decisionError = nil
            decisionReceipt = nil
        }
    }

    private var tabs: some View {
        Picker(L10n.t("工作详情"), selection: $model.inspectorPage) {
            ForEach(InspectorPage.allCases) { page in Text(L10n.t(page.rawValue)).tag(page) }
        }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func runContext(_ run: AgentRun) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(run.title)
                    .font(Theme.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(L10n.t(run.phase.label))
                    .font(Theme.label)
                    .foregroundStyle(run.phase == .failed ? Theme.error : Theme.secondary)
                    .fixedSize()
            }
            if !run.summary.isEmpty {
                Text(run.summary)
                    .font(Theme.label)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
                    .help(run.summary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        if !model.ready {
            InspectorLoadingState(title: L10n.t("正在打开工作详情"), detail: L10n.t("产出和引用邮件会在这里展开。"))
        } else if let run = model.selectedRun {
            switch model.inspectorPage {
            case .artifacts: artifacts(run)
            case .evidence: evidence(run)
            case .decisions: decisions(run)
            }
        } else {
            InspectorState(icon: "doc.text.magnifyingglass", title: L10n.t("选择一项工作"), detail: L10n.t("查看伙伴的产出、原邮件，以及需要你决定的下一步。"), actionTitle: L10n.t("查看工作台")) {
                model.workspacePage = .desk
            }
        }
    }

    @ViewBuilder private func artifacts(_ run: AgentRun) -> some View {
        if model.selectedArtifacts.isEmpty {
            if isWorking(run) {
                InspectorLoadingState(title: L10n.t("正在准备产出"), detail: L10n.t("完成的草稿和简报会保存在这里。"))
            } else if run.phase == .failed {
                failureState(run)
            } else {
                InspectorState(icon: "doc.text", title: L10n.t("这项工作还没有产出"), detail: L10n.t("草稿、简报和已完成的整理会保存在这里。"), actionTitle: L10n.t("查看工作台")) {
                    model.workspacePage = .desk
                }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.selectedArtifacts) { artifact in
                        artifactContent(artifact)
                        if artifact.id != model.selectedArtifacts.last?.id {
                            InspectorRule().padding(.vertical, 24)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func artifactContent(_ artifact: AgentArtifact) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text(artifactLabel(artifact.kind))
                    Spacer()
                    Text(artifact.createdAt.uiFormatted(date: .abbreviated, time: .shortened))
                        .monospacedDigit()
                }
                .font(Theme.label)
                .foregroundStyle(Theme.secondary)
                Text(artifact.title)
                    .font(Theme.heading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if artifact.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(L10n.t("这份产出没有正文。"))
                    .font(Theme.body)
                    .foregroundStyle(Theme.secondary)
            } else {
                Text(artifact.content)
                    .font(Theme.reader)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let draftID = artifact.linkedDraftID {
                if let draft = model.drafts.first(where: { $0.id == draftID }) {
                    InspectorButton(kind: .quiet) {
                        model.openDraft(draft)
                    } label: {
                        Label(L10n.t(draft.state == "sent" ? "查看已发送" : "打开草稿"), systemImage: draft.state == "sent" ? "paperplane" : "square.and.pencil")
                    }
                    .accessibilityLabel(L10n.t("打开草稿：") + artifact.title)
                } else {
                    Text(L10n.t("关联草稿暂不可用。产出正文已保留。"))
                        .font(Theme.label)
                        .foregroundStyle(Theme.secondary)
                }
            }
            MailReferenceList(ids: artifact.sourceMailIDs, title: L10n.t("引用邮件"), collapsible: false, showsDetails: true) { mail in
                model.selectedID = mail.id; model.inspectorPage = .evidence
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(artifactLabel(artifact.kind) + "：" + artifact.title)
    }

    @ViewBuilder private func evidence(_ run: AgentRun) -> some View {
        let sourceIDs = Set(run.sourceMailIDs + model.selectedArtifacts.flatMap(\.sourceMailIDs))
        if let mail = model.selected, sourceIDs.contains(mail.id) {
            ReaderView(mail: mail)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if run.sourceMailIDs.isEmpty {
            if isWorking(run) {
                InspectorLoadingState(title: L10n.t("正在核对原邮件"), detail: L10n.t("本轮工作引用的邮件会出现在这里。"))
            } else if run.phase == .failed {
                failureState(run)
            } else {
                InspectorState(icon: "envelope.open", title: L10n.t("这项工作还没有引用邮件"), detail: L10n.t("伙伴读取邮件后，你可以在这里核对原文。"), actionTitle: L10n.t("查看产出")) {
                    model.inspectorPage = .artifacts
                }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text(L10n.t("本轮引用的原邮件"))
                        .font(Theme.label)
                        .foregroundStyle(Theme.secondary)
                        .padding(.bottom, 12)
                    MailReferenceList(ids: run.sourceMailIDs, collapsible: false, showsDetails: true) { mail in
                        model.selectedID = mail.id; model.inspectorPage = .evidence
                    }
                    if unavailableSources(run) && !model.realAccounts.isEmpty {
                        InspectorButton(kind: .quiet) {
                            Task { await model.sync(userInitiated: true) }
                        } label: {
                            HStack(spacing: 8) {
                                if model.syncBusy {
                                    ProgressView().controlSize(.small)
                                    Text(L10n.t("正在同步"))
                                } else {
                                    Label(L10n.t("同步邮箱"), systemImage: "arrow.clockwise")
                                }
                            }
                        }
                        .disabled(model.syncBusy)
                        .padding(.top, 20)
                    }
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder private func decisions(_ run: AgentRun) -> some View {
        let pending = runDecisions(run)
        if pending.isEmpty {
            if let decisionError {
                InspectorState(icon: "exclamationmark.triangle", title: L10n.t("决定暂未完成"), detail: decisionError, isError: true, actionTitle: L10n.t("查看产出")) {
                    model.inspectorPage = .artifacts
                }
            } else if isWorking(run) {
                InspectorLoadingState(title: L10n.t("正在准备下一步"), detail: L10n.t("需要你确认的事项会在这里列出。"))
            } else if run.phase == .failed {
                failureState(run)
            } else {
                InspectorState(icon: decisionReceipt == nil ? "checklist" : "checkmark", title: decisionReceipt ?? L10n.t("暂时没有需要你决定的事"), detail: L10n.t("查看已有产出，或继续给伙伴补充要求。"), actionTitle: L10n.t("查看产出")) {
                    model.inspectorPage = .artifacts
                }
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let decisionError {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(L10n.t("决定暂未完成"), systemImage: "exclamationmark.triangle")
                                .font(Theme.body.weight(.medium))
                                .foregroundStyle(Theme.error)
                            Text(decisionError)
                                .font(Theme.label)
                                .foregroundStyle(Theme.secondary)
                                .textSelection(.enabled)
                        }
                        .padding(.bottom, 24)
                    }
                    ForEach(pending) { decision in
                        decisionContent(decision)
                        if decision.id != pending.last?.id {
                            InspectorRule().padding(.vertical, 24)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private func decisionContent(_ decision: AgentDecision) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(decision.title)
                .font(Theme.heading)
                .fixedSize(horizontal: false, vertical: true)
            Text(decision.detail)
                .font(Theme.reader)
                .foregroundStyle(Theme.secondary)
                .lineSpacing(4)
                .textSelection(.enabled)
            if let artifactID = decision.artifactID,
               let artifact = model.agentArtifacts.first(where: { $0.id == artifactID }) {
                InspectorButton(kind: .quiet) {
                    model.inspectorPage = .artifacts
                } label: {
                    Label(L10n.t("查看相关产出"), systemImage: "doc.text")
                }
                .accessibilityLabel(L10n.t("查看相关产出：") + artifact.title)
            }
            HStack(spacing: 10) {
                InspectorButton(kind: .primary) {
                    answer(decision, adopt: true)
                } label: {
                    HStack(spacing: 8) {
                        if answeringDecisionID == decision.id && answeringAdoption {
                            ProgressView().controlSize(.small).tint(Theme.accentInk)
                        }
                        Text(L10n.t("采用"))
                    }
                }
                .accessibilityLabel(L10n.t("采用：") + decision.title)
                InspectorButton(kind: .quiet) {
                    answer(decision, adopt: false)
                } label: {
                    HStack(spacing: 8) {
                        if answeringDecisionID == decision.id && !answeringAdoption {
                            ProgressView().controlSize(.small).tint(Theme.secondary)
                        }
                        Text(L10n.t("暂缓"))
                    }
                }
                .accessibilityLabel(L10n.t("暂缓：") + decision.title)
                Spacer(minLength: 0)
            }
            .disabled(answeringDecisionID != nil)
            if model.isDemo {
                Text(L10n.t("演示工作区会模拟处理这项决定。"))
                    .font(Theme.label)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func answer(_ decision: AgentDecision, adopt: Bool) {
        guard answeringDecisionID == nil else { return }
        answeringDecisionID = decision.id
        answeringAdoption = adopt
        decisionError = nil
        decisionReceipt = nil
        let priorError = model.error
        Task {
            await model.answerDecision(decision, adopt: adopt)
            if model.selectedRunID == decision.runID {
                if let error = model.error, error != priorError {
                    decisionError = error
                } else if let updated = model.agentDecisions.first(where: { $0.id == decision.id }), updated.state != "pending" {
                    decisionReceipt = adopt ? L10n.t("已记录你的采用决定") : L10n.t("这一步已暂缓")
                }
            }
            answeringDecisionID = nil
        }
    }

    private func failureState(_ run: AgentRun) -> some View {
        InspectorState(icon: "exclamationmark.triangle", title: L10n.t("这次工作还没有完成"), detail: run.summary.isEmpty ? L10n.t("回到工作台补充要求，再继续这项工作。") : run.summary, isError: true, actionTitle: L10n.t("返回工作台")) {
            model.workspacePage = .desk
        }
    }

    private func isWorking(_ run: AgentRun) -> Bool {
        run.phase == .reading || run.phase == .working || model.executingRunIDs.contains(run.id)
    }
    private func runDecisions(_ run: AgentRun) -> [AgentDecision] {
        model.agentDecisions.filter { $0.runID == run.id && $0.state == "pending" }.sorted { $0.createdAt < $1.createdAt }
    }
    private func unavailableSources(_ run: AgentRun) -> Bool {
        run.sourceMailIDs.contains { model.mailByID($0) == nil }
    }
    private func artifactLabel(_ kind: AgentArtifactKind) -> String {
        switch kind {
        case .draft: return L10n.t("回复草稿")
        case .report: return L10n.t("工作简报")
        case .brief: return L10n.t("摘要")
        case .action: return L10n.t("处理记录")
        }
    }
}

private struct InspectorRule: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    var body: some View {
        Rectangle().fill(Theme.rule).frame(height: 1).accessibilityHidden(true)
    }
}

private enum InspectorButtonKind: Equatable { case primary, quiet, tab, row }

private struct InspectorButton<Content: View>: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    var kind: InspectorButtonKind = .quiet
    var selected = false
    var expands = false
    var action: () -> Void
    @ViewBuilder var label: () -> Content
    @FocusState private var focused: Bool
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            label()
        }
        .buttonStyle(InspectorButtonAppearance(kind: kind, selected: selected, expands: expands, focused: focused, hovered: hovered))
        .focused($focused)
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct InspectorButtonAppearance: ButtonStyle {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    var kind: InspectorButtonKind
    var selected: Bool
    var expands: Bool
    var focused: Bool
    var hovered: Bool
    @Environment(\.isEnabled) private var enabled

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if kind == .primary {
            InteractiveControlBody(label: configuration.label, pressed: configuration.isPressed, kind: .primary)
        } else if kind == .quiet {
            InteractiveControlBody(label: configuration.label, pressed: configuration.isPressed, kind: .quiet)
        } else {
            configuration.label.font(Theme.label).foregroundStyle(foreground)
                .padding(.horizontal, kind == .row ? 8 : 12)
                .frame(maxWidth: expands ? .infinity : nil, minHeight: 30, alignment: kind == .row ? .leading : .center)
                .background(background(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(focused ? Theme.focus : Theme.clear, lineWidth: 1.5))
                .contentShape(Rectangle()).opacity(enabled ? 1 : 0.55)
        }
    }

    private var foreground: Color {
        if kind == .primary { return Theme.accentInk }
        if kind == .tab { return selected ? Theme.accent2 : Theme.secondary }
        return Theme.ink
    }
    private func background(pressed: Bool) -> Color {
        if kind == .primary { return Theme.accent.opacity(pressed ? 0.8 : (hovered && enabled ? 0.9 : 1)) }
        if pressed { return Theme.sidebar }
        if selected && kind == .row { return Theme.selected }
        if selected && kind == .tab { return Theme.paper }
        return hovered && enabled ? Theme.sidebar : Theme.clear
    }
}

private struct InspectorState: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    var icon: String
    var title: String
    var detail: String
    var isError = false
    var actionTitle: String
    var action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: icon)
                .font(Theme.emptyIcon)
                .foregroundStyle(isError ? Theme.error : Theme.secondary)
                .accessibilityHidden(true)
            Text(title).font(Theme.heading)
            Text(detail)
                .font(Theme.body)
                .foregroundStyle(Theme.secondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            InspectorButton(kind: .quiet, action: action) {
                Text(actionTitle)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct InspectorLoadingState: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    var title: String
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(Theme.accent2)
                Text(title).font(Theme.body.weight(.medium))
            }
            Text(detail)
                .font(Theme.label)
                .foregroundStyle(Theme.secondary)
                .lineSpacing(4)
            VStack(alignment: .leading, spacing: 12) {
                Rectangle().fill(Theme.rule).frame(width: 170, height: 16)
                Rectangle().fill(Theme.rule).frame(height: 12)
                Rectangle().fill(Theme.rule).frame(height: 12)
                Rectangle().fill(Theme.rule).frame(width: 220, height: 12)
            }
            .padding(.top, 12)
            .accessibilityHidden(true)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title + "。" + detail)
    }
}
