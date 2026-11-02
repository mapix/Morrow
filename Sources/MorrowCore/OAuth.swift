import Foundation
import CryptoKit
import Security
import Network
#if canImport(AppKit)
import AppKit
#endif

public struct OAuthTokens: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date
    public var grantedScopes: String? = nil
}

public enum OAuthProvider {
    public static func endpoints(_ provider: String) -> (authorization: String, token: String, scope: String) {
        provider == "google" ? ("https://accounts.google.com/o/oauth2/v2/auth", "https://oauth2.googleapis.com/token", "openid email https://mail.google.com/") : ("https://login.microsoftonline.com/common/oauth2/v2.0/authorize", "https://login.microsoftonline.com/common/oauth2/v2.0/token", "offline_access https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send")
    }
    public static func googleEmail(accessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!); request.timeoutInterval = 20
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw MailError.message("Google 账户身份未能核验，请重新授权。") }
        struct Profile: Decodable { var email: String; var email_verified: Bool }
        let profile = try JSONDecoder().decode(Profile.self, from: data)
        guard profile.email_verified, MailAddress.isValid(profile.email) else { throw MailError.message("Google 尚未确认这个邮箱地址，未保存连接。") }
        return profile.email
    }
    public static func googleScopes(accessToken: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/tokeninfo")!); request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); request.httpBody = Data(form(["access_token": accessToken]).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        struct Info: Decodable { var scope: String }
        guard (response as? HTTPURLResponse)?.statusCode == 200, let info = try? JSONDecoder().decode(Info.self, from: data) else { throw MailError.message("Google 账户已登录，但尚未核验邮件授权范围；已保存授权，稍后可重试。") }
        return info.scope
    }
    public static func authorizationURL(_ account: MailAccount, redirect: String, state: String, verifier: String, forceConsent: Bool = true) throws -> URL {
        guard !account.oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MailError.message("Morrow 的浏览器登录尚未配置。") }
        let scope = endpoints(account.oauthProvider).scope + (account.usesPOP && account.oauthProvider == "microsoft" ? " https://outlook.office.com/POP.AccessAsUser.All" : "")
        var fields = ["client_id": account.oauthClientID.trimmingCharacters(in: .whitespacesAndNewlines), "response_type": "code", "redirect_uri": redirect, "scope": scope, "state": state, "code_challenge": challenge(verifier), "code_challenge_method": "S256"]
        if !account.email.isEmpty { fields["login_hint"] = account.email }
        if account.oauthProvider == "google" { fields["access_type"] = "offline"; if forceConsent { fields["prompt"] = "consent" } }
        guard let url = URL(string: endpoints(account.oauthProvider).authorization + "?" + form(fields)) else { throw MailError.message("无法准备浏览器授权地址。") }
        return url
    }
    public static func exchange(provider: String, fields: [String: String], previousRefresh: String? = nil) async throws -> OAuthTokens {
        var fields = fields
        #if !os(iOS)
        if provider == "google", let clientID = fields["client_id"], fields["client_secret"] == nil {
            let secret = try OAuthApplicationClients.clientSecret(provider: provider, clientID: clientID)
            if !secret.isEmpty { fields["client_secret"] = secret }
        }
        #endif
        var request = URLRequest(url: URL(string: endpoints(provider).token)!); request.httpMethod = "POST"; request.timeoutInterval = 45
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form(fields).utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            struct Failure: Decodable { var error: String; var error_description: String? }
            let failure = try? JSONDecoder().decode(Failure.self, from: data)
            let description = failure?.error_description ?? ""
            if description.contains("client_secret") { throw MailError.message("Google 已收到登录请求，但 Morrow 的应用凭据尚未配置完整（client_secret）。请更新应用连接配置后重试。") }
            throw MailError.message("兑换邮箱授权失败：" + (failure?.error ?? "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)") + (description.isEmpty ? "" : "，" + String(description.prefix(250))))
        }
        struct Response: Decodable { var access_token: String; var refresh_token: String?; var expires_in: Int; var scope: String? }
        let r = try JSONDecoder().decode(Response.self, from: data)
        return OAuthTokens(accessToken: r.access_token, refreshToken: r.refresh_token ?? previousRefresh, expiresAt: Date().addingTimeInterval(Double(r.expires_in)), grantedScopes: r.scope)
    }
    public static func form(_ fields: [String: String]) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return fields.sorted { $0.key < $1.key }.map { ($0.key.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.joined(separator: "&")
    }
    public static func verifier() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw MailError.message("无法生成安全授权随机数，请重试。") }
        return base64url(Data(bytes))
    }
    public static func challenge(_ verifier: String) -> String { base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    private static func base64url(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
}

public actor AccountCredentials {
    private var refreshes: [String: Task<String, Error>] = [:]
    private var pendingTokens: [String: (MailAccount, OAuthTokens)] = [:]
    private var revisions: [String: Int] = [:]
    public init() {}
    public func invalidate(_ accountID: String) {
        revisions[accountID, default: 0] += 1
        refreshes.removeValue(forKey: accountID)?.cancel(); pendingTokens[accountID] = nil
        SecretStore.invalidateMemory(accountID: accountID)
    }
    public func authorize(_ account: MailAccount) throws {
        if let pending = pendingTokens[account.id], pending.0 == account {
            try SecretStore.save(String(decoding: JSONEncoder().encode(pending.1), as: UTF8.self), accountID: account.id, allowInteraction: true)
            pendingTokens[account.id] = nil
        } else {
            _ = try SecretStore.read(accountID: account.id, allowInteraction: true, forceReload: true)
        }
    }
    public func credential(_ account: MailAccount) async throws -> String {
        if account.authMethod != "oauth" { return try SecretStore.read(accountID: account.id) }
        if let task = refreshes[account.id] { return try await task.value }
        if let pending = pendingTokens[account.id], pending.0 == account {
            try SecretStore.save(String(decoding: JSONEncoder().encode(pending.1), as: UTF8.self), accountID: account.id, allowInteraction: false)
            pendingTokens[account.id] = nil
        }
        let revision = revisions[account.id, default: 0]
        let task = Task<String, Error> {
            let secret = try SecretStore.read(accountID: account.id)
            let tokens = try JSONDecoder().decode(OAuthTokens.self, from: Data(secret.utf8))
            if tokens.expiresAt > Date().addingTimeInterval(90) { return tokens.accessToken }
            guard let refresh = tokens.refreshToken else { throw MailError.message("邮箱授权已到期，请在设置中重新登录。") }
            let updated = try await OAuthProvider.exchange(provider: account.oauthProvider, fields: ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": account.oauthClientID], previousRefresh: refresh)
            try Task.checkCancellation()
            guard revisions[account.id, default: 0] == revision else { throw CancellationError() }
            pendingTokens[account.id] = (account, updated)
            try SecretStore.save(String(decoding: JSONEncoder().encode(updated), as: UTF8.self), accountID: account.id, allowInteraction: false)
            pendingTokens[account.id] = nil
            return updated.accessToken
        }
        refreshes[account.id] = task
        do { let value = try await task.value; if revisions[account.id, default: 0] == revision { refreshes[account.id] = nil }; return value }
        catch { if revisions[account.id, default: 0] == revision { refreshes[account.id] = nil }; throw error }
    }
}

@MainActor public enum OAuthFlow {
    /// Loopback callback and PKCE for public desktop clients. Client IDs are caller-owned.
    public static func signIn(_ account: MailAccount, forceConsent: Bool = false, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> OAuthTokens {
        #if !os(macOS)
        throw MailError.message("当前桌面邮箱授权仅支持 Mac。移动端可连接 IMAP 授权码邮箱。")
        #else
        guard !account.oauthClientID.trimmingCharacters(in: .whitespaces).isEmpty else { throw MailError.message("请填写你注册的 OAuth 桌面客户端 ID。") }
        let verifier = try OAuthProvider.verifier(); let state = try OAuthProvider.verifier()
        let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        let gate = OAuthCallbackGate()
        let callback: (String, String) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
            gate.install(continuation)
            guard !Task.isCancelled else { gate.finish(.failure(CancellationError())); return }
            listener.stateUpdateHandler = { status in
                if case .ready = status, let port = listener.port {
                    let redirect = "http://127.0.0.1:\(port.rawValue)/oauth"
                    do { let url = try OAuthProvider.authorizationURL(account, redirect: redirect, state: state, verifier: verifier, forceConsent: forceConsent); DispatchQueue.main.async { NSWorkspace.shared.open(url) } }
                    catch { gate.finish(.failure(error)); listener.cancel() }
                } else if case .failed(let error) = status { gate.finish(.failure(error)); listener.cancel() }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: DispatchQueue.global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    guard let data, let request = String(data: data, encoding: .utf8), let target = request.components(separatedBy: " ").dropFirst().first,
                          let url = URLComponents(string: "http://127.0.0.1" + target), url.path == "/oauth" else { connection.cancel(); return }
                    let fields = Dictionary((url.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
                    guard fields["state"] == state else { connection.cancel(); return }
                    let success = fields["code"] != nil
                    let body = success ? "Mailbox authorization received. Return to Morrow." : "Authorization cancelled. Return to Morrow."
                    let response = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                    connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
                    if let code = fields["code"], let port = listener.port { gate.finish(.success((code, "http://127.0.0.1:\(port.rawValue)/oauth"))) }
                    else { gate.finish(.failure(MailError.message("邮箱登录已取消。"))) }
                    listener.cancel()
                }
            }
            listener.start(queue: DispatchQueue.global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 600) { if gate.finish(.failure(MailError.message("浏览器授权等待已超时，请重新发起连接。已授予的权限没有被撤销。"))) { listener.cancel() } }
            }
        } onCancel: { gate.finish(.failure(CancellationError())); listener.cancel() }
        try Task.checkCancellation()
        progress("已收到 " + (account.oauthProvider == "google" ? "Google" : "Microsoft") + " 授权，正在兑换访问凭据…")
        return try await OAuthProvider.exchange(provider: account.oauthProvider, fields: ["grant_type": "authorization_code", "code": callback.0, "client_id": account.oauthClientID, "redirect_uri": callback.1, "code_verifier": verifier])
        #endif
    }
}
private final class OAuthCallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(String, String), Error>?
    private var result: Result<(String, String), Error>?
    func install(_ value: CheckedContinuation<(String, String), Error>) {
        lock.lock()
        if let result { lock.unlock(); value.resume(with: result) }
        else { continuation = value; lock.unlock() }
    }
    @discardableResult func finish(_ value: Result<(String, String), Error>) -> Bool {
        lock.lock(); guard result == nil else { lock.unlock(); return false }
        result = value; let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: value); return true
    }
}
