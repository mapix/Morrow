import Foundation
import SwiftUI
import MorrowCore
#if os(macOS)
import AppKit
#endif

@MainActor
final class ChatGPTLoginModel: ObservableObject {
    @Published var profiles: [ChatGPTProfile] = []
    @Published var catalog: [ChatGPTModel] = []
    @Published var busy = false
    @Published var signingIn = false
    @Published var status: String?
    @Published var newlyConnected: ChatGPTProfile?
    @Published var welcomeProfile: ChatGPTProfile?
    private var operation: Task<Void, Never>?
    private var loopback: ChatGPTLoopback?
    private var operationID = UUID()
    func load() async { profiles = await ChatGPTService.shared.savedProfiles() }
    func signIn(profileID: String? = nil, resumePending: Bool = true) {
        guard !busy else { return }
        #if os(macOS)
        let identity = UUID(); operationID = identity; busy = true; signingIn = true; status = L10n.t("正在准备 ChatGPT 登录…"); newlyConnected = nil
        operation = Task {
            defer { if operationID == identity { busy = false; signingIn = false; loopback = nil; operation = nil } }
            do {
                let profiles = await ChatGPTService.shared.savedProfiles(); let previous = profiles.first { $0.id == profileID }
                var retained: String?
                if let previous { retained = try await ChatGPTService.shared.retainedIDToken(profileID: previous.id) }
                let host = await ChatGPTService.shared.hostID()
                var pending = previous?.clientID
                if pending == nil, profileID == nil, resumePending { pending = await ChatGPTService.shared.pendingClientID() }
                if profileID == nil, !resumePending { await ChatGPTService.shared.clearPendingClient() }
                let server = try ChatGPTLoopback(); loopback = server
                let attempt = try await server.prepare(hostID: host, previousClientID: pending)
                try Task.checkCancellation(); guard operationID == identity else { server.cancel(); return }
                let url = try attempt.authorizationURL(previousIDToken: retained, email: previous?.email)
                guard NSWorkspace.shared.open(url) else { server.cancel(); throw ChatGPTServiceError("browser_open_failed") }
                status = L10n.t("在浏览器完成登录并允许 Morrow 使用 ChatGPT 计划。")
                let (code, clientID) = try await server.wait()
                status = L10n.t("已收到授权，正在验证 ChatGPT 身份…")
                let profile = try await ChatGPTService.shared.finishSignIn(attempt: attempt, code: code, clientID: clientID, expectedProfileID: previous?.id)
                try Task.checkCancellation(); guard operationID == identity else { return }
                await load(); newlyConnected = profile
                status = profile.planEnabled ? L10n.t("已登录；选择模型并保存后使用 ChatGPT 计划。") : L10n.t("已登录，但未授予 ChatGPT 计划使用权限。")
                if profile.planEnabled, !profile.welcomed { welcomeProfile = profile }
                if profile.planEnabled { await refreshCatalog(profileID: profile.id) }
            } catch is CancellationError { if operationID == identity { status = L10n.t("ChatGPT 登录已取消。") } }
            catch { if operationID == identity { status = error.localizedDescription } }
        }
        #else
        status = ChatGPTServiceError("native_callback_unavailable").localizedDescription
        #endif
    }
    func cancel() { operationID = UUID(); operation?.cancel(); loopback?.cancel(); loopback = nil; operation = nil; busy = false; signingIn = false; status = L10n.t("ChatGPT 登录已取消。") }
    func refreshCatalog(profileID: String) async {
        let identity = operationID
        do { let values = try await ChatGPTPlanClient.shared.models(profileID: profileID); guard operationID == identity else { return }; catalog = values }
        catch { if operationID == identity { catalog = []; status = error.localizedDescription } }
    }
    func changeAccount() { catalog = []; operationID = UUID() }
    func signOut(profileID: String) {
        guard !busy else { return }; busy = true; catalog = []
        operation = Task { defer { busy = false; operation = nil }; do { let revoked = try await ChatGPTService.shared.signOut(profileID: profileID); await load(); status = revoked ? L10n.t("已退出这个 ChatGPT 账户。") : L10n.t("本机凭据已清除；远程撤销未确认，可在 ChatGPT 设置中断开 Morrow。") } catch { status = error.localizedDescription } }
    }
    func dismissWelcome() async { if let profile = welcomeProfile { try? await ChatGPTService.shared.markWelcomed(profileID: profile.id) }; welcomeProfile = nil; await load() }
}
