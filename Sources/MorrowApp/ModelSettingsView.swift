import SwiftUI
import MorrowCore

struct ModelSettingsView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    @Binding var draft: AgentSettings
    @Binding var key: String
    @ObservedObject var saveFeedback: SettingsSaveFeedback
    var onEdited: () -> Void = {}
    @State private var busy = false
    @State private var result: String?
    @State private var catalog: [String] = []
    private var catalogID: String { draft.provider + "|" + (draft.provider == "chatgpt" ? draft.chatGPTAccountID ?? "" : draft.provider == "openai" ? draft.openAIURL ?? "https://api.openai.com/v1" : draft.ollamaURL) + "|" + key }
    private var selectedModel: String { draft.provider == "openai" ? draft.openAIModel ?? "" : draft.model }
    private var configurationID: String { SettingsSaveFeedback.configurationID(draft) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker(L10n.t("模型服务"), selection: $draft.provider) { Text(L10n.t("自动选择本机模型")).tag("auto"); Text("Ollama").tag("ollama"); Text(L10n.t("OpenAI兼容服务")).tag("openai"); Text("ChatGPT").tag("chatgpt"); Text("Apple Intelligence").tag("apple") }
            if draft.provider == "chatgpt" {
                ChatGPTLoginView(draft: $draft)
            } else if draft.provider == "openai" {
                LabeledContent(L10n.t("服务地址")) { TextField("https://service.example/v1", text: Binding(get: { draft.openAIURL ?? "https://api.openai.com/v1" }, set: { draft.openAIURL = $0 })).textFieldStyle(PaperFieldStyle()).accessibilityLabel(L10n.t("兼容模型服务地址")) }
                LabeledContent(L10n.t("API密钥")) { SecureField("", text: Binding(get: { key }, set: { key = $0; saveFeedback.edited(); onEdited() })).textFieldStyle(PaperFieldStyle()).accessibilityLabel(L10n.t("模型API密钥")) }
                Text(L10n.t("留空保留已保存的密钥。")).font(Theme.small).foregroundStyle(Theme.secondary)
                DisclosureGroup(L10n.t("连接问题")) {
                Button(L10n.t("授权读取已存凭据")) {
                    let id = ModelEndpoint.credentialID(draft.openAIURL ?? "https://api.openai.com/v1")
                    busy = true; result = nil
                    Task {
                        defer { busy = false }
                        do {
                            _ = try await Task.detached { try SecretStore.read(accountID: id, allowInteraction: true, forceReload: true) }.value
                            result = L10n.t("钥匙串凭据已允许读取。")
                        } catch { result = error.localizedDescription }
                    }
                }.buttonStyle(QuietButtonStyle()).disabled(busy).accessibilityIdentifier("settings.model.credentials.authorize")
                }
                LabeledContent(L10n.t("模型ID")) { TextField("", text: Binding(get: { draft.openAIModel ?? "" }, set: { draft.openAIModel = $0 })).textFieldStyle(PaperFieldStyle()).accessibilityLabel(L10n.t("兼容服务模型ID")) }
                DisclosureGroup(L10n.t("兼容设置")) { Toggle(L10n.t("严格JSON Schema输出（需模型支持）"), isOn: Binding(get: { draft.strictJSON ?? false }, set: { draft.strictJSON = $0 })); Toggle(L10n.t("使用developer指令角色"), isOn: Binding(get: { draft.useDeveloperRole ?? false }, set: { draft.useDeveloperRole = $0 })) }.font(Theme.label)
            } else if draft.provider != "apple" {
                LabeledContent(L10n.t("Ollama服务地址")) { TextField("http://127.0.0.1:11434", text: $draft.ollamaURL).textFieldStyle(PaperFieldStyle()).accessibilityLabel(L10n.t("Ollama服务地址")) }
                LabeledContent(L10n.t("模型名称")) { TextField("", text: $draft.model).textFieldStyle(PaperFieldStyle()).accessibilityLabel(L10n.t("本机思考模型名称")) }
            }
            if draft.provider != "apple" && draft.provider != "chatgpt" {
                HStack {
                    Button(L10n.t("读取模型列表")) {
                        let snapshot = draft, credential = key.isEmpty ? nil : key, identity = catalogID
                        busy = true; result = nil
                        Task { defer { busy = false }; do { let values = try await model.ai.configuredModels(settings: snapshot, apiKey: credential); guard identity == catalogID else { return }; catalog = values; result = values.isEmpty ? L10n.t("这个服务暂未提供模型列表，可手动填写模型ID。") : L10n.t("已读取当前服务的模型列表。") } catch { if identity == catalogID { result = error.localizedDescription } } }
                    }.buttonStyle(QuietButtonStyle())
                    Button(L10n.t("测试模型连接")) {
                        var snapshot = draft; snapshot.enabled = true
                        let credential = key.isEmpty ? nil : key, identity = catalogID
                        busy = true; result = nil
                        Task { defer { busy = false }; do { let reply = try await model.ai.complete(system: L10n.t("只回复连接成功。"), prompt: L10n.t("这是模型连接测试，不包含邮件。"), settings: snapshot, maxTokens: 64, apiKey: credential); if identity == catalogID { result = L10n.t("连接成功：") + reply.source } } catch { if identity == catalogID { result = error.localizedDescription } } }
                    }.buttonStyle(QuietButtonStyle())
                }
                if !catalog.isEmpty {
                    Picker(L10n.t("选择模型"), selection: Binding(get: { selectedModel }, set: { if draft.provider == "openai" { draft.openAIModel = $0 } else { draft.model = $0 } })) {
                        if !catalog.contains(selectedModel) { Text(selectedModel.isEmpty ? L10n.t("选择模型") : selectedModel + L10n.t("（手动填写）")).tag(selectedModel) }
                        ForEach(catalog, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            if draft.provider == "chatgpt" {
                Button(L10n.t("测试模型连接")) {
                    var snapshot = draft; snapshot.enabled = true
                    let identity = catalogID; busy = true; result = nil
                    Task {
                        defer { busy = false }
                        do { let reply = try await model.ai.complete(system: "Reply with Connected.", prompt: "Connection test, no mail data.", settings: snapshot, maxTokens: 64); if identity == catalogID { result = L10n.t("连接成功：") + reply.source } }
                        catch { if identity == catalogID { result = error.localizedDescription } }
                    }
                }.buttonStyle(QuietButtonStyle())
            } else {
                Text(draft.provider == "openai" ? L10n.t("聊天与委托内容会发给此服务。自动邮件分析使用单独的模型设置。") : L10n.t("本机模型在这台Mac上处理邮件；远程地址会把内容发送给该服务。")).font(Theme.label).foregroundStyle(Theme.secondary)
            }
            Text(L10n.t("保存后应用；连接测试只使用当前填写的配置。")).font(Theme.small).foregroundStyle(Theme.secondary)
            RetrievalDecisionSettingsView(draft: $draft)
            if busy { ProgressView().controlSize(.small) }
            if let result { Text(result).font(Theme.label).foregroundStyle(Theme.secondary).textSelection(.enabled) }
            Button(saveFeedback.isSaving ? L10n.t("保存中…") : L10n.t("保存模型设置")) {
                let snapshot = draft, credential = key
                result = nil
                Task { let saved = await saveFeedback.perform(scope: .model) { try await model.saveModelConfiguration(snapshot, apiKey: credential) }; if saved { key = "" } }
            }.buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("settings.model.save")
            if saveFeedback.scope == .model { SettingsSaveFeedbackView(feedback: saveFeedback, success: L10n.t("模型设置已保存。"), identifier: "settings.model.save.feedback") }
        }.disabled(busy || saveFeedback.isSaving).onChange(of: catalogID) { catalog = []; result = nil }.onChange(of: configurationID) { saveFeedback.edited(); onEdited() }
    }
}
