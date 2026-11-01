import SwiftUI
import MorrowCore

extension AppModel {
    func selectModelPreset(local: Bool) async throws {
        var value = settings; value.provider = local ? "ollama" : "openai"
        if !local { guard !(value.openAIURL ?? "").isEmpty, !(value.openAIModel ?? "").isEmpty else { throw MailError.message("请先保存网关地址和模型。") } }
        try await saveModelConfiguration(value, apiKey: "")
    }
}

struct ModelQuickSwitchView: View {
    @EnvironmentObject var model: AppModel
    var selected: () -> Void
    @State private var busy = false
    @State private var status = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { switchModel(local: false) } label: { Label(L10n.t("网关模型"), systemImage: model.settings.provider == "openai" ? "checkmark.circle.fill" : "network") }.buttonStyle(QuietButtonStyle()).accessibilityIdentifier("model.preset.gateway")
                Button { switchModel(local: true) } label: { Label("Ollama", systemImage: ["ollama","auto"].contains(model.settings.provider) ? "checkmark.circle.fill" : "desktopcomputer") }.buttonStyle(QuietButtonStyle()).accessibilityIdentifier("model.preset.ollama")
            }.disabled(busy)
            Text(model.settings.provider == "openai" ? model.settings.openAIModel ?? "" : model.settings.model).font(Theme.small).foregroundStyle(Theme.secondary)
            if !status.isEmpty { Text(status).font(Theme.small).foregroundStyle(Theme.secondary) }
        }
    }
    private func switchModel(local: Bool) {
        busy = true
        Task { defer { busy = false }; do { try await model.selectModelPreset(local: local); selected(); status = L10n.t("模型选择已保存") } catch { status = error.localizedDescription } }
    }
}
