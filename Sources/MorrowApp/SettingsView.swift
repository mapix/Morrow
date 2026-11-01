import SwiftUI
import MorrowCore
import AppKit
import ServiceManagement

struct AccountSetupView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var initial: MailAccount? = nil
    @State private var account = MailAccount()
    @State private var password = ""
    @State private var provider = MailProvider.other.rawValue
    @State private var appliedProvider = MailProvider.other.rawValue
    @State private var busy = false
    @State private var error = ""
    @State private var advanced = false
    @State private var task: Task<Void, Never>?
    private var browserLogin: Bool { account.authMethod == "oauth" }
    private var loginTitle: String { browserLogin ? (account.oauthProvider == "google" ? L10n.t("用 Google 登录") : L10n.t("用 Microsoft 登录")) : L10n.t("验证并连接") }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text(initial == nil ? L10n.t("连接邮箱") : L10n.t("邮箱设置")).font(Theme.title); Spacer(); Button { task?.cancel(); dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help(L10n.t("关闭")) }
            Text(browserLogin ? L10n.t("在浏览器中选择账户并授权，连接后邮件会自动同步。") : L10n.t("使用邮箱提供商的客户端授权码连接。网易和 QQ 需先开启 IMAP/SMTP。")).font(Theme.body).foregroundStyle(Theme.secondary)
            ScrollView { VStack(alignment: .leading, spacing: 18) {
                Picker(L10n.t("提供商"), selection: $provider) { ForEach(MailProvider.allCases) { Text(L10n.t($0.rawValue)).tag($0.rawValue) } }
                    .onChange(of: provider) { old, value in guard value != appliedProvider else { return }; appliedProvider = value; account = MailProvider.switching(account, from: old, to: value, clientID: OAuthApplicationClients.clientID(provider: value == "Gmail" ? "google" : "microsoft")) }
                LabeledContent(L10n.t("显示名称")) { TextField(L10n.t("我的邮箱"), text: $account.name).textFieldStyle(PaperFieldStyle()).accessibilityLabel(L10n.t("显示名称")) }
                LabeledContent(L10n.t("邮箱地址")) { TextField(browserLogin && account.oauthProvider == "google" ? L10n.t("可留空，在 Google 中选择账户") : "name@example.com", text: $account.email).textFieldStyle(PaperFieldStyle()).accessibilityLabel(L10n.t("邮箱地址")) }
                if !browserLogin { LabeledContent(L10n.t("客户端授权码")) { SecureField("", text: $password).textFieldStyle(PaperFieldStyle()).accessibilityLabel(L10n.t("客户端授权码")) } }
                if browserLogin && account.oauthClientID.isEmpty {
                    Text(L10n.t("Morrow 的") + (account.oauthProvider == "google" ? "Google" : "Microsoft") + L10n.t("浏览器登录尚未配置。")).font(Theme.label).foregroundStyle(Theme.error)
                    TextField(L10n.t("应用的 OAuth 桌面客户端 ID"), text: $account.oauthClientID).textFieldStyle(PaperFieldStyle()).accessibilityLabel(L10n.t("应用OAuth客户端ID"))
                }
                DisclosureGroup(L10n.t("连接选项"), isExpanded: $advanced) {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker(L10n.t("登录方式"), selection: $account.authMethod) { Text(L10n.t("浏览器授权")).tag("oauth"); Text(L10n.t("客户端授权码")).tag("password") }
                        Picker(L10n.t("接收协议"), selection: Binding(get: { account.receiveProtocol ?? "imap" }, set: { value in account.receiveProtocol = value; account.imapHost = account.imapHost.replacingOccurrences(of: value == "pop3" ? "imap." : "pop.", with: value == "pop3" ? "pop." : "imap."); account.imapPort = value == "pop3" ? 995 : 993 })) { Text(L10n.t("IMAP，同步文件夹")).tag("imap"); Text(L10n.t("POP3，下载邮件")).tag("pop3") }
                        if browserLogin {
                            Picker(L10n.t("授权提供商"), selection: $account.oauthProvider) { Text("Google").tag("google"); Text("Microsoft").tag("microsoft") }
                            if !account.oauthClientID.isEmpty { TextField(L10n.t("应用OAuth客户端ID"), text: $account.oauthClientID).textFieldStyle(PaperFieldStyle()) }
                        }
                        TextField(account.usesPOP ? L10n.t("POP3服务器") : L10n.t("IMAP服务器"), text: $account.imapHost).textFieldStyle(PaperFieldStyle())
                        TextField(L10n.t("接收TLS端口"), value: $account.imapPort, format: .number).textFieldStyle(PaperFieldStyle())
                        TextField(L10n.t("SMTP服务器"), text: $account.smtpHost).textFieldStyle(PaperFieldStyle())
                        TextField(L10n.t("SMTP端口"), value: $account.smtpPort, format: .number).textFieldStyle(PaperFieldStyle())
                        Toggle(L10n.t("SMTP使用STARTTLS"), isOn: $account.smtpStartTLS)
                        Text(L10n.t("签名")).font(Theme.label); TextEditor(text: $account.signature).font(Theme.body).frame(height: 70)
                    }.padding(.top, 12)
                }.font(Theme.label)
            }.disabled(busy) }
            if !error.isEmpty { Text(error).font(Theme.label).foregroundStyle(Theme.error).textSelection(.enabled) }
            HStack { Button(L10n.t("取消")) { task?.cancel(); dismiss() }.buttonStyle(QuietButtonStyle()); Spacer(); if busy { ProgressView().controlSize(.small) }; Button(busy ? L10n.t("等待浏览器授权…") : loginTitle) { connect() }.buttonStyle(PrimaryButtonStyle()).disabled(busy || (browserLogin && account.oauthClientID.isEmpty)) }
        }.padding(28).frame(width: 600, height: 640).background(Theme.paper)
            .onAppear {
                if let initial { appliedProvider = MailProvider.forAccount(initial).rawValue; provider = appliedProvider; account = initial; if account.authMethod == "oauth" && account.oauthClientID.isEmpty { account.oauthClientID = OAuthApplicationClients.clientID(provider: account.oauthProvider) } }
                else { let value = model.connectionDraft(model.suggestedAccount); appliedProvider = value.name.isEmpty ? MailProvider.other.rawValue : value.name; provider = appliedProvider; account = value }
            }.onDisappear { task?.cancel() }
    }
    private func connect() {
        busy = true; error = ""
        let snapshot = account, secret = password
        task = Task {
            defer { busy = false; task = nil }
            do {
                if snapshot.authMethod == "oauth" { try await model.connectOAuthAccount(snapshot) }
                else { let credential = secret.isEmpty && initial != nil ? try SecretStore.read(accountID: snapshot.id) : secret; try await model.addAccount(snapshot, password: credential) }
                dismiss()
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

struct SettingsView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    @State private var editing: MailAccount?
    @State private var deleting: MailAccount?
    @State private var folderName = ""
    @State private var folderAccount = ""
    @State private var launchAtLogin = false
    @State private var modelDraft = AgentSettings()
    @State private var modelKey = ""
    @State private var loadedModelDraft = false
    @StateObject private var saveFeedback = SettingsSaveFeedback()
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text(L10n.t("设置")).font(Theme.title).padding(.top, 12)
                section(L10n.t("邮箱")) {
                    ForEach(model.accounts) { a in
                        HStack { VStack(alignment: .leading, spacing: 6) { Text(a.name).font(Theme.body.weight(.medium)); Text(a.email).font(Theme.label).foregroundStyle(Theme.muted); Text(a.isDemo ? L10n.t("演示邮箱") : model.accountSyncStates[a.id]?.error ?? model.accountSyncStates[a.id]?.lastSyncAt.map { L10n.t("同步于 ") + $0.uiFormatted() } ?? L10n.t("尚未同步")).font(Theme.small).foregroundStyle(model.accountSyncStates[a.id]?.error == nil ? Theme.secondary : Theme.error) }; Spacer(); if !a.isDemo { Button(L10n.t("设置")) { editing = a }.buttonStyle(.link) }; Button(L10n.t("移除")) { deleting = a }.buttonStyle(.link) }.padding(.vertical, 12)
                        Divider().overlay(Theme.rule)
                    }
                    Button { model.showAccount = true } label: { Label(L10n.t("添加邮箱"), systemImage: "plus") }.buttonStyle(QuietButtonStyle()).padding(.top, 12)
                }
                section(L10n.t("伙伴")) {
                    Toggle(L10n.t("让伙伴主动整理和推进委托"), isOn: runtimeBinding(\.enabled))
                    Toggle(L10n.t("自动阅读新邮件，准备事项和回复建议"), isOn: runtimeBinding(\.autoAnalyze))
                    ModelQuickSwitchView { modelDraft = model.settings; modelKey = "" }
                    ModelSettingsView(draft: $modelDraft, key: $modelKey, saveFeedback: saveFeedback, onEdited: { saveFeedback.edited() })
                    HStack { Button(L10n.t("启用重要事项通知")) { Task { await model.requestNotifications() } }.buttonStyle(QuietButtonStyle()); Text(model.settings.notifications ? L10n.t("通知已启用") : L10n.t("通知未启用")).font(Theme.label).foregroundStyle(Theme.muted) }
                }
                section(L10n.t("布局与记忆")) {
                    PresentationSettingsView()
                    Picker(L10n.t("布局密度"), selection: $model.workspacePreferences.density) { Text(L10n.t("紧凑")).tag("compact"); Text(L10n.t("宽松")).tag("comfortable") }.pickerStyle(.segmented).frame(maxWidth: 360).onChange(of: model.workspacePreferences.density) { Task { await model.savePreferences() } }
                    Toggle(L10n.t("使用长期记忆"), isOn: $model.workspacePreferences.memoryEnabled).onChange(of: model.workspacePreferences.memoryEnabled) { Task { await model.savePreferences() } }
                    Button(L10n.t("管理记忆")) { model.workspacePage = .memory }.buttonStyle(QuietButtonStyle())
                }
                section("iCloud") { CloudWorkspaceSettingsView(cloud: model.cloudWorkspace) }
                section(L10n.t("自动索引")) {
                    HStack { Text("EmbeddingGemma 2").font(Theme.body.weight(.medium)); Spacer(); Text(L10n.format("{0} / {1} 封已索引", "\(model.indexCount)", "\(model.mailCount)")).font(Theme.label).foregroundStyle(Theme.muted) }
                    Text(model.indexStatus).font(Theme.label).foregroundStyle(Theme.muted)
                    HStack { TextField(L10n.t("本机模型文件夹"), text: runtimeBinding(\.embeddingDirectory)).textFieldStyle(PaperFieldStyle()); Button(L10n.t("选择…")) { let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; if panel.runModal() == .OK, let url = panel.url { runtimeBinding(\.embeddingDirectory).wrappedValue = url.path } }.buttonStyle(QuietButtonStyle()) }
                    Toggle(L10n.t("索引可提取的附件文字（PDF、文本和 CSV）"), isOn: runtimeBinding(\.indexAttachments))
                    Button(L10n.t("继续索引")) { model.process() }.buttonStyle(QuietButtonStyle())
                }
                section(L10n.t("同步与运行")) {
                    Stepper(L10n.format("每 {0} 秒同步邮箱", "\(model.settings.syncInterval)"), value: runtimeBinding(\.syncInterval), in: 60...900, step: 60)
                    Toggle(L10n.t("登录 Mac 时打开 Morrow"), isOn: Binding(get: { launchAtLogin }, set: { value in
                        do { if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; launchAtLogin = value } catch { model.error = error.localizedDescription }
                    }))
                    Text(L10n.t("关闭窗口后，Morrow 留在菜单栏并继续同步。退出应用后，委托和定时发送会在下次启动继续。")).font(Theme.label).foregroundStyle(Theme.muted)
                    Button(L10n.t("打开本机邮件数据文件夹")) { NSWorkspace.shared.open(model.store.root) }.buttonStyle(.link)
                }
                if !model.realAccounts.isEmpty {
                    section(L10n.t("新建邮箱文件夹")) {
                        HStack { Picker(L10n.t("邮箱"), selection: $folderAccount) { Text(L10n.t("选择邮箱")).tag(""); ForEach(model.realAccounts) { Text($0.name).tag($0.id) } }.frame(width: 200); TextField(L10n.t("文件夹名称"), text: $folderName).textFieldStyle(PaperFieldStyle()); Button(L10n.t("创建")) { guard let a = model.accounts.first(where: { $0.id == folderAccount }), !folderName.isEmpty else { return }; Task { do { try await model.createFolder(a, name: folderName); folderName = "" } catch { model.error = error.localizedDescription } } }.buttonStyle(QuietButtonStyle()) }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button(saveFeedback.isSaving ? L10n.t("保存中…") : L10n.t("保存设置")) {
                            let configuration = modelDraft, credential = modelKey
                            Task { let saved = await saveFeedback.perform { try await model.saveModelConfiguration(configuration, apiKey: credential) }; if saved { modelKey = "" } }
                        }.buttonStyle(PrimaryButtonStyle()).disabled(saveFeedback.isSaving).accessibilityIdentifier("settings.save")
                        Text(L10n.t("设置与委托保存在本机。")).font(Theme.label).foregroundStyle(Theme.muted)
                    }
                    if saveFeedback.scope == .general { SettingsSaveFeedbackView(feedback: saveFeedback, success: L10n.t("修改已保存"), identifier: "settings.save.feedback") }
                }
            }.padding(32).frame(maxWidth: 980, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading).disabled(saveFeedback.isSaving)
        }.background(Theme.paper).sheet(item: $editing) { account in AccountSetupView(initial: account).environmentObject(model) }
            .alert(L10n.t("移除邮箱？"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) { Button(L10n.t("取消"), role: .cancel) { deleting = nil }; Button(L10n.t("移除本机账户"), role: .destructive) { if let account = deleting { Task { await model.removeAccount(account) } }; deleting = nil } } message: { Text(L10n.t("会移除此 Mac 上的邮件缓存和授权码，服务器上的邮件会保留。")) }
            .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled; if !loadedModelDraft { modelDraft = model.settings; loadedModelDraft = true } }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View { VStack(alignment: .leading, spacing: 16) { Text(title).font(Theme.heading); Divider().overlay(Theme.rule); content() }.padding(.bottom, 8) }
    private func runtimeBinding<Value>(_ path: WritableKeyPath<AgentSettings, Value>) -> Binding<Value> {
        Binding(get: { model.settings[keyPath: path] }, set: { value in saveFeedback.edited(); model.settings[keyPath: path] = value })
    }
}

