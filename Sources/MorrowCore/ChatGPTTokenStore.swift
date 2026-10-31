import Foundation
import Security

/// Authentication and inference never follow redirects that could replay credentials elsewhere.
public enum ChatGPTNetwork {
    public static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: ChatGPTNoRedirects(), delegateQueue: nil)
    }()
}
private final class ChatGPTNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public protocol ChatGPTCredentialStorage: Sendable {
    func read(profileID: String) throws -> ChatGPTCredentials?
    func save(_ credentials: ChatGPTCredentials, profileID: String) throws
    func delete(profileID: String) throws
}
public struct ChatGPTKeychain: ChatGPTCredentialStorage {
    public init() {}
    private func query(_ id: String) -> [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.smail.chatgpt.oauth", kSecAttrAccount as String: id, kSecAttrSynchronizable as String: false] }
    public func read(profileID: String) throws -> ChatGPTCredentials? {
        var q = query(profileID); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?; let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw ChatGPTServiceError("credential_read_failed") }
        return try JSONDecoder().decode(ChatGPTCredentials.self, from: data)
    }
    public func save(_ credentials: ChatGPTCredentials, profileID: String) throws {
        let data = try JSONEncoder().encode(credentials), q = query(profileID)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound { var add = q; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly; guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw ChatGPTServiceError("credential_save_failed") } }
        else if status != errSecSuccess { throw ChatGPTServiceError("credential_save_failed") }
    }
    public func delete(profileID: String) throws { let status = SecItemDelete(query(profileID) as CFDictionary); guard status == errSecSuccess || status == errSecItemNotFound else { throw ChatGPTServiceError("credential_delete_failed") } }
}

