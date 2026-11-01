import SwiftUI
import MorrowCore
import UniformTypeIdentifiers

struct MobileSettings: View {
    @EnvironmentObject var model: MobileModel
    @Environment(\.dismiss) var dismiss
    @AppStorage("SmailMobileLanguage") var language = "zh-Hans"
    @AppStorage("SmailMobileTheme") var theme = "coral"
    @AppStorage("SmailMobileCompact") var compact = false
    @State var settings = AgentSettings()
    @State var key = ""
    @State var addAccount = false
    @State var addGmail = false
    @State var importModel = false
    @State var saveBusy = false
    private func decisionField<T>(_ key: WritableKeyPath<RetrievalDecisionSettings, T>) -> Binding<T> {
        Binding(get: { (settings.retrievalDecision ?? RetrievalDecisionSettings())[keyPath: key] }, set: { value in var next = settings.retrievalDecision ?? RetrievalDecisionSettings(); next[keyPath: key] = value; settings.retrievalDecision = next })
    }
    var body: some View { Form {
        Section(MobileL10n.text("邮件")) { ForEach(model.accounts) { account in VStack(alignment: .leading) { Text(account.name).font(.headline); Text(account.email).font(.caption).foregroundStyle(.secondary) } }; Button(MobileL10n.text("连接邮箱")) { addAccount = true }.accessibilityIdentifier("mailbox.connect"); Button(GmailMobileText.text("连接 Gmail", "Connect Gmail", "Gmail に接続")) { addGmail = true }.accessibilityIdentifier("mailbox.gmail.connect");  Button(MobileL10n.text("前台同步")) { Task { await model.sync() } }.disabled(model.syncing) }
        Section(MobileL10n.text("外观")) { Picker(MobileL10n.text("语言"), selection: $language) { Text(MobileL10n.text("简体中文")).tag("zh-Hans"); Text("English").tag("en"); Text(MobileL10n.text("日本語")).tag("ja") }.accessibilityIdentifier("settings.language"); Picker(MobileL10n.text("主题配色"), selection: $theme) { Text("Coral").tag("coral"); Text("Slate").tag("slate"); Text("Forest").tag("forest"); Text("Midnight").tag("dark") }.accessibilityIdentifier("settings.theme"); Toggle(MobileL10n.text("紧凑"), isOn: $compact) }
        Section(MobileL10n.text("模型")) { Picker(MobileL10n.text("模型服务"), selection: $settings.provider) { Text(ChatGPTMobileText.text("自动选择", "Auto", "自動")).tag("auto"); Text("Apple Intelligence").tag("apple"); Text("ChatGPT").tag("chatgpt"); Text("OpenAI compatible").tag("openai"); Text("Ollama (HTTPS)").tag("ollama") }.accessibilityIdentifier("settings.provider"); if settings.provider == "chatgpt" { ChatGPTMobileLoginView(draft: $settings) } else if settings.provider == "openai" { TextField(MobileL10n.text("模型地址"), text: Binding(get: { settings.openAIURL ?? "" }, set: { settings.openAIURL = $0 })).textInputAutocapitalization(.never).keyboardType(.URL); TextField(MobileL10n.text("模型名称"), text: Binding(get: { settings.openAIModel ?? "" }, set: { settings.openAIModel = $0 })).textInputAutocapitalization(.never); SecureField(MobileL10n.text("API Key"), text: $key).textInputAutocapitalization(.never) } else if settings.provider == "ollama" { TextField(MobileL10n.text("模型地址"), text: $settings.ollamaURL).textInputAutocapitalization(.never).keyboardType(.URL); TextField(MobileL10n.text("模型名称"), text: $settings.model).textInputAutocapitalization(.never) }; Toggle(MobileL10n.text("自动分析新邮件"), isOn: $settings.autoAnalyze); Toggle(MobileL10n.text("分析附件"), isOn: $settings.indexAttachments) }
        Section(ChatGPTMobileText.text("检索决策模型", "Retrieval decision model", "検索判断モデル")) {
            Toggle(ChatGPTMobileText.text("召回后筛选与排序", "Filter and rerank retrieved mail", "検索結果を絞り込み並べ替える"), isOn: decisionField(\.enabled))
            TextField(ChatGPTMobileText.text("决策服务地址", "Decision service URL", "判断サービス URL"), text: decisionField(\.baseURL)).textInputAutocapitalization(.never).keyboardType(.URL)
            TextField(ChatGPTMobileText.text("决策模型名称", "Decision model", "判断モデル"), text: decisionField(\.model)).textInputAutocapitalization(.never)
            Toggle(ChatGPTMobileText.text("过滤明显不相关的候选", "Filter clearly irrelevant candidates", "明らかに無関係な候補を除外"), isOn: decisionField(\.filterIrrelevant))
            Text(ChatGPTMobileText.text("默认使用 Ollama nimble。手机需填写可访问的决策服务地址；失败时保留原召回结果。", "Defaults to Ollama nimble. On iPhone, configure a reachable decision service. Failures preserve original retrieval.", "標準は Ollama nimble。iPhone から接続できるサービスを設定してください。失敗時は元の結果を保持します。")).font(.caption)
        }
        Section("EmbeddingGemma 2") { Text(MobileL10n.text(settings.embeddingDirectory.isEmpty ? "未安装本机向量模型。语义检索会明确提示缺少索引，可切换关键词。" : "已选择本机模型文件夹")).font(.caption); Button(MobileL10n.text("导入模型文件夹")) { importModel = true }; Button(MobileL10n.text("重建索引")) { Task { await model.indexAll() } }.disabled(model.indexing || settings.embeddingDirectory.isEmpty) }
        Section { NavigationLink(MobileL10n.text("记忆")) { MobileMemories() }; NavigationLink(MobileL10n.text("响应器")) { MobileResponders() }; Toggle("iCloud", isOn: Binding(get: { model.cloudRequested }, set: { enabled in Task { await model.setCloudEnabled(enabled) } })).disabled(CloudSyncService.configuredContainer() == nil).accessibilityIdentifier("settings.icloud"); Text(CloudSyncService.configuredContainer() == nil ? MobileL10n.text("iCloud 默认关闭；此安装尚未配置已签名的容器。") : model.cloudStatus.message).font(.caption).foregroundStyle(.secondary); if model.cloudStatus.enabled { Button("同步 iCloud") { Task { await model.syncCloud() } } }; Text(MobileL10n.text("手机前台同步和处理邮件；持续响应与后台工作由 Mac 执行。账号凭据保存在本机钥匙串。")).font(.caption).foregroundStyle(.secondary) }
        Section { Button(MobileL10n.text("保存")) { saveBusy = true; Task { do { try await model.saveModelConfiguration(settings, apiKey: key); key = ""; dismiss() } catch { model.error = error.localizedDescription }; saveBusy = false } }.disabled(saveBusy).accessibilityIdentifier("settings.save") }
    }.navigationTitle(MobileL10n.text("设置")).toolbar { ToolbarItem(placement: .topBarTrailing) { Button(MobileL10n.text("完成")) { dismiss() } } }.onAppear { settings = model.settings }.sheet(isPresented: $addAccount) { MobileAccountSetup().environmentObject(model) }.sheet(isPresented: $addGmail) { NavigationStack { ScrollView { GmailMobileConnectView(existingAccounts: model.accounts) { connection in try await model.acceptGmailConnection(connection); addGmail = false }.padding(22) }.navigationTitle("Gmail") } }.fileImporter(isPresented: $importModel, allowedContentTypes: [.folder]) { result in if case .success(let url) = result { Task { await model.importModel(url); settings = model.settings } } } }
}