struct ContactsView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var editing: ContactEntry?
    private var contacts: [ContactEntry] {
        var out = model.contacts; var seen = Set(out.map { $0.email.lowercased() })
        for address in model.mails.flatMap({ [$0.from] + $0.to + $0.cc }) where seen.insert(address.email.lowercased()).inserted { var c = ContactEntry(); c.id = "discovered:" + address.email.lowercased(); c.name = address.name; c.email = address.email; out.append(c) }
        return out.filter { query.isEmpty || ($0.name + $0.email + $0.company).localizedCaseInsensitiveContains(query) }.sorted { $0.address.display.localizedCompare($1.address.display) == .orderedAscending }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(L10n.t("与你通信的人")).font(Theme.title).padding(.top, 12)
            HStack { TextField(L10n.t("姓名或邮箱地址"), text: $query).textFieldStyle(PaperFieldStyle()).frame(width: 320); Spacer(); Button(L10n.t("导入系统通讯录")) { Task { await model.importSystemContacts() } }.buttonStyle(QuietButtonStyle()); Button(L10n.t("添加联系人")) { editing = ContactEntry() }.buttonStyle(PrimaryButtonStyle()) }
            if contacts.isEmpty { EmptyRegion(icon: "person.2", title: L10n.t("联系人会从邮件中整理"), detail: L10n.t("连接邮箱或导入邮件后，发件人和收件人会显示在这里。"), action: nil) }
            else { ScrollView { VStack(spacing: 0) { ForEach(contacts) { contact in
                HStack {
                    VStack(alignment: .leading, spacing: 6) { Text(contact.address.display).font(Theme.body.weight(.medium)); if !contact.company.isEmpty { Text(contact.company).font(Theme.label).foregroundStyle(Theme.muted) } }.frame(width: 210, alignment: .leading)
                    Text(contact.email).foregroundStyle(Theme.muted).textSelection(.enabled)
                    Spacer()
                    Button(L10n.t("写邮件")) { Task { await model.compose(); model.composer?.to = contact.email } }.buttonStyle(.link)
                    Menu {
                        Button(L10n.t("编辑")) { editing = contact }
                        Button(L10n.t("导出 vCard")) { model.exportContact(contact) }
                        if model.contacts.contains(where: { $0.id == contact.id }) { Button(L10n.t("移除手动联系人")) { Task { await model.removeContact(contact) } } }
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                }.padding(.vertical, 18).overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
            } } } }
        }.padding(32).background(Theme.paper).sheet(item: $editing) { c in ContactEditor(initial: c).environmentObject(model) }
    }
}

struct ContactEditor: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let initial: ContactEntry
    @State private var contact = ContactEntry()
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(L10n.t("联系人")).font(Theme.title)
            Form { TextField(L10n.t("姓名"), text: $contact.name); TextField(L10n.t("邮箱地址"), text: $contact.email); TextField(L10n.t("电话"), text: $contact.phone); TextField(L10n.t("公司"), text: $contact.company); VStack(alignment: .leading, spacing: 8) { Text(L10n.t("笔记")); TextEditor(text: $contact.note).frame(height: 80) } }.formStyle(.grouped)
            if !error.isEmpty { Text(error).font(Theme.label).foregroundStyle(Theme.error) }
            HStack { Button(L10n.t("取消")) { dismiss() }.buttonStyle(QuietButtonStyle()); Spacer(); Button(L10n.t("保存")) { Task { do { try await model.saveContact(contact); dismiss() } catch { self.error = error.localizedDescription } } }.buttonStyle(PrimaryButtonStyle()) }
        }.padding(28).frame(width: 580, height: 480).background(Theme.paper).onAppear { contact = initial }
    }
}
