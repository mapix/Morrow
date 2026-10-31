import Foundation
import MorrowCore

extension MobileModel {
    func saveModelConfiguration(_ value: AgentSettings, apiKey: String) async throws {
        var next = value
        next.replyLanguage = MobileL10n.responseLanguage
        if next.provider == "chatgpt" {
            guard let id = next.chatGPTAccountID, let model = next.chatGPTModel, !model.isEmpty else {
                throw MailError.message(ChatGPTMobileText.text("请先登录并选择 ChatGPT 模型。", "Sign in and choose a ChatGPT model first.", "先にログインして ChatGPT モデルを選択してください。"))
            }
            let profiles = await ChatGPTService.shared.savedProfiles()
            guard profiles.contains(where: { $0.id == id && $0.signedIn && $0.planEnabled }) else { throw ChatGPTServiceError("plan_permission_missing") }
            let catalog = try await ChatGPTPlanClient.shared.models(profileID: id)
            guard catalog.contains(where: { $0.slug == model }) else { throw MailError.message(ChatGPTMobileText.text("所选模型在当前账户不可用。", "The selected model is unavailable for this account.", "選択したモデルはこのアカウントでは利用できません。")) }
        } else if next.provider == "openai" {
            let base = next.openAIURL ?? "https://api.openai.com/v1"
            _ = try ModelEndpoint.url(base, path: "models")
            guard !(next.openAIModel ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MailError.message(MobileL10n.text("请填写模型名称。")) }
            if !apiKey.isEmpty { try SecretStore.save(apiKey, accountID: ModelEndpoint.credentialID(base)) }
        } else if next.provider == "ollama" || next.provider == "auto" {
            _ = try ModelEndpoint.url(next.ollamaURL, path: "api/tags")
            if next.provider == "ollama", next.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw MailError.message(MobileL10n.text("请填写模型名称。")) }
        }
        let changedIndex = next.embeddingDirectory != settings.embeddingDirectory
        try await store.save(next, kind: "settings", id: "default")
        settings = next
        if changedIndex, !next.embeddingDirectory.isEmpty { Task { await indexAll() } }
        if next.enabled { await retryPendingProcessing() }
    }
}
