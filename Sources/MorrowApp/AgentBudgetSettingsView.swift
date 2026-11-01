import SwiftUI
import MorrowCore

struct AgentBudgetSettingsView: View {
    @EnvironmentObject var model: AppModel
    private var budget: AgentRunBudget { (model.settings.runBudget ?? AgentRunBudget()).bounded }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Stepper(L10n.format("每段最多 {0} 轮模型调用", String(budget.modelTurns)), value: binding(\.modelTurns), in: 16...512, step: 16)
            Stepper(L10n.format("每段最多 {0} 次工具调用", String(budget.toolCalls)), value: binding(\.toolCalls), in: 64...4096, step: 128)
            Stepper(L10n.format("每次最多运行 {0} 分钟", String(budget.seconds / 60)), value: binding(\.seconds), in: 300...14400, step: 300)
            Text(L10n.t("达到预算或遇到问题时保存进度，说明已完成部分，等你决定后继续。")).font(Theme.label).foregroundStyle(Theme.muted)
        }
    }
    private func binding(_ path: WritableKeyPath<AgentRunBudget, Int>) -> Binding<Int> {
        Binding(get: { budget[keyPath: path] }, set: { value in var next = budget; next[keyPath: path] = value; model.settings.runBudget = next; Task { await model.saveSettings() } })
    }
}

struct AgentBudgetSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text(L10n.t("任务运行预算")).font(Theme.heading); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(ToolbarIconButtonStyle()).accessibilityLabel(L10n.t("关闭")) }
            AgentBudgetSettingsView()
            Text(L10n.t("修改立即保存，下一次继续任务时使用新预算。")).font(Theme.label).foregroundStyle(Theme.secondary)
            HStack { Spacer(); Button(L10n.t("完成")) { dismiss() }.buttonStyle(PrimaryButtonStyle()) }
        }.padding(28).frame(width: 520).background(Theme.paper).accessibilityIdentifier("agent.budget.sheet")
    }
}
