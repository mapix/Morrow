import SwiftUI
import MorrowCore

struct AgentProgressView: View {
    let trace: AgentExecutionTrace
    var live = false
    @State private var expanded = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: live ? 1 : 3600)) { timeline in
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    if live { ProgressView().controlSize(.small) } else { Image(systemName: trace.status == "completed" ? "checkmark.circle" : "pause.circle").foregroundStyle(Theme.accent2) }
                    Text(L10n.t(live ? "正在执行" : "执行记录")).font(Theme.label.weight(.semibold))
                    Spacer()
                    Text(duration((trace.finishedAt ?? timeline.date).timeIntervalSince(trace.startedAt))).font(Theme.small.monospacedDigit()).foregroundStyle(Theme.secondary)
                }
                if !trace.plan.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        Text(L10n.t("计划")).font(Theme.small).foregroundStyle(Theme.muted)
                        ForEach(trace.plan) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: item.status == "completed" ? "checkmark.circle.fill" : item.status == "in_progress" ? "circle.lefthalf.filled" : "circle").foregroundStyle(item.status == "pending" ? Theme.muted : Theme.accent2).frame(width: 15)
                                Text(item.title).font(Theme.label).foregroundStyle(item.status == "completed" ? Theme.secondary : Theme.ink).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if live, let model = trace.models.last, model.seconds == nil {
                    HStack { Text(L10n.t("模型正在响应")); Spacer(); Text(duration(timeline.date.timeIntervalSince(model.startedAt))).monospacedDigit() }.font(Theme.small).foregroundStyle(Theme.secondary)
                }
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(trace.tools) { step in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: step.status == "completed" ? "checkmark" : step.status == "failed" ? "exclamationmark.circle" : "ellipsis").foregroundStyle(step.status == "failed" ? Theme.error : Theme.accent2).frame(width: 15)
                                Text(title(step.tool)).font(Theme.label); Spacer(minLength: 8)
                                Text(duration(step.seconds ?? timeline.date.timeIntervalSince(step.startedAt))).font(Theme.small.monospacedDigit()).foregroundStyle(Theme.secondary)
                            }
                        }
                        if !trace.models.isEmpty {
                            Divider().overlay(Theme.rule)
                            ForEach(trace.models) { model in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack { Text((model.model ?? L10n.t("模型")) + " · " + String(model.step)); Spacer(); Text(duration(model.seconds ?? timeline.date.timeIntervalSince(model.startedAt))).monospacedDigit() }
                                    if let queue = model.queueSeconds, let request = model.requestSeconds { Text(L10n.format("排队 {0} · 请求 {1}", duration(queue), duration(request))).foregroundStyle(Theme.muted) }
                                    if let prompt = model.promptSeconds, let generation = model.generationSeconds { Text(L10n.format("处理输入 {0} · 生成 {1}", duration(prompt), duration(generation))).foregroundStyle(Theme.muted) }
                                }.font(Theme.small)
                            }
                        }
                    }.padding(.top, 8)
                } label: { Text(L10n.format("实际步骤（{0}）", String(trace.tools.count))).font(Theme.label) }
            }.padding(14).background(Theme.sidebar.opacity(0.65), in: RoundedRectangle(cornerRadius: Theme.radius))
        }.accessibilityIdentifier("agent.execution.progress")
    }
    private func duration(_ seconds: Double) -> String { let value = max(0, Int(seconds)); return value < 60 ? "\(value)s" : "\(value / 60)m \(value % 60)s" }
    private func title(_ name: String) -> String {
        let names = ["search_mail":"检索邮件", "read_mail":"读取正文", "read_mails":"批量读取正文", "list_contacts":"筛选联系人", "scan_mail":"检查邮件列表", "write_plan":"更新计划", "find_tools":"发现工具", "cite_sources":"整理来源", "render_ui":"准备图表", "prepare_draft":"保存草稿", "read_attachment":"读取附件", "delegate_task":"执行分任务", "mail_statistics":"读取统计"]
        return L10n.t(names[name] ?? name.replacingOccurrences(of: "_", with: " "))
    }
}
