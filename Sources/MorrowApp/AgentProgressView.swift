import SwiftUI
import MorrowCore

struct AgentProgressView: View {
    let trace: AgentExecutionTrace
    var live = false
    @State private var expanded = false
    var body: some View {
        Group {
            if live { TimelineView(.periodic(from: .now, by: 1)) { timeline in content(at: timeline.date) } }
            else { content(at: trace.finishedAt ?? trace.startedAt) }
        }.accessibilityIdentifier("agent.execution.progress")
    }
    private func content(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if live { ProgressView().controlSize(.small) }
                else { Image(systemName: trace.status == "failed" ? "exclamationmark.circle" : trace.status == "completed" ? "checkmark" : "pause").foregroundStyle(trace.status == "failed" ? Theme.error : Theme.secondary) }
                Text(L10n.t(live ? "正在处理" : trace.status == "completed" ? "已完成本轮处理" : trace.status == "failed" ? "本轮未完成" : "处理已暂停")).font(Theme.label)
                Spacer()
                Text(duration((trace.finishedAt ?? date).timeIntervalSince(trace.startedAt))).font(Theme.small.monospacedDigit()).foregroundStyle(Theme.secondary)
            }
            if live, let item = trace.plan.first(where: { $0.status == "in_progress" }) { Text(item.title).font(Theme.label).foregroundStyle(Theme.secondary).lineLimit(2) }
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 8) {
                    if !trace.plan.isEmpty {
                        Text(L10n.t("任务计划")).font(Theme.label.weight(.medium)).foregroundStyle(Theme.secondary)
                        ForEach(trace.plan) { item in HStack(alignment: .top, spacing: 8) { Image(systemName: item.status == "completed" ? "checkmark" : item.status == "in_progress" ? "arrow.right" : "minus").foregroundStyle(Theme.muted).frame(width: 14); Text(item.title).font(Theme.label).fixedSize(horizontal: false, vertical: true) } }
                    }
                    ForEach(trace.tools) { step in
                        HStack(alignment: .top, spacing: 8) { Image(systemName: step.status == "failed" ? "exclamationmark.circle" : step.status == "completed" ? "checkmark" : "ellipsis").foregroundStyle(step.status == "failed" ? Theme.error : Theme.muted).frame(width: 14); Text(title(step.tool)).font(Theme.label); Spacer(minLength: 8); Text(duration(step.seconds ?? date.timeIntervalSince(step.startedAt))).font(Theme.small.monospacedDigit()).foregroundStyle(Theme.secondary) }
                    }
                    ForEach(trace.models) { model in HStack { Text(model.model ?? L10n.t("模型响应")).lineLimit(1); Spacer(); Text(duration(model.seconds ?? date.timeIntervalSince(model.startedAt))).monospacedDigit() }.font(Theme.small).foregroundStyle(Theme.secondary) }
                }.padding(.top, 8)
            } label: { Text(L10n.t("处理详情")).font(Theme.small).foregroundStyle(Theme.secondary) }
        }.padding(.vertical, 6)
    }
    private func duration(_ seconds: Double) -> String { let value = max(0, Int(seconds)); return value < 60 ? "\(value)s" : "\(value / 60)m \(value % 60)s" }
    private func title(_ name: String) -> String {
        let names = ["search_mail":"检索邮件", "read_mail":"读取正文", "read_mails":"批量读取正文", "list_contacts":"筛选联系人", "scan_mail":"检查邮件列表", "write_plan":"更新计划", "find_tools":"发现工具", "cite_sources":"整理来源", "render_ui":"准备图表", "prepare_draft":"保存草稿", "read_attachment":"读取附件", "delegate_task":"执行分任务", "mail_statistics":"读取统计"]
        return L10n.t(names[name] ?? name.replacingOccurrences(of: "_", with: " "))
    }
}
