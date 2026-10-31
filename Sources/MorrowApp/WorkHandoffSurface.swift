import SwiftUI
import MorrowCore

struct WorkHandoffSurface: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    @State private var instruction = ""
    @State private var handoffID: String?
    @State private var formingNewWork = false
    @FocusState private var focused: Bool
    private var handoffs: [AgentRun] {
        model.agentRuns.sorted {
            if ($0.phase == .waitingUser) != ($1.phase == .waitingUser) { return $0.phase == .waitingUser }; return $0.updatedAt > $1.updatedAt
        }
    }
    private var foreground: AgentRun? { handoffs.first { $0.id == handoffID } ?? handoffs.first }
    private var displayedRun: AgentRun? { model.selectedRun ?? foreground }
    private var newIntent: Bool { formingNewWork || displayedRun == nil }
    var body: some View {
        VStack(spacing: 0) {
            if let run = model.selectedRun { WorkDocumentView(run: run) }
            else if let run = foreground { WorkDocumentView(run: run, isHandoff: true) }
            else { EmptyRegion(icon: "doc.text", title: L10n.t("把一件事交给我"), detail: L10n.t("告诉我目的，或从一封邮件与附件开始。我会把准备好的成果带回来。"), action: model.accounts.isEmpty ? L10n.t("打开演示场景") : nil, perform: { Task { await model.loadDemo(); await model.installAgentDemoScenarios() } }) }

        }.background(Theme.paper)
            .onAppear { if handoffID == nil { handoffID = handoffs.first?.id }; model.visibleRunID = displayedRun?.id }
            .onChange(of: displayedRun?.id) { model.visibleRunID = displayedRun?.id }
            .onChange(of: model.agentRuns.map(\.id)) { if handoffID == nil { handoffID = handoffs.first?.id } }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MorrowFocusMission"))) { _ in formingNewWork = true; focused = true }
    }
    private var introduction: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.agentArtifacts.isEmpty ? L10n.t("你交代目的，我带回成果。") : L10n.t("这些已经准备好了。")).font(Theme.title)
            Text(summary).font(Theme.reader).foregroundStyle(Theme.secondary).lineSpacing(5)
            if model.isDemo { Text(L10n.t("所有邮件与投递均为演示场景。")).font(Theme.label).foregroundStyle(Theme.muted) }
        }
    }
    private var summary: String {
        let decisions = model.pendingDecisions.count; let ready = model.agentArtifacts.count
        if ready > 0 { return L10n.format("我已准备{0}份成果，{1}项需要你判断。你可以直接采用、修改，或告诉我继续往哪个方向做。", "\(ready)", "\(decisions)") }
        return L10n.t("跟进客户、核对条款、准备回复或整理材料，都可以交给我。过程和依据随时可查。")
    }
    private var instructionSurface: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(Theme.rule).frame(height: 1)
            HStack { Text(newIntent ? L10n.t("交给我一件新工作") : L10n.t("在这份工作里继续")).font(Theme.label).foregroundStyle(Theme.muted); Spacer(); if formingNewWork && displayedRun != nil { Button(L10n.t("回到这份工作")) { formingNewWork = false }.buttonStyle(.plain).font(Theme.label) }; if model.partnerBusy { ProgressView().controlSize(.small); Text(L10n.t("正在处理")).font(Theme.label).foregroundStyle(Theme.muted) } }
            HStack(alignment: .bottom, spacing: 14) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $instruction).font(Theme.reader).scrollContentBackground(.hidden).focused($focused).padding(8).frame(height: 62).accessibilityLabel(L10n.t("继续工作或形成新委托"))
                    if instruction.isEmpty { Text(newIntent ? L10n.t("例如：把这项续约推进到客户确认；先比较合同，再备好回复。") : L10n.t("改写这段、解释依据，或继续下一步。")).font(Theme.body).foregroundStyle(Theme.muted).padding(14).allowsHitTesting(false).accessibilityHidden(true) }
                }.background(Theme.sheet).overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(focused ? Theme.focus : Theme.fieldEdge, lineWidth: 1))
                Button(newIntent ? L10n.t("形成委托") : L10n.t("继续")) { let text = instruction; let creating = newIntent; let currentID = displayedRun?.id; Task { if creating { await model.proposeWork(text) } else { model.selectedRunID = currentID; await model.workspaceCommand(text) }; if model.error == nil && instruction == text { instruction = ""; formingNewWork = false } } }.buttonStyle(PrimaryButtonStyle()).disabled(instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.partnerBusy || model.delegationBusy).keyboardShortcut(.return, modifiers: .command)
            }
            HStack { Button { model.importFiles() } label: { Label(L10n.t("带上资料"), systemImage: "paperclip") }.buttonStyle(.plain).font(Theme.label).foregroundStyle(Theme.secondary); Spacer(); Text(L10n.t("邮件、附件和已有上下文一起工作")).font(Theme.small).foregroundStyle(Theme.muted) }
        }.padding(.horizontal, 32).padding(.bottom, 18).frame(maxWidth: 1180).frame(maxWidth: .infinity)
    }
}

