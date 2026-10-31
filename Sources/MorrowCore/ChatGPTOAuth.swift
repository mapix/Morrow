import Foundation
import CryptoKit
import Security
import Network

public enum ChatGPTCrypto {
    public static func base64URL(_ data: Data) -> String { data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    public static func decode(_ string: String) -> Data? { let base = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/"); return Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4)) }
    public static func digest(_ value: String) -> String { base64URL(Data(SHA256.hash(data: Data(value.utf8)))) }
    public static func random(_ bytes: Int = 32) throws -> String { var buffer = [UInt8](repeating: 0, count: bytes); guard SecRandomCopyBytes(kSecRandomDefault, bytes, &buffer) == errSecSuccess else { throw ChatGPTServiceError("random_failed") }; return base64URL(Data(buffer)) }
    public static func constantTimeEqual(_ a: String, _ b: String) -> Bool { let x = Array(a.utf8), y = Array(b.utf8); guard x.count == y.count else { return false }; var diff: UInt8 = 0; for i in x.indices { diff |= x[i] ^ y[i] }; return diff == 0 }
}
public struct ChatGPTAuthorizationAttempt: Sendable {
    public let state: String
    public let nonce: String
    public let verifier: String
    public let hostID: String
    public let redirectURI: String
    public let previousClientID: String?
    public let expiresAt: Date
    public init(hostID: String, redirectURI: String, previousClientID: String? = nil) throws {
        guard let uri = URL(string: redirectURI), uri.scheme == "http", uri.host == "127.0.0.1", uri.path == "/auth/callback", uri.query == nil, uri.fragment == nil, uri.user == nil, uri.password == nil else { throw ChatGPTServiceError("callback_invalid") }
        self.state = try ChatGPTCrypto.random(); self.nonce = try ChatGPTCrypto.random(); self.verifier = try ChatGPTCrypto.random(64)
        self.hostID = hostID; self.redirectURI = redirectURI; self.previousClientID = previousClientID; self.expiresAt = Date().addingTimeInterval(600)
    }
    public func authorizationURL(previousIDToken: String? = nil, email: String? = nil) throws -> URL {
        var components = URLComponents(string: "https://auth.openai.com/api/accounts/authorize")!
        var fields = ["client_id": previousClientID ?? "dynamic_agent_client", "ext_agent_host_id": hostID, "response_type": "code", "redirect_uri": redirectURI, "scope": "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct", "resource": "https://api.openai.com/v1", "state": state, "nonce": nonce, "code_challenge_method": "S256", "code_challenge": ChatGPTCrypto.digest(verifier)]
        if previousClientID == nil { fields["agent_name_hint"] = "Morrow" }
        else { if let previousIDToken { fields["id_token_hint"] = previousIDToken }; if let email { fields["login_hint"] = email } }
        components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }; return components.url!
    }
    public func consumeCallback(_ url: URL, now: Date = Date()) throws -> (code: String, clientID: String) {
        guard now < expiresAt, let parsed = URLComponents(url: url, resolvingAgainstBaseURL: false), let expected = URLComponents(string: redirectURI), parsed.scheme == expected.scheme, parsed.host == expected.host, parsed.port == expected.port, parsed.path == expected.path else { throw ChatGPTServiceError("callback_invalid") }
        let items = parsed.queryItems ?? []; var fields: [String: String] = [:]
        for item in items { if fields[item.name] != nil { throw ChatGPTServiceError("callback_invalid") }; fields[item.name] = item.value ?? "" }
        guard let returned = fields["state"], ChatGPTCrypto.constantTimeEqual(returned, state) else { throw ChatGPTServiceError("callback_invalid") }
        if fields["error"] != nil { throw ChatGPTServiceError(fields["error"] == "access_denied" ? "access_denied" : "callback_invalid") }
        guard let code = fields["code"], !code.isEmpty else { throw ChatGPTServiceError("callback_invalid") }
        let issued: String
        if let previousClientID { if let value = fields["client_id"], value != previousClientID { throw ChatGPTServiceError("callback_invalid") }; issued = previousClientID }
        else { guard let value = fields["client_id"], !value.isEmpty, value != "dynamic_agent_client" else { throw ChatGPTServiceError("callback_invalid") }; issued = value }
        return (code, issued)
    }
}
public struct ChatGPTDiscovery: Decodable, Sendable {
    public var issuer: String
    public var jwksURI: String
    public var revocationEndpoint: String?
    enum CodingKeys: String, CodingKey { case issuer, jwksURI = "jwks_uri", revocationEndpoint = "revocation_endpoint" }
    public static func load(session: URLSession = ChatGPTNetwork.session) async throws -> ChatGPTDiscovery {
        let (data, response) = try await session.data(from: URL(string: "https://auth.openai.com/.well-known/openid-configuration")!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ChatGPTServiceError("discovery_failed") }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.issuer == "https://auth.openai.com", let keys = URL(string: value.jwksURI), keys.scheme == "https", keys.host == "auth.openai.com", keys.user == nil, keys.password == nil else { throw ChatGPTServiceError("identity_invalid") }
        return value
    }
}
/// OpenAI currently publishes RS256 signing keys. Rejects unadvertised algorithms and embedded keys.
public enum ChatGPTIdentityVerifier {
    public static func verify(_ token: String, clientID: String, nonce: String?, jwks: Data, now: Date = Date()) throws -> ChatGPTVerifiedIdentity {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerData = ChatGPTCrypto.decode(parts[0]), let payloadData = ChatGPTCrypto.decode(parts[1]), let signature = ChatGPTCrypto.decode(parts[2]), let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any], header["alg"] as? String == "RS256", let kid = header["kid"] as? String, header["jku"] == nil, header["jwk"] == nil, header["crit"] == nil, let keyset = try JSONSerialization.jsonObject(with: jwks) as? [String: Any], let keys = keyset["keys"] as? [[String: Any]], let key = keys.first(where: { $0["kid"] as? String == kid && $0["kty"] as? String == "RSA" && ($0["use"] as? String ?? "sig") == "sig" && ($0["alg"] as? String ?? "RS256") == "RS256" }), let n = key["n"] as? String, let e = key["e"] as? String, let modulus = ChatGPTCrypto.decode(n), let exponent = ChatGPTCrypto.decode(e), modulus.count >= 256 else { throw ChatGPTServiceError("identity_invalid") }
        let pkcs1 = sequence(integer(modulus) + integer(exponent))
        let attrs = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeyClass as String: kSecAttrKeyClassPublic, kSecAttrKeySizeInBits as String: modulus.count * 8] as CFDictionary
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCreateWithData(pkcs1 as CFData, attrs, &error), SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256, Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, &error), let claims = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else { throw ChatGPTServiceError("identity_invalid") }
        let audiences = claims["aud"] as? [String] ?? (claims["aud"] as? String).map { [$0] } ?? []
        guard claims["iss"] as? String == "https://auth.openai.com", audiences.contains(clientID), let subject = claims["sub"] as? String, !subject.isEmpty, let expires = claims["exp"] as? NSNumber, let issued = claims["iat"] as? NSNumber, expires.doubleValue > now.timeIntervalSince1970 - 5, issued.doubleValue <= now.timeIntervalSince1970 + 5, expires.doubleValue > issued.doubleValue else { throw ChatGPTServiceError("identity_invalid") }
        if audiences.count > 1, claims["azp"] as? String != clientID { throw ChatGPTServiceError("identity_invalid") }
        if let start = claims["nbf"] as? NSNumber, start.doubleValue > now.timeIntervalSince1970 + 5 { throw ChatGPTServiceError("identity_invalid") }
        if let nonce, !ChatGPTCrypto.constantTimeEqual(claims["nonce"] as? String ?? "", nonce) { throw ChatGPTServiceError("identity_invalid") }
        return ChatGPTVerifiedIdentity(issuer: "https://auth.openai.com", subject: subject, email: claims["email"] as? String, name: claims["name"] as? String)
    }
    private static func length(_ count: Int) -> Data { if count < 128 { return Data([UInt8(count)]) }; var value = count; var bytes: [UInt8] = []; while value > 0 { bytes.insert(UInt8(value & 255), at: 0); value >>= 8 }; return Data([0x80 | UInt8(bytes.count)] + bytes) }
    private static func integer(_ bytes: Data) -> Data { var value = Data(bytes.drop(while: { $0 == 0 })); if value.first.map({ $0 & 128 != 0 }) == true { value.insert(0, at: 0) }; return Data([0x02]) + length(value.count) + value }
    private static func sequence(_ value: Data) -> Data { Data([0x30]) + length(value.count) + value }
}

