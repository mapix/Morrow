import SwiftUI
import MorrowCore

struct MailAnalysisSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var draft = MailAnalysisSettings()
    @State private var catalog: [String] = []
    @State private var busy = false
    @State private var status = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Ollama", systemImage: "desktopcomputer").font(Theme.body.weight(.medium))
            Text(L10n.t("自动摘要、分类、事项提取和联系人资料使用此模型。已完成且有效的分析会继续复用。")).font(Theme.label).foregroundStyle(Theme.secondary)
            Text(L10n.t("每封邮件仅提供正文前1000字符和附件名称。")).font(Theme.label).foregroundStyle(Theme.secondary)
            LabeledContent(L10n.t("Ollama服务地址")) { TextField("http://127.0.0.1:11434", text: $draft.ollamaURL).textFieldStyle(PaperFieldStyle()).accessibilityIdentifier("settings.mail-analysis.url") }
            LabeledContent(L10n.t("模型名称")) { TextField("", text: $draft.model).textFieldStyle(PaperFieldStyle()).accessibilityIdentifier("settings.mail-analysis.model") }
            HStack {
                Button(L10n.t("读取模型列表")) { guard !model.isQualityPreview else { return }; run { catalog = try await model.ai.availableModels(endpoint: draft.ollamaURL); status = L10n.t("已读取当前服务的模型列表。") } }.buttonStyle(CompactButtonStyle()).disabled(model.isQualityPreview)
                Button(L10n.t("测试模型连接")) { guard !model.isQualityPreview else { return }; run { let configuration = try draft.validated(); var settings = configuration.applying(to: model.settings); settings.enabled = true; let result = try await model.ai.complete(system: "Reply with Connected.", prompt: "Local connection test, no mail data.", settings: settings, maxTokens: 32); status = L10n.t("连接成功：") + result.source } }.buttonStyle(CompactButtonStyle()).disabled(model.isQualityPreview).accessibilityIdentifier("settings.mail-analysis.test")
            }
            if !catalog.isEmpty { Picker(L10n.t("选择模型"), selection: $draft.model) { if !catalog.contains(draft.model) { Text(draft.model).tag(draft.model) }; ForEach(catalog, id: \.self) { Text($0).tag($0) } } }
            Text(L10n.t("服务不可用时暂停分析并提示问题，不自动使用网关。远程 Ollama 地址会把邮件内容发送到该地址。")).font(Theme.small).foregroundStyle(Theme.muted)
            Button(L10n.t("保存邮件分析设置")) { run { try await model.saveMailAnalysisConfiguration(draft); status = L10n.t("邮件分析设置已保存。") } }.buttonStyle(QuietButtonStyle()).accessibilityIdentifier("settings.mail-analysis.save")
            if busy { ProgressView().controlSize(.small) }
            if !status.isEmpty { Text(status).font(Theme.label).foregroundStyle(Theme.secondary).textSelection(.enabled).accessibilityIdentifier("settings.mail-analysis.feedback") }
        }.disabled(busy).onAppear { draft = model.settings.mailAnalysisConfiguration }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        busy = true; status = ""
        Task { defer { busy = false }; do { try await action() } catch { status = error.localizedDescription } }
    }
}
