import SwiftUI
import MorrowCore

struct ChatGPTLoginView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @Binding var draft: AgentSettings
    @StateObject private var login = ChatGPTLoginModel()
    private var selectedProfile: ChatGPTProfile? { login.profiles.first { $0.id == draft.chatGPTAccountID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("使用你的 ChatGPT 计划")).font(Theme.heading)
            Text(L10n.t("符合条件的 AI 请求使用 ChatGPT 计划中的用量；具体权限由账户和工作区决定。")).font(Theme.label).foregroundStyle(Theme.secondary)
            if !login.profiles.isEmpty {
                Picker(L10n.t("ChatGPT 账户与工作区"), selection: Binding(get: { draft.chatGPTAccountID ?? "" }, set: { draft.chatGPTAccountID = $0.isEmpty ? nil : $0; draft.chatGPTModel = nil; login.changeAccount() })) {
                    Text(L10n.t("选择账户")).tag("")
                    ForEach(login.profiles) { profile in Text(profile.detail + "  /  " + String(profile.clientID.suffix(8)) + (profile.signedIn ? "" : L10n.t("（已退出）"))).tag(profile.id) }
                }.disabled(login.busy)
            }
            HStack {
                Button("Continue with ChatGPT") { login.signIn(profileID: selectedProfile?.id) }.buttonStyle(PrimaryButtonStyle()).disabled(login.busy)
                if login.signingIn { Button(L10n.t("取消登录")) { login.cancel() }.buttonStyle(QuietButtonStyle()) }
                else { Button(L10n.t("添加账户或工作区")) { login.signIn(resumePending: false) }.buttonStyle(QuietButtonStyle()) }
            }
            if let profile = selectedProfile, profile.signedIn {
                HStack {
                    Text(profile.planEnabled ? "Using ChatGPT plan" : L10n.t("尚未授权计划使用")).font(Theme.label)
                    Link("Manage usage", destination: URL(string: "https://chatgpt.com/settings/usage")!).font(Theme.label)
                    Spacer()
                    Button(L10n.t("退出这个账户")) { login.signOut(profileID: profile.id) }.buttonStyle(CompactButtonStyle()).disabled(login.busy)
                }
                if profile.planEnabled {
                    Picker(L10n.t("ChatGPT 模型"), selection: Binding(get: { draft.chatGPTModel ?? "" }, set: { draft.chatGPTModel = $0 })) {
                        if !login.catalog.contains(where: { $0.slug == draft.chatGPTModel }) { Text(draft.chatGPTModel ?? L10n.t("选择模型")).tag(draft.chatGPTModel ?? "") }
                        ForEach(login.catalog) { Text($0.displayName).tag($0.slug) }
                    }.disabled(login.busy)
                    Button(L10n.t("刷新可用模型")) { Task { await login.refreshCatalog(profileID: profile.id) } }.buttonStyle(CompactButtonStyle()).disabled(login.busy)
                }
            }
            if login.busy { ProgressView().controlSize(.small) }
            if let status = login.status { Text(status).font(Theme.label).foregroundStyle(Theme.secondary).textSelection(.enabled) }
            Text(L10n.t("登录凭据只保存在这台设备的钥匙串。保存模型设置后应用。")).font(Theme.small).foregroundStyle(Theme.secondary)
        }
        .task { await login.load() }
        .task(id: draft.chatGPTAccountID) { if let id = draft.chatGPTAccountID { await login.refreshCatalog(profileID: id) } }
        .onChange(of: login.newlyConnected) { if let profile = login.newlyConnected { draft.chatGPTAccountID = profile.id; draft.chatGPTModel = nil } }
        .sheet(item: $login.welcomeProfile) { profile in
            VStack(alignment: .leading, spacing: 20) {
                Text("You're using your ChatGPT plan").font(Theme.heading)
                Text(L10n.t("Morrow 中符合条件的 AI 请求将使用你的 ChatGPT 计划。你可以在 ChatGPT 设置中管理用量。")).font(Theme.body)
                Link("Manage usage", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                Button("Got it") { Task { await login.dismissWelcome() } }.buttonStyle(PrimaryButtonStyle())
            }.padding(30).frame(maxWidth: 460).background(Theme.sheet)
        }
        .onDisappear { if login.signingIn { login.cancel() } }
    }
}