/// A loopback server belonging only to this authorization. It never logs URL/query/code values.
public final class ChatGPTLoopback: @unchecked Sendable {
    private let listener: NWListener
    private let gate = ChatGPTCallbackGate()
    private var attempt: ChatGPTAuthorizationAttempt?
    public init() throws { let params = NWParameters.tcp; params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any); listener = try NWListener(using: params, on: .any) }
    public func prepare(hostID: String, previousClientID: String?) async throws -> ChatGPTAuthorizationAttempt {
        try Task.checkCancellation()
        listener.newConnectionHandler = { [weak self] connection in self?.receive(connection) }
        let port: NWEndpoint.Port = try await withTaskCancellationHandler { try await withCheckedThrowingContinuation { continuation in
            let ready = ChatGPTCallbackGate()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: if ready.claim() { if let port = self?.listener.port { continuation.resume(returning: port) } else { continuation.resume(throwing: ChatGPTServiceError("listener_failed")) } }
                case .failed: if ready.claim() { continuation.resume(throwing: ChatGPTServiceError("listener_failed")) }
                case .cancelled: if ready.claim() { continuation.resume(throwing: CancellationError()) }
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "app.smail.chatgpt.loopback"))
        } } onCancel: { self.cancel() }
        try Task.checkCancellation()
        let value = try ChatGPTAuthorizationAttempt(hostID: hostID, redirectURI: "http://127.0.0.1:\(port.rawValue)/auth/callback", previousClientID: previousClientID)
        attempt = value; return value
    }
    public func wait() async throws -> (String, String) {
        defer { listener.cancel() }
        return try await withTaskCancellationHandler { try await withCheckedThrowingContinuation { continuation in gate.install(continuation); DispatchQueue.global().asyncAfter(deadline: .now() + 600) { [weak self] in self?.gate.finish(.failure(ChatGPTServiceError("login_timeout"))); self?.listener.cancel() } } } onCancel: { self.cancel() }
    }
    public func cancel() { gate.finish(.failure(CancellationError())); listener.cancel() }
    private func receive(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "app.smail.chatgpt.callback")); read(connection, buffer: Data())
    }
    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var combined = buffer; if let data { combined += data }
            guard combined.count <= 16384, error == nil else { connection.cancel(); return }
            guard let text = String(data: combined, encoding: .utf8), text.contains("\r\n\r\n") else { if complete { connection.cancel() } else { self.read(connection, buffer: combined) }; return }
            guard let attempt = self.attempt, let first = text.components(separatedBy: "\r\n").first else { self.reply(connection, status: "503 Service Unavailable", text: "Morrow sign-in is preparing. Please try again."); return }
            let words = first.split(separator: " ")
            guard words.count == 3, words[0] == "GET", let uri = URL(string: attempt.redirectURI), let components = URLComponents(string: String(words[1])), components.path == "/auth/callback", let target = URL(string: uri.scheme! + "://127.0.0.1:\(uri.port!)" + String(words[1])) else { self.reply(connection, status: "404 Not Found", text: "Not found."); return }
            do { let result = try attempt.consumeCallback(target); if self.gate.finish(.success((result.code, result.clientID))) { self.reply(connection, status: "200 OK", text: "ChatGPT authorization received. Return to Morrow to complete sign-in.") } else { self.reply(connection, status: "410 Gone", text: "This sign-in has already finished.") } }
            catch let failure as ChatGPTServiceError { if let returned = components.queryItems?.first(where: { $0.name == "state" })?.value, ChatGPTCrypto.constantTimeEqual(returned, attempt.state) { self.gate.finish(.failure(failure)) }; self.reply(connection, status: "400 Bad Request", text: failure.code == "access_denied" ? "Authorization cancelled. Return to Morrow." : "Authorization could not be verified. Return to Morrow.") }
            catch { self.reply(connection, status: "400 Bad Request", text: "Authorization could not be verified.") }
        }
    }
    private func reply(_ connection: NWConnection, status: String, text: String) { let body = Data(text.utf8); let header = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"; connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() }) }
}
private final class ChatGPTCallbackGate: @unchecked Sendable {
    private let lock = NSLock(); private var result: Result<(String, String), Error>?; private var continuation: CheckedContinuation<(String, String), Error>?; private var claimed = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; guard !claimed else { return false }; claimed = true; return true }
    func install(_ continuation: CheckedContinuation<(String, String), Error>) { lock.lock(); if let result { lock.unlock(); continuation.resume(with: result) } else { self.continuation = continuation; lock.unlock() } }
    @discardableResult func finish(_ result: Result<(String, String), Error>) -> Bool { lock.lock(); guard self.result == nil else { lock.unlock(); return false }; self.result = result; let continuation = self.continuation; self.continuation = nil; lock.unlock(); continuation?.resume(with: result); return true }
}
