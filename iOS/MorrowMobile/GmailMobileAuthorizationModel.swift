import Foundation
import SwiftUI
import UIKit
import Security
import MorrowCore

/// Created only after full Gmail scope, verified Google identity, and IMAP LIST succeed.
/// The caller commits this connection, then publishes the account in its native workspace.
struct GmailMobileConnection: Sendable {
    let account: MailAccount
    let folders: [MailFolder]
    private let tokens: OAuthTokens

    fileprivate init(account: MailAccount, folders: [MailFolder], tokens: OAuthTokens) {
        self.account = account; self.folders = folders; self.tokens = tokens
    }

    func commit(to store: MailStore) async throws {
        // Metadata commits together; a failure restores the former credential and retains the pending grant.
        let previous = try SecretStore.readOptional(accountID: account.id)
        let encoded = String(decoding: try JSONEncoder().encode(tokens), as: UTF8.self)
        try SecretStore.save(encoded, accountID: account.id)
        do { try await store.commitMailboxConnection(account, folders: folders) }
        catch {
            if let previous { try? SecretStore.save(previous, accountID: account.id) }
            else { SecretStore.delete(accountID: account.id) }
            throw error
        }
    }
}

@MainActor
final class GmailMobileAuthorizationModel: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var signingIn = false
    @Published private(set) var committing = false
    @Published private(set) var hasPendingGrant = false
    @Published private(set) var status: String?
    private var operation: Task<Void, Never>?
    private var presenter: GmailMobileAuthorizationPresenter?
    private var operationID = UUID()
    private let transport = MailTransport()

    func loadPending() {
        do {
            let client = try GmailMobileOAuthClient.load()
            hasPendingGrant = try GmailMobilePendingVault(client: client).load() != nil
        } catch {
            hasPendingGrant = false
            status = error.localizedDescription
        }
    }

    func signIn(in window: UIWindow?, emailHint: String = "", existingAccounts: [MailAccount], onConnect: @escaping @MainActor (GmailMobileConnection) async throws -> Void) {
        guard !busy else { return }
        do {
            let client = try GmailMobileOAuthClient.load()
            let browser = try GmailMobileAuthorizationPresenter(anchor: window)
            let attempt = GmailMobileOAuthAttempt(client: client, state: try OAuthProvider.verifier(), verifier: try OAuthProvider.verifier())
            var draft = MailAccount.preset(MailProvider.gmail.rawValue)
            draft.email = emailHint.trimmingCharacters(in: .whitespacesAndNewlines)
            draft.oauthClientID = client.clientID
            let url = try OAuthProvider.authorizationURL(draft, redirect: client.redirectURI, state: attempt.state, verifier: attempt.verifier, forceConsent: true)
            let identity = begin(signingIn: true)
            presenter = browser
            operation = Task {
                defer { finish(identity) }
                do {
                    status = GmailMobileText.text("在系统窗口选择 Google 账户，并允许 Gmail 邮件访问。", "Choose your Google account in the system window and allow Gmail access.", "システム画面で Google アカウントを選び、Gmail へのアクセスを許可してください。")
                    let code = try await browser.authorize(url: url, attempt: attempt)
                    try Task.checkCancellation()
                    guard operationID == identity else { return }
                    signingIn = false
                    status = GmailMobileText.text("正在验证 Google 授权…", "Verifying Google authorization…", "Google の認証を検証しています…")
                    let tokens: OAuthTokens
                    do {
                        tokens = try await OAuthProvider.exchange(provider: "google", fields: ["grant_type": "authorization_code", "code": code, "client_id": client.clientID, "redirect_uri": client.redirectURI, "code_verifier": attempt.verifier])
                    } catch is CancellationError { throw CancellationError() }
                    catch { throw GmailMobileAuthorizationError.authorizationFailed }
                    // Persist the grant before further network checks, even if cancellation arrived
                    // during exchange. Codes, PKCE verifier, and browser state are never persisted.
                    let pending = GmailMobilePendingGrant(account: draft, tokens: tokens, requestedEmail: draft.email)
                    try GmailMobilePendingVault(client: client).save(pending)
                    hasPendingGrant = true
                    try Task.checkCancellation()
                    guard operationID == identity else { return }
                    try await verify(pending, client: client, emailHint: draft.email, existingAccounts: existingAccounts, identity: identity, onConnect: onConnect)
                } catch is CancellationError {
                    if operationID == identity { status = GmailMobileAuthorizationError.cancelled.localizedDescription }
                } catch {
                    if operationID == identity { status = error.localizedDescription }
                }
            }
        } catch { status = error.localizedDescription }
    }

    func retry(emailHint: String = "", existingAccounts: [MailAccount], onConnect: @escaping @MainActor (GmailMobileConnection) async throws -> Void) {
        guard !busy else { return }
        do {
            let client = try GmailMobileOAuthClient.load()
            guard let pending = try GmailMobilePendingVault(client: client).load() else { throw GmailMobileAuthorizationError.noPendingGrant }
            let identity = begin(signingIn: false)
            operation = Task {
                defer { finish(identity) }
                do { try await verify(pending, client: client, emailHint: emailHint, existingAccounts: existingAccounts, identity: identity, onConnect: onConnect) }
                catch is CancellationError { if operationID == identity { status = GmailMobileAuthorizationError.cancelled.localizedDescription } }
                catch { if operationID == identity { status = error.localizedDescription } }
            }
        } catch { status = error.localizedDescription }
    }

    func cancel() {
        guard !committing else { return }
        operationID = UUID()
        operation?.cancel(); presenter?.cancel()
        operation = nil; presenter = nil; busy = false; signingIn = false
        status = GmailMobileAuthorizationError.cancelled.localizedDescription
    }

    private func begin(signingIn: Bool) -> UUID {
        let identity = UUID(); operationID = identity; busy = true; self.signingIn = signingIn; return identity
    }

    private func finish(_ identity: UUID) {
        guard operationID == identity else { return }
        presenter?.cancel(); presenter = nil; operation = nil
        busy = false; signingIn = false; committing = false
    }

    private func verify(_ saved: GmailMobilePendingGrant, client: GmailMobileOAuthClient, emailHint: String, existingAccounts: [MailAccount], identity: UUID, onConnect: @escaping @MainActor (GmailMobileConnection) async throws -> Void) async throws {
        var pending = saved
        let vault = GmailMobilePendingVault(client: client)
        try Task.checkCancellation()
        guard operationID == identity else { throw CancellationError() }
        if pending.tokens.expiresAt <= Date().addingTimeInterval(90) {
            guard let refresh = pending.tokens.refreshToken, !refresh.isEmpty else { throw GmailMobileAuthorizationError.pendingExpired }
            do {
                var updated = try await OAuthProvider.exchange(provider: "google", fields: ["grant_type": "refresh_token", "refresh_token": refresh, "client_id": client.clientID], previousRefresh: refresh)
                updated.grantedScopes = updated.grantedScopes ?? pending.tokens.grantedScopes
                pending.tokens = updated
                try vault.save(pending)
            } catch is CancellationError { throw CancellationError() }
            catch { throw GmailMobileAuthorizationError.pendingExpired }
        }
        try Task.checkCancellation()
        status = GmailMobileText.text("正在核验 Gmail 权限和邮箱身份…", "Checking Gmail permission and mailbox identity…", "Gmail の権限とメールの本人情報を確認しています…")
        if pending.tokens.grantedScopes == nil {
            do { pending.tokens.grantedScopes = try await OAuthProvider.googleScopes(accessToken: pending.tokens.accessToken) }
            catch is CancellationError { throw CancellationError() }
            catch { throw GmailMobileAuthorizationError.verificationFailed }
            try vault.save(pending)
        }
        guard GmailMobileOAuthAttempt.hasFullMailScope(pending.tokens.grantedScopes) else { throw GmailMobileAuthorizationError.missingMailScope }
        guard let refresh = pending.tokens.refreshToken, !refresh.isEmpty else { throw GmailMobileAuthorizationError.missingRefreshToken }
        let verifiedEmail: String
        do { verifiedEmail = try await OAuthProvider.googleEmail(accessToken: pending.tokens.accessToken) }
        catch is CancellationError { throw CancellationError() }
        catch { throw GmailMobileAuthorizationError.identityFailed }
        let requested = emailHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? pending.requestedEmail : emailHint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard requested.isEmpty || verifiedEmail.caseInsensitiveCompare(requested) == .orderedSame else { throw GmailMobileAuthorizationError.wrongAccount }
        var account = MailAccount.preset(MailProvider.gmail.rawValue)
        if let previous = existingAccounts.first(where: { !$0.isDemo && $0.authMethod == "oauth" && $0.oauthProvider == "google" && $0.email.caseInsensitiveCompare(verifiedEmail) == .orderedSame }) {
            account.id = previous.id; account.name = previous.name; account.signature = previous.signature; account.enabled = previous.enabled
        } else { account.id = pending.account.id }
        account.email = verifiedEmail
        account.oauthClientID = client.clientID
        pending.account = account
        try vault.save(pending)
        try Task.checkCancellation()
        guard operationID == identity else { throw CancellationError() }
        status = GmailMobileText.text("正在测试 Gmail 邮箱连接…", "Testing the Gmail mailbox connection…", "Gmail メールボックスの接続をテストしています…")
        let folders: [MailFolder]
        do { folders = try await transport.test(account, password: pending.tokens.accessToken) }
        catch is CancellationError { throw CancellationError() }
        catch { throw GmailMobileAuthorizationError.verificationFailed }
        try Task.checkCancellation()
        guard operationID == identity else { throw CancellationError() }
        committing = true
        status = GmailMobileText.text("正在保存已验证的 Gmail 连接…", "Saving the verified Gmail connection…", "検証済みの Gmail 接続を保存しています…")
        try await onConnect(GmailMobileConnection(account: account, folders: folders, tokens: pending.tokens))
        hasPendingGrant = !vault.clear()
        status = GmailMobileText.text("Gmail 已连接。", "Gmail connected.", "Gmail に接続しました。")
    }
}

