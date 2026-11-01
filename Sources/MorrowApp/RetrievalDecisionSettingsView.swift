import SwiftUI
import MorrowCore

struct RetrievalDecisionSettingsView: View {
    @Binding var draft: AgentSettings
    @State private var checking = false
    @State private var status: String?
    private var config: RetrievalDecisionSettings { draft.retrievalDecision ?? RetrievalDecisionSettings() }
    private func field<T>(_ key: WritableKeyPath<RetrievalDecisionSettings, T>) -> Binding<T> {
        Binding(get: { config[keyPath: key] }, set: { value in var next = config; next[keyPath: key] = value; draft.retrievalDecision = next; status = nil })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().overlay(Theme.rule)
            Text(L10n.t("检索决策模型")).font(Theme.heading)
            Toggle(L10n.t("召回后筛选与排序"), isOn: field(\.enabled)).accessibilityIdentifier("settings.retrieval-decision.enabled")
            Text(L10n.t("EmbeddingGemma 2 先找到候选，决策模型再核对相关性。默认使用本机 Ollama 的 nimble；不确定的候选会保留。")).font(Theme.label).foregroundStyle(Theme.secondary)
            if config.enabled {
                TextField(L10n.t("决策服务地址"), text: field(\.baseURL)).textFieldStyle(PaperFieldStyle()).accessibilityIdentifier("settings.retrieval-decision.url")
                TextField(L10n.t("决策模型名称"), text: field(\.model)).textFieldStyle(PaperFieldStyle()).accessibilityIdentifier("settings.retrieval-decision.model")
                Toggle(L10n.t("过滤明显不相关的候选"), isOn: field(\.filterIrrelevant))
                Text(L10n.t("只发送本轮召回的相关片段，不把整箱邮件送入决策模型。服务地址如果不是本机，片段会发送到该地址。连接失败时保留原召回结果并说明原因。")).font(Theme.label).foregroundStyle(Theme.secondary)
                HStack {
                    Button(L10n.t("测试决策模型")) {
                        let snapshot = config; checking = true; status = nil
                        Task {
                            defer { checking = false }
                            let mail = MailMessage(accountID: "synthetic", from: .init(email: "sender@example.invalid"), subject: "发布安排确认", text: "请确认下周一上午9点的发布窗口，收到确认后再执行发布。")
                            do {
                                let value = try await OllamaMailDecisionClient().relevance(.init(query: "需要我确认的发布安排", hit: .init(message: mail, score: 1, method: "连接测试")), settings: snapshot)
                                if snapshot == config { status = L10n.t("决策连接成功：") + snapshot.model + String(format: " · %.3f", value) }
                            } catch { if snapshot == config { status = error.localizedDescription } }
                        }
                    }.buttonStyle(QuietButtonStyle()).accessibilityIdentifier("settings.retrieval-decision.test")
                    if checking { ProgressView().controlSize(.small) }
                }
                if let status { Text(status).font(Theme.label).foregroundStyle(Theme.secondary).textSelection(.enabled) }
            }
        }.disabled(checking)
    }
}
