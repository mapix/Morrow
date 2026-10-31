import SwiftUI
import UIKit
import MorrowCore

/// Place in the model settings form when the selected provider is "chatgpt".
struct ChatGPTMobileLoginView: View {
    @Binding var draft: AgentSettings
    @StateObject private var login = ChatGPTMobileLoginModel()
    @State private var window: UIWindow?
    @Environment(\.scenePhase) private var scenePhase
    private var selectedProfile: ChatGPTProfile? { login.profiles.first { $0.id == draft.chatGPTAccountID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(ChatGPTMobileText.text("使用你的 ChatGPT 计划", "Use your ChatGPT plan", "ChatGPT プランを利用")).font(.headline)
                Text("Beta").font(.caption.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 3).background(.quaternary, in: Capsule())
            }
            Text(ChatGPTMobileText.text("iPhone 登录为测试版，实际账户授权与模型使用仍待验证；可用性取决于账户、工作区和应用接入资格。", "iPhone sign-in is in beta. Account authorization and model use still need verification; availability depends on the account, workspace, and app eligibility.", "iPhone ログインはベータ版です。実際の認証とモデル利用は検証待ちで、利用可否はアカウント、ワークスペース、アプリの資格に依存します。"))
                .font(.caption).foregroundStyle(.secondary)
            Text(ChatGPTMobileText.text("使用此服务分析时，邮件与资料会发送到 OpenAI。", "Mail and materials are sent to OpenAI when this service analyzes them.", "このサービスで分析すると、メールや資料が OpenAI に送信されます。"))
                .font(.caption).foregroundStyle(.secondary)
            if !login.profiles.isEmpty {
                Picker(ChatGPTMobileText.text("ChatGPT 账户与工作区", "ChatGPT account and workspace", "ChatGPT アカウントとワークスペース"), selection: Binding(get: { draft.chatGPTAccountID ?? "" }, set: {
                    draft.chatGPTAccountID = $0.isEmpty ? nil : $0
                    draft.chatGPTModel = nil
                    login.changeAccount()
                })) {
                    Text(ChatGPTMobileText.text("选择账户", "Choose account", "アカウントを選択")).tag("")
                    ForEach(login.profiles) { profile in
                        Text(profile.detail + " / " + String(profile.clientID.suffix(8)) + (profile.signedIn ? "" : ChatGPTMobileText.text("（已退出）", " (signed out)", "（ログアウト済み）"))).tag(profile.id)
                    }
                }.disabled(login.busy).accessibilityIdentifier("chatgpt.account")
            }
            Button("Continue with ChatGPT") { login.signIn(in: window, profileID: selectedProfile?.id) }
                .buttonStyle(.borderedProminent).disabled(login.busy).accessibilityIdentifier("chatgpt.connect")
            if login.signingIn {
                Button(ChatGPTMobileText.text("取消登录", "Cancel sign-in", "ログインをキャンセル")) { login.cancel() }
                    .accessibilityIdentifier("chatgpt.cancel")
            } else {
                Button(ChatGPTMobileText.text("添加账户或工作区", "Add account or workspace", "アカウントまたはワークスペースを追加")) { login.signIn(in: window, resumePending: false) }
                    .disabled(login.busy)
            }
            if let profile = selectedProfile, profile.signedIn {
                Text(profile.planEnabled ? "Using ChatGPT plan" : ChatGPTMobileText.text("尚未授权计划使用", "Plan usage is not authorized", "プラン利用は未許可です")).font(.subheadline)
                Link("Manage usage", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                if profile.planEnabled {
                    Picker(ChatGPTMobileText.text("ChatGPT 模型", "ChatGPT model", "ChatGPT モデル"), selection: Binding(get: { draft.chatGPTModel ?? "" }, set: { draft.chatGPTModel = $0.isEmpty ? nil : $0 })) {
                        if !login.catalog.contains(where: { $0.slug == draft.chatGPTModel }) {
                            Text(draft.chatGPTModel ?? ChatGPTMobileText.text("选择模型", "Choose model", "モデルを選択")).tag(draft.chatGPTModel ?? "")
                        }
                        ForEach(login.catalog) { Text($0.displayName).tag($0.slug) }
                    }.disabled(login.busy || login.catalogBusy).accessibilityIdentifier("chatgpt.model")
                    Button(ChatGPTMobileText.text("刷新可用模型", "Refresh available models", "利用可能なモデルを更新")) { Task { await login.refreshCatalog(profileID: profile.id) } }
                        .disabled(login.busy || login.catalogBusy)
                }
                Button(ChatGPTMobileText.text("退出这个账户", "Sign out of this account", "このアカウントからログアウト")) { login.signOut(profileID: profile.id) }.disabled(login.busy)
            }
            if login.busy || login.catalogBusy { ProgressView() }
            if let status = login.status { Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            Text(ChatGPTMobileText.text("凭据只保存在这台设备的钥匙串。选择模型后保存设置。", "Credentials stay in this device's Keychain. Save settings after choosing a model.", "認証情報はこの端末のキーチェーンに保存されます。モデルを選んだ後に設定を保存してください。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .background(ChatGPTMobileLoginAnchor { window = $0 }.frame(width: 0, height: 0))
        .task { await login.load() }
        .task(id: draft.chatGPTAccountID) { if let id = draft.chatGPTAccountID { await login.refreshCatalog(profileID: id) } }
        .onChange(of: login.newlyConnected) { _, profile in
            if let profile { draft.chatGPTAccountID = profile.id; draft.chatGPTModel = nil }
        }
        .sheet(item: $login.welcomeProfile) { _ in
            VStack(alignment: .leading, spacing: 20) {
                Text("You're using your ChatGPT plan").font(.title2.weight(.semibold))
                Text(ChatGPTMobileText.text("Morrow 中符合条件的 AI 请求将使用你的 ChatGPT 计划。你可以在 ChatGPT 设置中管理用量。", "Eligible AI requests in Morrow use your ChatGPT plan. Manage usage in ChatGPT settings.", "Morrow の対象 AI リクエストは ChatGPT プランを使用します。ChatGPT の設定で利用量を管理できます。"))
                Link("Manage usage", destination: URL(string: "https://chatgpt.com/settings/usage")!)
                Button("Got it") { Task { await login.dismissWelcome() } }.buttonStyle(.borderedProminent)
            }.padding(24).presentationDetents([.medium])
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background, login.signingIn { login.cancel() } }
        .onDisappear { if login.signingIn { login.cancel() }; login.changeAccount() }
    }
}