struct MobileAccountSetup: View {
    @EnvironmentObject var model: MobileModel
    @Environment(\.dismiss) var dismiss
    @State var account = MailAccount()
    @State var secret = ""
    @State var provider = "自定义"
    @State var testing = false
    init(hint: String = "") {
        let inferred = MailProvider.infer(hint) ?? .other
        _account = State(initialValue: MailProvider.connectionDraft(hint))
        _provider = State(initialValue: inferred == .other || inferred == .gmail || inferred == .outlook ? "自定义" : inferred.rawValue)
    }
    var body: some View { NavigationStack { Form { Picker("Provider", selection: $provider) { ForEach(["自定义", "网易 163", "网易 126", "QQ 邮箱", "iCloud"], id: \.self) { Text($0) } }.onChange(of: provider) { _, value in let email = account.email; account = MailAccount.preset(value); account.email = email }; TextField(MobileL10n.text("邮箱名称"), text: $account.name); TextField(MobileL10n.text("邮箱地址"), text: $account.email).textInputAutocapitalization(.never).keyboardType(.emailAddress); SecureField(MobileL10n.text("授权码"), text: $secret).textInputAutocapitalization(.never); Section("IMAP") { TextField(MobileL10n.text("接收服务器"), text: $account.imapHost).textInputAutocapitalization(.never); TextField(MobileL10n.text("接收端口"), value: $account.imapPort, format: .number).keyboardType(.numberPad) }; Section("SMTP") { TextField(MobileL10n.text("发送服务器"), text: $account.smtpHost).textInputAutocapitalization(.never); TextField(MobileL10n.text("发送端口"), value: $account.smtpPort, format: .number).keyboardType(.numberPad); Toggle("STARTTLS", isOn: $account.smtpStartTLS) }; Button(MobileL10n.text("测试并连接")) { testing = true; Task { do { try await model.addAccount(account, secret: secret); secret = ""; dismiss() } catch { model.error = error.localizedDescription }; testing = false } }.disabled(testing); if testing { ProgressView() } }.navigationTitle(MobileL10n.text("连接邮箱")).toolbar { ToolbarItem(placement: .topBarLeading) { Button(MobileL10n.text("取消")) { dismiss() } } } } }
}

