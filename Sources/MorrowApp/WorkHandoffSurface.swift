import SwiftUI
import MorrowCore

struct WorkHandoffSurface: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    @State private var instruction = ""
    @State private var formingNewWork = false
    @State private var submitting = false
    @State private var formError: String?
    @FocusState private var focused: Bool

    private var runs: [AgentRun] { model.agentRuns.sorted { $0.updatedAt > $1.updatedAt } }
    private var attention: [AgentRun] { runs.filter { $0.phase == .waitingUser || $0.phase == .failed } }
    private var ongoing: [AgentRun] { runs.filter { ![.completed, .paused, .waitingUser, .failed].contains($0.phase) } }
    private var recent: [AgentArtifact] { model.agentArtifacts.sorted { $0.createdAt > $1.createdAt } }
    private var busy: Bool { submitting || model.partnerBusy || model.delegationBusy }

    var body: some View {
        Group {
            if let run = model.selectedRun { WorkDocumentView(run: run) }
            else {
                VStack(spacing: 0) {
                    header
                    Divider().overlay(Theme.rule)
                    if !model.ready {
                        ProgressView(L10n.t("正在打开工作区…")).font(Theme.label).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 24) {
                                if runs.isEmpty && recent.isEmpty { emptyState }
                                if !attention.isEmpty { runSection("需要你处理", runs: attention) }
                                if !ongoing.isEmpty { runSection("进行中的工作", runs: ongoing) }
                                if !recent.isEmpty { resultsSection }
                                if attention.isEmpty && ongoing.isEmpty && !runs.isEmpty {
                                    HStack(spacing: 12) {
                                        Label(L10n.t("当前没有待处理的工作"), systemImage: "checkmark.circle").font(Theme.label).foregroundStyle(Theme.secondary)
                                        Spacer()
                                        Button(L10n.t("查看工作记录")) { model.openWorkspace(.history) }.buttonStyle(CompactButtonStyle())
                                    }
                                }
                            }.padding(24).frame(maxWidth: 980, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if formingNewWork { instructionSurface }
                }
            }
        }.background(Theme.paper)
            .onAppear { model.visibleRunID = model.selectedRun?.id }
            .onChange(of: model.selectedRunID) { model.visibleRunID = model.selectedRun?.id }
    }
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { title; Spacer(minLength: 12); headerActions }
            VStack(alignment: .leading, spacing: 12) { title; headerActions }
        }.padding(24)
    }
    private var title: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.t("工作")).font(Theme.title)
            Text(L10n.format("{0}项待处理，{1}项正在进行", String(attention.count), String(ongoing.count))).font(Theme.label).foregroundStyle(Theme.secondary)
        }
    }
    private var headerActions: some View {
        HStack(spacing: 8) {
            Button(L10n.t("工作记录")) { model.openWorkspace(.history) }.buttonStyle(CompactButtonStyle())
            Button { formingNewWork = true; focused = true } label: { Label(L10n.t("新建工作"), systemImage: "plus") }.buttonStyle(PrimaryButtonStyle()).disabled(busy).accessibilityIdentifier("work.create")
        }.fixedSize(horizontal: true, vertical: false)
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("还没有工作")).font(Theme.heading)
            Text(L10n.t("从一封邮件开始，或新建一项跟进、整理或回复工作。")).font(Theme.body).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { emptyActions }
                VStack(alignment: .leading, spacing: 8) { emptyActions }
            }
        }.padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("work.empty")
    }
    @ViewBuilder private var emptyActions: some View {
        Button(L10n.t("打开邮件")) { model.openWorkspace(.mail) }.buttonStyle(CompactButtonStyle())
        if model.accounts.isEmpty { Button(L10n.t("连接邮箱")) { model.showAccount = true }.buttonStyle(CompactButtonStyle()) }
        if model.isDemo || model.accounts.isEmpty { Button(L10n.t("打开演示场景")) { Task { await model.loadDemo(); await model.installAgentDemoScenarios() } }.buttonStyle(CompactButtonStyle()) }
    }
    private func runSection(_ title: String, runs: [AgentRun]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(L10n.t(title)).font(Theme.heading); Text(String(runs.count)).font(Theme.label).foregroundStyle(Theme.muted); Spacer() }
            ForEach(runs.prefix(8)) { run in
                Button { model.selectRun(run) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(run.title).font(Theme.body.weight(.medium)).lineLimit(2)
                            Spacer(minLength: 8)
                            Text(L10n.t(run.phase.label)).font(Theme.label).foregroundStyle(run.phase == .failed ? Theme.error : run.phase == .waitingUser ? Theme.accent2 : Theme.secondary)
                        }
                        if !run.summary.isEmpty { Text(run.summary).font(Theme.label).foregroundStyle(Theme.secondary).lineLimit(2) }
                        Text(run.updatedAt.uiFormatted(date: .abbreviated, time: .shortened)).font(Theme.small).foregroundStyle(Theme.muted)
                    }.padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(ListRowButtonStyle()).accessibilityIdentifier("work.open")
                Divider().overlay(Theme.rule)
            }
            if runs.count > 8 { Button(L10n.t("查看全部工作")) { model.openWorkspace(.history) }.buttonStyle(CompactButtonStyle()) }
        }
    }
    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(L10n.t("最近的成果")).font(Theme.heading); Spacer(); Button(L10n.t("查看全部成果")) { model.openWorkspace(.library) }.buttonStyle(CompactButtonStyle()) }
            ForEach(recent.prefix(4)) { artifact in
                Button {
                    if artifact.isBrief { model.openBrief(artifact) }
                    else if let run = model.agentRuns.first(where: { $0.id == artifact.runID }) { model.selectRun(run) }
                    else { model.openWorkspace(.library) }
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: artifact.kind == .draft ? "doc.text" : "doc.text.magnifyingglass").foregroundStyle(Theme.secondary).frame(width: 20)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(artifact.title).font(Theme.body.weight(.medium)).lineLimit(2)
                            Text(artifact.createdAt.uiFormatted(date: .abbreviated, time: .shortened)).font(Theme.small).foregroundStyle(Theme.muted)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(Theme.small).foregroundStyle(Theme.muted)
                    }.padding(.vertical, 12)
                }.buttonStyle(ListRowButtonStyle())
                Divider().overlay(Theme.rule)
            }
        }
    }
    private var instructionSurface: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().overlay(Theme.rule)
            HStack { Text(L10n.t("新建工作")).font(Theme.heading); Spacer(); Button(L10n.t("取消")) { formingNewWork = false; formError = nil }.buttonStyle(CompactButtonStyle()).disabled(submitting) }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $instruction).font(Theme.reader).scrollContentBackground(.hidden).focused($focused).padding(8).frame(height: 80).accessibilityLabel(L10n.t("工作要求"))
                if instruction.isEmpty { Text(L10n.t("说明需要完成的事，例如核对合同条款，或跟进客户回复。")).font(Theme.body).foregroundStyle(Theme.muted).padding(12).allowsHitTesting(false).accessibilityHidden(true) }
            }.background(Theme.sheet).overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).stroke(focused ? Theme.focus : Theme.fieldEdge, lineWidth: 1))
            if let formError { Text(formError).font(Theme.label).foregroundStyle(Theme.error).textSelection(.enabled) }
            HStack {
                Button { model.importFiles() } label: { Label(L10n.t("带上资料"), systemImage: "paperclip") }.buttonStyle(CompactButtonStyle()).disabled(submitting)
                Spacer()
                Button(submitting ? L10n.t("正在准备工作…") : L10n.t("形成委托")) { submit() }.buttonStyle(PrimaryButtonStyle()).disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy).keyboardShortcut(.return, modifiers: .command).accessibilityIdentifier("work.submit")
            }
        }.padding(.horizontal, 24).padding(.bottom, 24)
    }
    private func submit() {
        let text = instruction; submitting = true; formError = nil; model.error = nil
        Task {
            await model.proposeWork(text)
            submitting = false
            if let error = model.error { formError = error; model.error = nil }
            else if instruction == text { instruction = ""; formingNewWork = false }
        }
    }
}
