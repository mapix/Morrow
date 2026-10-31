import Foundation
import MorrowCore

extension AppModel {
    /// Publish only a validated, persisted configuration to background work.
    func saveModelConfiguration(_ draft: AgentSettings, apiKey: String = "") async throws {
        var next = settings
        next.provider = draft.provider
        next.ollamaURL = draft.ollamaURL.trimmingCharacters(in: .whitespacesAndNewlines)
        next.model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        next.openAIURL = draft.openAIURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        next.openAIModel = draft.openAIModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        next.strictJSON = draft.strictJSON; next.useDeveloperRole = draft.useDeveloperRole
        next.chatGPTAccountID = draft.chatGPTAccountID; next.chatGPTModel = draft.chatGPTModel
        next.replyLanguage = PresentationPreferences.shared.replyLanguageName
        if next.provider == "chatgpt" {
            guard let id = next.chatGPTAccountID, let chosen = next.chatGPTModel, !chosen.isEmpty else { throw MailError.message("请登录ChatGPT并选择可用模型。") }
            let profiles = await ChatGPTService.shared.savedProfiles()
            guard profiles.contains(where: { $0.id == id && $0.signedIn && $0.planEnabled }) else { throw ChatGPTServiceError("plan_permission_missing") }
            let catalog = try await ChatGPTPlanClient.shared.models(profileID: id)
            guard catalog.contains(where: { $0.slug == chosen }) else { throw MailError.message("当前ChatGPT账户无法使用所选模型。") }
        } else if next.provider == "openai" {
            let base = next.openAIURL ?? "https://api.openai.com/v1"
            _ = try ModelEndpoint.url(base, path: "models")
            guard !(next.openAIModel ?? "").isEmpty else { throw MailError.message("请填写模型ID，或从服务列表中选择。") }
            if !apiKey.isEmpty { try SecretStore.save(apiKey, accountID: ModelEndpoint.credentialID(base)) }
        } else if next.provider != "apple" {
            _ = try ModelEndpoint.url(next.ollamaURL, path: "api/tags")
            if next.provider == "ollama", next.model.isEmpty { throw MailError.message("请填写本机模型名称。") }
        }
        try await store.save(next, kind: "settings", id: "main")
        settings = next; configurationDidSave()
    }
}
