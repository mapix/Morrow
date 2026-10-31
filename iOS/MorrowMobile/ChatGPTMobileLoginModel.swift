import SwiftUI
import UIKit
import MorrowCore

@MainActor
final class ChatGPTMobileLoginModel: ObservableObject {
    @Published var profiles: [ChatGPTProfile] = []
    @Published var catalog: [ChatGPTModel] = []
    @Published var busy = false
    @Published var signingIn = false
    @Published var catalogBusy = false
    @Published var status: String?
    @Published var newlyConnected: ChatGPTProfile?
    @Published var welcomeProfile: ChatGPTProfile?
    private var operation: Task<Void, Never>?
    private var loopback: ChatGPTLoopback?
    private var presenter: ChatGPTMobileLoginPresenter?
    private var operationID = UUID()
    private var catalogID = UUID()

    func load() async { profiles = await ChatGPTService.shared.savedProfiles() }

    func signIn(in window: UIWindow?, profileID: String? = nil, resumePending: Bool = true) {
        guard !busy else { return }
        do { presenter = try ChatGPTMobileLoginPresenter(anchor: window) }
        catch { status = error.localizedDescription; return }
        let identity = UUID()
        operationID = identity
        busy = true
        signingIn = true
        newlyConnected = nil
        status = ChatGPTMobileText.text("正在准备 ChatGPT 登录…", "Preparing ChatGPT sign-in…", "ChatGPT ログインを準備しています…")
        operation = Task {
            defer {
                if operationID == identity {
                    presenter?.cancel()
                    loopback?.cancel()
                    presenter = nil
                    loopback = nil
                    operation = nil
                    busy = false
                    signingIn = false
                }
            }
            do {
                let saved = await ChatGPTService.shared.savedProfiles()
                let previous = saved.first { $0.id == profileID }
                if profileID != nil, previous == nil { throw ChatGPTServiceError("not_signed_in") }
                var retained: String?
                if let previous { retained = try await ChatGPTService.shared.retainedIDToken(profileID: previous.id) }
                let host = await ChatGPTService.shared.hostID()
                var pending = previous?.clientID
                if pending == nil, profileID == nil, resumePending { pending = await ChatGPTService.shared.pendingClientID() }
                if profileID == nil, !resumePending { await ChatGPTService.shared.clearPendingClient() }
                try Task.checkCancellation()
                guard operationID == identity else { return }
                let server = try ChatGPTLoopback()
                loopback = server
                let attempt = try await server.prepare(hostID: host, previousClientID: pending)
                try Task.checkCancellation()
                guard operationID == identity, let presenter else { server.cancel(); return }
                let url = try attempt.authorizationURL(previousIDToken: retained, email: previous?.email)
                try presenter.start(url: url) { [weak server] in server?.cancel() }
                status = ChatGPTMobileText.text("在系统窗口完成登录，并选择是否允许 Morrow 使用 ChatGPT 计划。", "Complete sign-in in the system window and choose whether Morrow may use your ChatGPT plan.", "システム画面でログインし、Morrow に ChatGPT プランの利用を許可するか選択してください。")
                let (code, clientID) = try await server.wait()
                try Task.checkCancellation()
                guard operationID == identity else { return }
                presenter.cancel()
                status = ChatGPTMobileText.text("已收到授权，正在验证 ChatGPT 身份…", "Authorization received. Verifying ChatGPT identity…", "認証を受け取りました。ChatGPT の本人情報を検証しています…")
                let profile = try await ChatGPTService.shared.finishSignIn(attempt: attempt, code: code, clientID: clientID, expectedProfileID: previous?.id)
                try Task.checkCancellation()
                guard operationID == identity else { return }
                await load()
                newlyConnected = profile
                status = profile.planEnabled
                    ? ChatGPTMobileText.text("已登录；选择模型并保存后使用 ChatGPT 计划。", "Signed in. Choose a model and save to use your ChatGPT plan.", "ログインしました。モデルを選んで保存すると ChatGPT プランを利用できます。")
                    : ChatGPTMobileText.text("已登录，但未授予 ChatGPT 计划使用权限。", "Signed in without permission to use the ChatGPT plan.", "ログインしましたが、ChatGPT プランの利用は許可されていません。")
                if profile.planEnabled, !profile.welcomed { welcomeProfile = profile }
                if profile.planEnabled { await refreshCatalog(profileID: profile.id) }
            } catch is CancellationError {
                if operationID == identity { status = presenter?.failure?.localizedDescription ?? ChatGPTMobilePresentationError.cancelled.localizedDescription }
            } catch {
                if operationID == identity { status = error.localizedDescription }
            }
        }
    }

    func cancel() {
        operationID = UUID()
        operation?.cancel()
        loopback?.cancel()
        presenter?.cancel()
        loopback = nil
        presenter = nil
        operation = nil
        busy = false
        signingIn = false
        status = ChatGPTMobilePresentationError.cancelled.localizedDescription
    }

    func changeAccount() { catalogID = UUID(); catalog = []; catalogBusy = false }

    func refreshCatalog(profileID: String) async {
        let identity = UUID()
        catalogID = identity
        catalog = []
        catalogBusy = true
        defer { if catalogID == identity { catalogBusy = false } }
        do {
            let values = try await ChatGPTPlanClient.shared.models(profileID: profileID)
            try Task.checkCancellation()
            let current = await ChatGPTService.shared.savedProfiles()
            guard catalogID == identity,
                  current.contains(where: { $0.id == profileID && $0.signedIn && $0.planEnabled }) else { return }
            profiles = current
            catalog = values
        } catch is CancellationError { }
        catch { if catalogID == identity { status = error.localizedDescription; await load() } }
    }

    func signOut(profileID: String) {
        guard !busy else { return }
        changeAccount()
        let identity = UUID()
        operationID = identity
        busy = true
        operation = Task {
            defer { if operationID == identity { busy = false; operation = nil } }
            do {
                let revoked = try await ChatGPTService.shared.signOut(profileID: profileID)
                guard operationID == identity else { return }
                await load()
                status = revoked
                    ? ChatGPTMobileText.text("已退出这个 ChatGPT 账户。", "Signed out of this ChatGPT account.", "この ChatGPT アカウントからログアウトしました。")
                    : ChatGPTMobileText.text("本机凭据已清除；远程撤销未确认，可在 ChatGPT 设置中断开 Morrow。", "Local credentials cleared. Remote revocation was not confirmed; disconnect Morrow in ChatGPT settings.", "端末の認証情報を削除しました。遠隔での失効は未確認です。ChatGPT の設定で Morrow を解除できます。")
            } catch { if operationID == identity { status = error.localizedDescription } }
        }
    }

    func dismissWelcome() async {
        if let profile = welcomeProfile { try? await ChatGPTService.shared.markWelcomed(profileID: profile.id) }
        welcomeProfile = nil
        await load()
    }
}
