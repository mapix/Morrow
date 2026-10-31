import Foundation
import MorrowCore

extension AppModel {
    func importOAuthApplicationSecret() throws {
        let url = store.root.appendingPathComponent("oauth-application-import.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        struct Import: Decodable { var provider: String; var clientID: String; var clientSecret: String }
        let value = try JSONDecoder().decode(Import.self, from: Data(contentsOf: url))
        guard value.clientID == OAuthApplicationClients.clientID(provider: value.provider), !value.clientSecret.isEmpty else { throw MailError.message("应用授权配置与当前客户端不一致。") }
        try SecretStore.save(value.clientSecret, accountID: OAuthApplicationClients.secretAccountID(provider: value.provider, clientID: value.clientID))
        try FileManager.default.removeItem(at: url)
    }
    func connectionDraft(_ suggestion: String) -> MailAccount {
        var account = MailProvider.connectionDraft(suggestion)
        if account.authMethod == "oauth" { account.oauthClientID = OAuthApplicationClients.clientID(provider: account.oauthProvider) }
        return account
    }
    func requestMailboxConnection(_ suggestion: String) async throws -> String {
        suggestedAccount = suggestion
        let account = connectionDraft(suggestion)
        if account.authMethod == "oauth" && !account.oauthClientID.isEmpty && (account.oauthProvider == "google" || MailAddress.isValid(account.email)) {
            try await connectOAuthAccount(account)
            return "已通过浏览器授权连接" + account.name + "，正在同步邮件。"
        }
        showAccount = true
        return account.authMethod == "oauth" ? "已选择" + account.name + "浏览器登录。请在连接页继续授权。" : "已打开邮箱连接页，提供商为" + account.name + "。"
    }
    func connectOAuthAccount(_ draft: MailAccount) async throws {
        var account = draft
        guard !account.oauthClientID.isEmpty else { throw MailError.message("Morrow 的浏览器登录尚未配置，请在连接选项中添加应用客户端 ID。") }
        mailboxConnectionStatus = "正在浏览器中等待 " + account.name + " 授权…"
        defer { mailboxConnectionStatus = nil }
        let update: @Sendable (String) -> Void = { [weak self] text in Task { @MainActor in self?.mailboxConnectionStatus = text } }
        let pendingKey = "pending-oauth:" + account.oauthProvider + ":" + MailStore.hash(account.email.lowercased() + account.oauthClientID)
        let previous = (try? SecretStore.read(accountID: pendingKey)).flatMap { try? JSONDecoder().decode(OAuthTokens.self, from: Data($0.utf8)) }
        var tokens: OAuthTokens
        if let previous, previous.expiresAt > Date().addingTimeInterval(60), account.oauthProvider != "google" || previous.grantedScopes == nil || previous.grantedScopes?.contains("https://mail.google.com/") == true {
            tokens = previous; mailboxConnectionStatus = "复用已完成的 Google 授权，正在重试邮件连接…"
        } else { tokens = try await OAuthFlow.signIn(account, forceConsent: previous != nil, progress: update) }
        if account.oauthProvider == "google" && tokens.refreshToken == nil {
            mailboxConnectionStatus = "正在请求长期访问授权…"
            tokens = try await OAuthFlow.signIn(account, forceConsent: true, progress: update)
        }
        try Task.checkCancellation()
        mailboxConnectionStatus = "正在核验邮箱身份…"
        if account.oauthProvider == "google" {
            let verified = try await OAuthProvider.googleEmail(accessToken: tokens.accessToken)
            if !account.email.isEmpty && verified.caseInsensitiveCompare(account.email) != .orderedSame { throw MailError.message("浏览器授权的 Google 账户与要求连接的邮箱不同，未保存连接。请在 Google 授权页选择所需账户。") }
            account.email = verified
            try SecretStore.save(String(decoding: JSONEncoder().encode(tokens), as: UTF8.self), accountID: pendingKey)
            if tokens.grantedScopes == nil { tokens.grantedScopes = try await OAuthProvider.googleScopes(accessToken: tokens.accessToken) }
        }
        try SecretStore.save(String(decoding: JSONEncoder().encode(tokens), as: UTF8.self), accountID: pendingKey)
        await log("Google 授权已完成", detail: "授权范围：" + (tokens.grantedScopes ?? "未提供"), kind: "account-authorization")
        if account.oauthProvider == "google", tokens.grantedScopes?.contains("https://mail.google.com/") != true { throw MailError.message("Google 登录已完成，但未授予 Gmail 邮件权限。请在 Google 授权页勾选完整邮件访问后重试。") }
        try account.validate()
        mailboxConnectionStatus = "授权已完成，正在验证邮箱连接…"
        do { try await addAccount(account, password: tokens.accessToken, storedSecret: String(decoding: JSONEncoder().encode(tokens), as: UTF8.self)) }
        catch {
            if account.oauthProvider == "google" {
                do {
                    _ = try await transport.request(url: "imaps://imap.gmail.com:993", username: account.email, password: tokens.accessToken, command: "CAPABILITY", oauth: true)
                    await log("Gmail 连接诊断", detail: "相同已授权凭据的libcurl认证成功；原生IMAP认证尚未完成。", kind: "account-diagnostic")
                } catch { await log("Gmail 连接诊断", detail: "libcurl与原生IMAP均未完成认证；授权范围：" + (tokens.grantedScopes ?? "未提供"), kind: "account-diagnostic") }
            }
            throw error
        }
        SecretStore.delete(accountID: pendingKey)
    }
    func isMailboxConnectionRequest(_ text: String) -> Bool {
        guard !["不要连接", "不用连接", "先不连接", "别连接", "不要登录", "不要登陆", "别添加", "解释", "为什么", "如何", "怎么", "断开", "移除"].contains(where: text.contains) else { return false }
        let direct = ["连接", "接入", "登录", "登陆", "connect", "sign in"].contains(where: text.lowercased().contains)
        let add = text.contains("添加") && (text.contains("邮箱") || text.contains("邮件账户"))
        return (direct || add) && MailProvider.infer(text) != nil
    }
}