private struct HandoffCard: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    let run: AgentRun
    private var artifact: AgentArtifact? { model.agentArtifacts.filter { $0.runID == run.id }.max { $0.createdAt < $1.createdAt } }
    private var decision: AgentDecision? { model.pendingDecisions.first { $0.runID == run.id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) { Text(run.title).font(Theme.heading); Spacer(); AgentPhaseLabel(phase: run.phase) }
            Text(agentMessage).font(Theme.reader).foregroundStyle(Theme.secondary).lineSpacing(5)
            if let artifact {
                VStack(alignment: .leading, spacing: 12) { Text(artifact.title).font(Theme.body.weight(.medium)); Text(preview(artifact.content)).font(Theme.reader).foregroundStyle(Theme.secondary).lineSpacing(5).lineLimit(6).textSelection(.enabled) }.padding(.vertical, 16).overlay(alignment: .top) { Rectangle().fill(Theme.rule).frame(height: 1) }.overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
            }
            if let decision { HStack(alignment: .top, spacing: 12) { Image(systemName: "hand.raised").foregroundStyle(Theme.accent2).accessibilityHidden(true); VStack(alignment: .leading, spacing: 8) { Text(decision.title).font(Theme.body.weight(.medium)); Text(decision.detail).font(Theme.body).foregroundStyle(Theme.muted) } } }
            HStack(spacing: 16) { Button(decision == nil ? L10n.t("打开共同工作稿") : L10n.t("查看并决定")) { model.selectRun(run) }.buttonStyle(QuietButtonStyle()); if run.phase == .waitingReply { Text(L10n.t("有后续邮件时，我会接着推进。")).font(Theme.label).foregroundStyle(Theme.muted) }; Spacer(); Button(L10n.format("{0}封依据", "\(run.sourceMailIDs.count)")) { model.selectRun(run) }.buttonStyle(.plain).font(Theme.label).foregroundStyle(Theme.muted) }
        }.padding(26).frame(maxWidth: .infinity, alignment: .leading).background(Theme.sheet)
    }
    private var agentMessage: String {
        if run.phase == .waitingUser { return L10n.t("我把这一步需要的内容准备好了。还需要你确认下面的选择；决定之后，我会继续这件事。") }
        if run.phase == .waitingReply { return run.summary }
        if run.phase == .failed { return L10n.t("这一步遇到了问题：") + run.summary }
        return L10n.t("这项工作已有成果，相关邮件和附件都保留为依据。你可以打开内容继续编辑或追问。")
    }
    private func preview(_ content: String) -> String { content.replacingOccurrences(of: #"(?m)^#{1,6}\s*"#, with: "", options: .regularExpression).replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
}