private struct GmailMobilePendingGrant: Codable {
    var account: MailAccount
    var tokens: OAuthTokens
    var requestedEmail: String
}

/// Separate from accepted mailbox credentials, with no iCloud synchronization or backup migration.
private struct GmailMobilePendingVault {
    let client: GmailMobileOAuthClient
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.smail.mobile.gmail.pending", kSecAttrAccount as String: MailStore.hash(client.clientID), kSecAttrSynchronizable as String: false]
    }
    func save(_ pending: GmailMobilePendingGrant) throws {
        let data = try JSONEncoder().encode(pending)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var create = query; create[kSecValueData as String] = data; create[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(create as CFDictionary, nil)
            guard added == errSecSuccess else { throw GmailMobileAuthorizationError.secureStorageStatus(added) }
        } else if status != errSecSuccess { throw GmailMobileAuthorizationError.secureStorageStatus(status) }
    }
    func load() throws -> GmailMobilePendingGrant? {
        var lookup = query; lookup[kSecReturnData as String] = true; lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw GmailMobileAuthorizationError.secureStorageStatus(status) }
        guard status == errSecSuccess, let data = result as? Data,
              let value = try? JSONDecoder().decode(GmailMobilePendingGrant.self, from: data),
              value.account.oauthProvider == "google", value.account.authMethod == "oauth", value.account.oauthClientID == client.clientID else {
            throw GmailMobileAuthorizationError.secureStorage
        }
        return value
    }
    func clear() -> Bool {
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