struct MobileComposer: View {
    @EnvironmentObject var model: MobileModel
    @Environment(\.dismiss) var dismiss
    let initial: ComposeDraft
    @State var draft = ComposeDraft()
    @State var sending = false
    @State var confirm = false
    @State var importFile = false
    @State var owner = UUID()
    @State var showPartner = false
    var draftFingerprint: String { let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; return ((try? encoder.encode(draft)) ?? Data()).base64EncodedString() }
    var body: some View { NavigationStack { Form { Picker(MobileL10n.text("发件邮箱"), selection: $draft.accountID) { ForEach(model.accounts) { Text($0.email).tag($0.id) } }; TextField(MobileL10n.text("收件人"), text: $draft.to).textInputAutocapitalization(.never).keyboardType(.emailAddress); TextField(MobileL10n.text("抄送"), text: $draft.cc).textInputAutocapitalization(.never); TextField(MobileL10n.text("密送"), text: $draft.bcc).textInputAutocapitalization(.never); TextField(MobileL10n.text("主题"), text: $draft.subject).accessibilityIdentifier("draft.subject"); TextEditor(text: $draft.body).frame(minHeight: 220).accessibilityIdentifier("draft.body"); ForEach(draft.attachments) { item in Text(item.name).font(.caption) }; Button(MobileL10n.text("添加文件")) { importFile = true }; Button(MobileL10n.text("委托给 Morrow")) { model.publishDraft(draft, owner: owner); showPartner = true }; Button(MobileL10n.text("保存草稿")) { Task { do { try await model.saveDraft(draft); dismiss() } catch { model.error = error.localizedDescription } } }.accessibilityIdentifier("draft.save"); Button(MobileL10n.text("发送")) { do { try draft.validate(); confirm = true } catch { model.error = error.localizedDescription } }.disabled(sending) }.navigationTitle(MobileL10n.text("草稿")).toolbar { ToolbarItem(placement: .topBarLeading) { Button(MobileL10n.text("取消")) { dismiss() } } }.onAppear { draft = initial; model.activateDraft(initial, owner: owner); model.context = .init(page: "draft", label: draft.subject); model.context?.draftID = draft.id; model.context?.accountID = draft.accountID }.onChange(of: draftFingerprint) { _, _ in model.publishDraft(draft, owner: owner) }.onReceive(model.$workingDraft) { value in if model.draftOwner == owner, let value, value.id == draft.id, value.body != draft.body || value.subject != draft.subject { draft = value } }.onDisappear { model.releaseDraft(owner: owner) }.sheet(isPresented: $showPartner) { MobileChat().environmentObject(model) }.confirmationDialog(MobileL10n.text("发送这封邮件？"), isPresented: $confirm, titleVisibility: .visible) { Button(MobileL10n.text("发送")) { sending = true; Task { do { try await model.send(draft); dismiss() } catch { model.error = error.localizedDescription }; sending = false } } } message: { Text(draft.to + "\n" + draft.subject) }.fileImporter(isPresented: $importFile, allowedContentTypes: [.item]) { result in if case .success(let url) = result { let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }; do { let bytes = try Data(contentsOf: url); guard bytes.count <= 32 * 1024 * 1024 else { throw MailError.message("附件超过 32 MB。") }; draft.attachments.append(.init(name: url.lastPathComponent, mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream", data: bytes)) } catch { model.error = error.localizedDescription } } } } }
}

struct MobileMemories: View {
    @EnvironmentObject var model: MobileModel
    @State var input = ""
    var body: some View { List { Section { TextField(MobileL10n.text("记住偏好"), text: $input, axis: .vertical); Button(MobileL10n.text("添加记忆")) { Task { await model.saveMemory(input); input = "" } }.disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }; ForEach(model.memories) { memory in VStack(alignment: .leading, spacing: 10) { Text(memory.content); Text(memory.status + " / " + memory.source).font(.caption).foregroundStyle(.secondary); HStack { Button(MobileL10n.text(memory.status == "active" ? "暂停" : "启用")) { Task { await model.toggleMemory(memory) } }; Button(MobileL10n.text("忘记"), role: .destructive) { Task { var value = memory; value.status = "forgotten"; value.updatedAt = Date(); do { try await model.store.commitMemories([value]); model.memories = model.memories.map { $0.id == value.id ? value : $0 } } catch { model.error = error.localizedDescription } } } } } } }.navigationTitle(MobileL10n.text("记忆")) }
}

struct MobileResponders: View {
    @EnvironmentObject var model: MobileModel
    @State var rule = MailResponder()
    var body: some View { Form { Section(MobileL10n.text("响应器")) { ForEach(model.responders) { value in VStack(alignment: .leading) { Text(value.title).font(.headline); Text(value.sender + " " + value.subjectContains).font(.caption); Text(MobileL10n.text("自动草稿")).font(.caption).foregroundStyle(.secondary) } } }; Section(MobileL10n.text("自动草稿")) { TextField(MobileL10n.text("名字"), text: $rule.title); Picker(MobileL10n.text("发件邮箱"), selection: $rule.accountID) { Text(MobileL10n.text("全部邮箱")).tag(""); ForEach(model.accounts) { Text($0.email).tag($0.id) } }; TextField(MobileL10n.text("发件人条件"), text: $rule.sender).textInputAutocapitalization(.never); TextField(MobileL10n.text("主题包含"), text: $rule.subjectContains); TextField(MobileL10n.text("回复内容"), text: $rule.response, axis: .vertical).lineLimit(4...8); Toggle("AI", isOn: $rule.useAI); Button(MobileL10n.text("保存")) { Task { do { try await model.saveResponder(rule); rule = MailResponder() } catch { model.error = error.localizedDescription } } } }; Text(MobileL10n.text("匹配的新邮件在前台同步后生成草稿。手机不接管 Mac 的自动发送权限。")).font(.caption).foregroundStyle(.secondary) }.navigationTitle(MobileL10n.text("响应器")) }
}