/// Serializes rotating refresh tokens. Account revisions prevent a late request from restoring a signed-out account.
public actor ChatGPTService {
    public static let shared = ChatGPTService()
    private let defaults: UserDefaults
    private let vault: any ChatGPTCredentialStorage
    private let session: URLSession
    private var profiles: [ChatGPTProfile]
    private var epochs: [String: UUID] = [:]
    private var refreshes: [String: (UUID, Task<ChatGPTCredentials, Error>)] = [:]
    private let profilesKey = "Smail.ChatGPT.profiles.v1"
    public init(defaults: UserDefaults = .standard, vault: any ChatGPTCredentialStorage = ChatGPTKeychain(), session: URLSession = ChatGPTNetwork.session) {
        self.defaults = defaults; self.vault = vault; self.session = session
        self.profiles = defaults.data(forKey: "Smail.ChatGPT.profiles.v1").flatMap { try? JSONDecoder().decode([ChatGPTProfile].self, from: $0) } ?? []
    }
    public func hostID() -> String { if let value = defaults.string(forKey: "Smail.ChatGPT.host.v1") { return value }; let value = "urn:uuid:" + UUID().uuidString.lowercased(); defaults.set(value, forKey: "Smail.ChatGPT.host.v1"); return value }
    public func savedProfiles() -> [ChatGPTProfile] { profiles }
    public func retainedIDToken(profileID: String) throws -> String? { try vault.read(profileID: profileID)?.idToken }
    public func pendingClientID() -> String? { defaults.string(forKey: "Smail.ChatGPT.pendingClient.v1") }
    public func clearPendingClient() { defaults.removeObject(forKey: "Smail.ChatGPT.pendingClient.v1") }
    public func markWelcomed(profileID: String) throws { if let i = profiles.firstIndex(where: { $0.id == profileID }) { profiles[i].welcomed = true; try persist() } }
    public func finishSignIn(attempt: ChatGPTAuthorizationAttempt, code: String, clientID: String, expectedProfileID: String?) async throws -> ChatGPTProfile {
        guard clientID != "dynamic_agent_client", attempt.previousClientID == nil || attempt.previousClientID == clientID else { throw ChatGPTServiceError("callback_invalid") }
        // Retain the issued registration even if a code has expired. It is never a credential.
        if expectedProfileID == nil { defaults.set(clientID, forKey: "Smail.ChatGPT.pendingClient.v1") }
        let epoch = expectedProfileID.map { epochFor($0) }
        let tokenData = try await tokenRequest(["grant_type": "authorization_code", "client_id": clientID, "code": code, "code_verifier": attempt.verifier, "redirect_uri": attempt.redirectURI, "resource": "https://api.openai.com/v1"])
        try Task.checkCancellation()
        let discovery = try await ChatGPTDiscovery.load(session: session)
        let (jwks, response) = try await session.data(from: URL(string: discovery.jwksURI)!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ChatGPTServiceError("identity_invalid") }
        let object = try tokenObject(tokenData)
        guard let idToken = object["id_token"] as? String else { throw ChatGPTServiceError("identity_invalid") }
        let identity = try ChatGPTIdentityVerifier.verify(idToken, clientID: clientID, nonce: attempt.nonce, jwks: jwks)
        let credentials = try makeCredentials(object, clientID: clientID, subject: identity.subject, previous: nil)
        var profile = ChatGPTProfile(identity: identity, clientID: clientID, planEnabled: credentials.planEnabled)
        if let expectedProfileID { guard profile.id == expectedProfileID, epochs[expectedProfileID] == epoch else { throw ChatGPTServiceError("identity_invalid") } }
        try Task.checkCancellation()
        if let old = profiles.first(where: { $0.id == profile.id }) { profile.welcomed = old.welcomed }
        try vault.save(credentials, profileID: profile.id)
        profiles.removeAll { $0.id == profile.id }; profiles.append(profile); try persist(); clearPendingClient(); return profile
    }
    public func credentials(profileID: String, requirePlan: Bool = true) async throws -> ChatGPTCredentials {
        guard let profile = profiles.first(where: { $0.id == profileID }), profile.signedIn, let credentials = try vault.read(profileID: profileID), credentials.clientID == profile.clientID, credentials.subject == profile.subject else { throw ChatGPTServiceError("not_signed_in") }
        if requirePlan && !credentials.planEnabled { throw ChatGPTServiceError("plan_permission_missing") }
        if credentials.expiresAt > Date().addingTimeInterval(90) { return credentials }
        if let earliest = credentials.earliestRefreshAt, earliest > Date(), credentials.expiresAt > Date() { return credentials }
        if let pending = refreshes[profileID] { let value = try await pending.1.value; guard epochs[profileID] == pending.0 else { throw ChatGPTServiceError("signed_out") }; if requirePlan && !value.planEnabled { throw ChatGPTServiceError("plan_permission_missing") }; return value }
        let epoch = epochFor(profileID)
        let task = Task<ChatGPTCredentials, Error> { try await self.refresh(credentials, profileID: profileID, epoch: epoch) }
        refreshes[profileID] = (epoch, task)
        do { let value = try await task.value; if refreshes[profileID]?.0 == epoch { refreshes[profileID] = nil }; guard epochs[profileID] == epoch else { throw ChatGPTServiceError("signed_out") }; if requirePlan && !value.planEnabled { throw ChatGPTServiceError("plan_permission_missing") }; return value }
        catch { if refreshes[profileID]?.0 == epoch { refreshes[profileID] = nil }; throw error }
    }
    private func refresh(_ previous: ChatGPTCredentials, profileID: String, epoch: UUID) async throws -> ChatGPTCredentials {
        guard let refresh = previous.refreshToken else { throw ChatGPTServiceError("invalid_grant") }
        do {
            let data = try await tokenRequest(["grant_type": "refresh_token", "client_id": previous.clientID, "refresh_token": refresh, "resource": "https://api.openai.com/v1"])
            let object = try tokenObject(data)
            if let idToken = object["id_token"] as? String {
                let discovery = try await ChatGPTDiscovery.load(session: session); let (jwks, response) = try await session.data(from: URL(string: discovery.jwksURI)!)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ChatGPTServiceError("identity_invalid") }
                let identity = try ChatGPTIdentityVerifier.verify(idToken, clientID: previous.clientID, nonce: nil, jwks: jwks)
                guard identity.subject == previous.subject else { throw ChatGPTServiceError("identity_invalid") }
            }
            let next = try makeCredentials(object, clientID: previous.clientID, subject: previous.subject, previous: previous)
            try Task.checkCancellation(); guard epochs[profileID] == epoch else { throw ChatGPTServiceError("signed_out") }
            try vault.save(next, profileID: profileID)
            if let i = profiles.firstIndex(where: { $0.id == profileID }) { profiles[i].planEnabled = next.planEnabled; profiles[i].updatedAt = Date(); try persist() }
            return next
        } catch let failure as ChatGPTServiceError {
            if ["invalid_grant", "refresh_token_reused", "token_expired", "invalid_token"].contains(failure.code), epochs[profileID] == epoch {
                try vault.delete(profileID: profileID); if let i = profiles.firstIndex(where: { $0.id == profileID }) { profiles[i].signedIn = false; profiles[i].planEnabled = false; try persist() }
            }; throw failure
        }
    }
    public func signOut(profileID: String) async throws -> Bool {
        epochs[profileID] = UUID(); refreshes[profileID]?.1.cancel(); refreshes[profileID] = nil
        await ChatGPTPlanClient.shared.cancel(profileID: profileID)
        let tokens = try vault.read(profileID: profileID)
        try vault.delete(profileID: profileID)
        if let i = profiles.firstIndex(where: { $0.id == profileID }) { profiles[i].signedIn = false; profiles[i].planEnabled = false; profiles[i].updatedAt = Date(); try persist() }
        guard let tokens else { return true }
        do {
            let discovery = try await ChatGPTDiscovery.load(session: session)
            guard let endpoint = discovery.revocationEndpoint, let url = URL(string: endpoint), url.scheme == "https", url.host == "auth.openai.com", url.user == nil, url.password == nil else { return false }
            var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 20; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.form(["token": tokens.refreshToken ?? tokens.accessToken, "token_type_hint": tokens.refreshToken == nil ? "access_token" : "refresh_token", "client_id": tokens.clientID])
            let (_, response) = try await session.data(for: request); return (response as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }
    private func epochFor(_ id: String) -> UUID { if let value = epochs[id] { return value }; let value = UUID(); epochs[id] = value; return value }
    private func persist() throws { defaults.set(try JSONEncoder().encode(profiles), forKey: profilesKey) }
    private func tokenRequest(_ fields: [String: String]) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/api/accounts/oauth/token")!); request.httpMethod = "POST"; request.timeoutInterval = 30; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type"); request.setValue("application/json", forHTTPHeaderField: "Accept"); request.httpBody = Self.form(fields)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ChatGPTServiceError("token_exchange_failed") }; guard http.statusCode == 200 else { throw ChatGPTServiceError.http(data, response: http) }; return data
    }
    private func tokenObject(_ data: Data) throws -> [String: Any] { guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ChatGPTServiceError("token_exchange_failed") }; return value }
    private func makeCredentials(_ object: [String: Any], clientID: String, subject: String, previous: ChatGPTCredentials?) throws -> ChatGPTCredentials {
        guard let token = object["access_token"] as? String, !token.isEmpty, let expiry = object["expires_in"] as? NSNumber, expiry.doubleValue > 0, (object["token_type"] as? String)?.lowercased() == "bearer" else { throw ChatGPTServiceError("token_exchange_failed") }
        let refresh = object["refresh_token"] as? String
        if previous?.refreshToken != nil && (refresh?.isEmpty ?? true) { throw ChatGPTServiceError("refresh_rotation_missing") }
        guard let idToken = object["id_token"] as? String ?? previous?.idToken else { throw ChatGPTServiceError("identity_invalid") }
        let scopes = (object["scope"] as? String).map { $0.split(separator: " ").map(String.init) } ?? previous?.scopes ?? []
        let earliest = (object["earliest_refresh_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return ChatGPTCredentials(clientID: clientID, subject: subject, accessToken: token, refreshToken: refresh, idToken: idToken, scopes: scopes, expiresAt: Date().addingTimeInterval(expiry.doubleValue), earliestRefreshAt: earliest, revision: UUID().uuidString)
    }
    public static func form(_ fields: [String: String]) -> Data { var components = URLComponents(); components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }; return Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8) }
}
