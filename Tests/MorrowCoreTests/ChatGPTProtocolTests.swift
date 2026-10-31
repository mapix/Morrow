import XCTest
import Security
@testable import MorrowCore

final class ChatGPTProtocolTests: XCTestCase {
    func testIssuedRegistrationAndReauthorization() throws {
        let new = try ChatGPTAuthorizationAttempt(hostID: "urn:uuid:fixture", redirectURI: "http://127.0.0.1:54321/auth/callback")
        let params = URLComponents(url: try new.authorizationURL(), resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(params.first { $0.name == "client_id" }?.value, "dynamic_agent_client")
        XCTAssertEqual(params.first { $0.name == "agent_name_hint" }?.value, "Morrow")
        let callback = callbackURL(new, extras: ["code":"fixture-code", "client_id":"oaiapp_fixture"])
        XCTAssertEqual(try new.consumeCallback(callback).clientID, "oaiapp_fixture")
        XCTAssertThrowsError(try new.consumeCallback(callbackURL(new, extras: ["code":"fixture-code"])))
        XCTAssertThrowsError(try new.consumeCallback(callbackURL(new, extras: ["code":"fixture-code", "client_id":"dynamic_agent_client"])))
        let returning = try ChatGPTAuthorizationAttempt(hostID: "urn:uuid:fixture", redirectURI: new.redirectURI, previousClientID: "oaiapp_fixture")
        XCTAssertEqual(try returning.consumeCallback(callbackURL(returning, extras: ["code":"fixture-code"])).clientID, "oaiapp_fixture")
        XCTAssertThrowsError(try returning.consumeCallback(callbackURL(returning, extras: ["code":"fixture-code", "client_id":"oaiapp_other"])))
        let returningParams = URLComponents(url: try returning.authorizationURL(), resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertNil(returningParams.first { $0.name == "agent_name_hint" })
    }
    func testCallbackStateExpiryAndExactRoute() throws {
        let attempt = try ChatGPTAuthorizationAttempt(hostID: "fixture", redirectURI: "http://127.0.0.1:54321/auth/callback")
        XCTAssertThrowsError(try attempt.consumeCallback(callbackURL(attempt, extras: ["state":"wrong", "code":"fixture-accesstoken-5", "client_id":"oaiapp_fixture"])))
        XCTAssertThrowsError(try attempt.consumeCallback(callbackURL(attempt, extras: ["code":"fixture-accesstoken-5", "client_id":"oaiapp_fixture"]), now: attempt.expiresAt))
        XCTAssertThrowsError(try ChatGPTAuthorizationAttempt(hostID: "fixture", redirectURI: "http://localhost:54321/auth/callback"))
        XCTAssertThrowsError(try ChatGPTAuthorizationAttempt(hostID: "fixture", redirectURI: "http://127.0.0.1:54321/callback"))
        var duplicated = URLComponents(url: callbackURL(attempt, extras: ["code":"fixture-accesstoken-5", "client_id":"oaiapp_fixture"]), resolvingAgainstBaseURL: false)!
        duplicated.queryItems?.append(URLQueryItem(name: "state", value: attempt.state))
        XCTAssertThrowsError(try attempt.consumeCallback(duplicated.url!))
        XCTAssertThrowsError(try attempt.consumeCallback(callbackURL(attempt, extras: ["error":"access_denied"]))) { XCTAssertEqual(($0 as? ChatGPTServiceError)?.code, "access_denied") }
    }
    func testRSAIdentitySignatureAndClaims() throws {
        let fixture = try SigningFixture()
        let now = Date(timeIntervalSince1970: 1793400000)
        let claims: [String: Any] = ["iss":"https://auth.openai.com", "sub":"subject-fixture", "aud":["oaiapp_fixture"], "nonce":"nonce-fixture", "iat":now.timeIntervalSince1970 - 5, "exp":now.timeIntervalSince1970 + 300, "email":"fixture@example.invalid"]
        let token = try fixture.sign(claims)
        XCTAssertEqual(try ChatGPTIdentityVerifier.verify(token, clientID: "oaiapp_fixture", nonce: "nonce-fixture", jwks: fixture.jwks, now: now).subject, "subject-fixture")
        XCTAssertThrowsError(try ChatGPTIdentityVerifier.verify(token, clientID: "oaiapp_wrong", nonce: "nonce-fixture", jwks: fixture.jwks, now: now))
        XCTAssertThrowsError(try ChatGPTIdentityVerifier.verify(token, clientID: "oaiapp_fixture", nonce: "wrong", jwks: fixture.jwks, now: now))
        XCTAssertThrowsError(try ChatGPTIdentityVerifier.verify(token, clientID: "oaiapp_fixture", nonce: "nonce-fixture", jwks: fixture.jwks, now: now.addingTimeInterval(310)))
        for change in [["iss":"https://evil.invalid"], ["nbf":now.timeIntervalSince1970 + 60], ["aud":["oaiapp_fixture", "oaiapp_other"]], ["sub":""]] as [[String: Any]] {
            var altered = claims; change.forEach { altered[$0.key] = $0.value }
            XCTAssertThrowsError(try ChatGPTIdentityVerifier.verify(fixture.sign(altered), clientID: "oaiapp_fixture", nonce: "nonce-fixture", jwks: fixture.jwks, now: now))
        }
        var invalid = token.split(separator: ".").map(String.init); invalid[2] = ChatGPTCrypto.base64URL(Data(repeating: 0, count: 256))
        XCTAssertThrowsError(try ChatGPTIdentityVerifier.verify(invalid.joined(separator: "."), clientID: "oaiapp_fixture", nonce: "nonce-fixture", jwks: fixture.jwks, now: now))
        XCTAssertThrowsError(try ChatGPTIdentityVerifier.verify(fixture.sign(claims, algorithm: "none"), clientID: "oaiapp_fixture", nonce: "nonce-fixture", jwks: fixture.jwks, now: now))
    }
    func testResponsesPayloadDoesNotBorrowGatewayOrUnsupportedParameters() throws {
        let payload = try ChatGPTPlanClient.payload(model: "fixture-model", system: "fixture instruction", prompt: "fixture prompt", json: true, schema: nil, images: [])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        XCTAssertEqual(object["store"] as? Bool, false); XCTAssertEqual(object["stream"] as? Bool, true)
        XCTAssertEqual(object["instructions"] as? String, "fixture instruction\nReturn a single valid JSON object and no other text.")
        for forbidden in ["max_output_tokens", "temperature", "background", "previous_response_id", "metadata", "user", "conversation"] { XCTAssertNil(object[forbidden]) }
        let input = try XCTUnwrap(object["input"] as? [[String: Any]])
        XCTAssertEqual(input.first?["role"] as? String, "user")
    }
    func testSSECompletionAndFailure() throws {
        var stream = ChatGPTResponseStream()
        XCTAssertNil(try stream.feed(line: "data: {\"type\":\"response.output_text.delta\",\"delta\":\"part\"}"))
        XCTAssertNil(try stream.feed(line: ""))
        XCTAssertNil(try stream.feed(line: "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"final\"}]}]}}"))
        XCTAssertEqual(try stream.feed(line: ""), "final")
        var failed = ChatGPTResponseStream()
        _ = try failed.feed(line: "data: {\"type\":\"response.failed\",\"response\":{\"error\":{\"code\":\"subscription_sharing_usage_limit_exceeded\"}}}")
        XCTAssertThrowsError(try failed.feed(line: "")) { XCTAssertEqual(($0 as? ChatGPTServiceError)?.code, "subscription_sharing_usage_limit_exceeded") }
        for record in ["[DONE]", "{\"type\":\"response.incomplete\"}", "{\"type\":\"response.completed\",\"response\":{\"status\":\"in_progress\"}}"] { var incomplete = ChatGPTResponseStream(); _ = try incomplete.feed(line: "data: " + record); XCTAssertThrowsError(try incomplete.feed(line: "")) }
    }
    func testURLSessionSSEBytesReachesTerminal() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureURLProtocol.self]
        let (bytes, response) = try await URLSession(configuration: config).bytes(from: URL(string: "https://fixture.invalid/events")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        var parser = ChatGPTSSEBytes(), final: String?
        for try await byte in bytes { if let result = try parser.feed(byte) { final = result; break } }
        XCTAssertEqual(final, "fixture-completed")
    }
    func testRefreshIsSingleFlightAndRotatesAtomically() async throws {
        let suite = "morrow-gpt-fixture-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = ChatGPTVerifiedIdentity(issuer: "https://auth.openai.com", subject: "fixture-sub", email: nil, name: nil)
        let profile = ChatGPTProfile(identity: identity, clientID: "oaiapp_fixture", planEnabled: true)
        defaults.set(try JSONEncoder().encode([profile]), forKey: "Smail.ChatGPT.profiles.v1")
        let vault = FixtureVault()
        let credentials = ChatGPTCredentials(clientID: profile.clientID, subject: profile.subject, accessToken: "fixture-accesstoken-1", refreshToken: "fixture-refreshtoken-2", idToken: "fixture-idtoken-3", scopes: ["chatgpt.tokens.use.direct"], expiresAt: Date().addingTimeInterval(-1), earliestRefreshAt: nil, revision: "old")
        try vault.save(credentials, profileID: profile.id)
        FixtureURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureURLProtocol.self]
        let service = ChatGPTService(defaults: defaults, vault: vault, session: URLSession(configuration: config))
        let results = try await withThrowingTaskGroup(of: ChatGPTCredentials.self) { group in
            for _ in 0..<20 { group.addTask { try await service.credentials(profileID: profile.id) } }
            var values: [ChatGPTCredentials] = []; for try await value in group { values.append(value) }; return values
        }
        XCTAssertEqual(results.count, 20); XCTAssertEqual(Set(results.map(\.revision)).count, 1)
        XCTAssertEqual(results.first?.accessToken, "fixture-accesstoken-6"); XCTAssertEqual(results.first?.refreshToken, "fixture-refreshtoken-7")
        XCTAssertEqual(FixtureURLProtocol.count, 1)
        XCTAssertEqual(try vault.read(profileID: profile.id)?.refreshToken, "fixture-refreshtoken-7")
    }
    func testSignOutCannotBeUndoneByLateRefresh() async throws {
        let suite = "morrow-gpt-fixture-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let profile = ChatGPTProfile(identity: ChatGPTVerifiedIdentity(issuer: "https://auth.openai.com", subject: "fixture-sub", email: nil, name: nil), clientID: "oaiapp_fixture", planEnabled: true)
        defaults.set(try JSONEncoder().encode([profile]), forKey: "Smail.ChatGPT.profiles.v1")
        let vault = FixtureVault(); try vault.save(ChatGPTCredentials(clientID: profile.clientID, subject: profile.subject, accessToken: "fixture-accesstoken-1", refreshToken: "fixture-refreshtoken-2", idToken: "fixture-idtoken-4", scopes: ["chatgpt.tokens.use.direct"], expiresAt: Date().addingTimeInterval(-1), earliestRefreshAt: nil, revision: "old"), profileID: profile.id)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureURLProtocol.self]
        let service = ChatGPTService(defaults: defaults, vault: vault, session: URLSession(configuration: config))
        let pending = Task { try await service.credentials(profileID: profile.id) }
        try await Task.sleep(for: .milliseconds(30))
        _ = try await service.signOut(profileID: profile.id)
        do { _ = try await pending.value; XCTFail("Late refresh must not restore signed-out credentials") } catch { }
        XCTAssertNil(try vault.read(profileID: profile.id))
        let saved = await service.savedProfiles(); XCTAssertEqual(saved.first?.signedIn, false)
    }
    func testMissingPlanScopeNeverRequestsInferenceCredential() async throws {
        let suite = "morrow-gpt-fixture-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let identity = ChatGPTVerifiedIdentity(issuer: "https://auth.openai.com", subject: "fixture-sub", email: nil, name: nil)
        let profile = ChatGPTProfile(identity: identity, clientID: "oaiapp_fixture", planEnabled: false)
        defaults.set(try JSONEncoder().encode([profile]), forKey: "Smail.ChatGPT.profiles.v1")
        let vault = FixtureVault(); try vault.save(ChatGPTCredentials(clientID: profile.clientID, subject: profile.subject, accessToken: "fixture-accesstoken-5", refreshToken: nil, idToken: "fixture-idtoken-4", scopes: ["openid"], expiresAt: Date().addingTimeInterval(1000), earliestRefreshAt: nil, revision: "fixture"), profileID: profile.id)
        let service = ChatGPTService(defaults: defaults, vault: vault)
        do { _ = try await service.credentials(profileID: profile.id); XCTFail("Identity alone cannot grant plan access") } catch { XCTAssertEqual((error as? ChatGPTServiceError)?.code, "plan_permission_missing") }
        let identityOnly = try await service.credentials(profileID: profile.id, requirePlan: false)
        XCTAssertFalse(identityOnly.planEnabled)
    }
    func testRealLoopbackConsumesCallbackAndCancellation() async throws {
        let server = try ChatGPTLoopback()
        let attempt = try await server.prepare(hostID: "urn:uuid:fixture", previousClientID: nil)
        let target = callbackURL(attempt, extras: ["code":"fixture-loopback-code", "client_id":"oaiapp_fixture"])
        let (badData, badResponse) = try await URLSession.shared.data(from: callbackURL(attempt, extras: ["state":"unverified", "code":"fixture-accesstoken-5", "client_id":"oaiapp_fixture"]))
        XCTAssertEqual((badResponse as? HTTPURLResponse)?.statusCode, 400); XCTAssertFalse(badData.isEmpty)
        let (data, response) = try await URLSession.shared.data(from: target)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(data: data, encoding: .utf8)?.contains("Return to Morrow") == true)
        let (_, duplicateResponse) = try await URLSession.shared.data(from: target)
        XCTAssertEqual((duplicateResponse as? HTTPURLResponse)?.statusCode, 410)
        let result = try await server.wait()
        XCTAssertEqual(result.0, "fixture-loopback-code"); XCTAssertEqual(result.1, "oaiapp_fixture")
        let cancelled = try ChatGPTLoopback()
        _ = try await cancelled.prepare(hostID: "urn:uuid:fixture", previousClientID: nil)
        let wait = Task { try await cancelled.wait() }; cancelled.cancel()
        do { _ = try await wait.value; XCTFail("Cancelled callback cannot succeed") } catch { XCTAssertTrue(error is CancellationError) }
    }
    private func callbackURL(_ attempt: ChatGPTAuthorizationAttempt, extras: [String: String]) -> URL { var components = URLComponents(string: attempt.redirectURI)!; var fields = extras; if fields["state"] == nil { fields["state"] = attempt.state }; components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }; return components.url! }
}
private struct SigningFixture {
    let privateKey: SecKey
    let jwks: Data
    init() throws {
        var error: Unmanaged<CFError>?
        privateKey = try XCTUnwrap(SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048] as CFDictionary, &error))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let data = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, &error) as Data?)
        var cursor = 0; let sequence = try Self.element(data, cursor: &cursor)
        var index = 0; let n = try Self.element(sequence, cursor: &index), e = try Self.element(sequence, cursor: &index)
        jwks = try JSONSerialization.data(withJSONObject: ["keys":[["kty":"RSA", "kid":"fixture-kid", "alg":"RS256", "use":"sig", "n":ChatGPTCrypto.base64URL(Data(n.drop(while: { $0 == 0 }))), "e":ChatGPTCrypto.base64URL(e)]]])
    }
    func sign(_ claims: [String: Any], algorithm: String = "RS256") throws -> String {
        let header = ChatGPTCrypto.base64URL(try JSONSerialization.data(withJSONObject: ["alg":algorithm, "kid":"fixture-kid"]))
        let payload = ChatGPTCrypto.base64URL(try JSONSerialization.data(withJSONObject: claims)); let signed = header + "." + payload
        var error: Unmanaged<CFError>?
        let signature = try XCTUnwrap(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(signed.utf8) as CFData, &error) as Data?)
        return signed + "." + ChatGPTCrypto.base64URL(signature)
    }
    private static func element(_ data: Data, cursor: inout Int) throws -> Data { let bytes = [UInt8](data); guard cursor + 2 <= bytes.count else { throw ChatGPTServiceError("fixture_invalid") }; cursor += 1; var count = Int(bytes[cursor]); cursor += 1; if count & 128 != 0 { let size = count & 127; count = 0; for _ in 0..<size { count = count * 256 + Int(bytes[cursor]); cursor += 1 } }; let end = cursor + count; guard end <= bytes.count else { throw ChatGPTServiceError("fixture_invalid") }; let result = Data(bytes[cursor..<end]); cursor = end; return result }
}
private final class FixtureVault: ChatGPTCredentialStorage, @unchecked Sendable {
    private let lock = NSLock(); private var records: [String: ChatGPTCredentials] = [:]
    func read(profileID: String) throws -> ChatGPTCredentials? { lock.lock(); defer { lock.unlock() }; return records[profileID] }
    func save(_ credentials: ChatGPTCredentials, profileID: String) throws { lock.lock(); defer { lock.unlock() }; records[profileID] = credentials }
    func delete(profileID: String) throws { lock.lock(); defer { lock.unlock() }; records[profileID] = nil }
}
private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock(); private static var requests = 0
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    static func reset() { lock.lock(); requests = 0; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests += 1; Self.lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
            let events = request.url?.path == "/events"
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":events ? "text/event-stream" : "application/json"])!
            let body = events ? Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"fixture-completed\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n".utf8) : Data("{\"access_token\":\"fixture-accesstoken-6\",\"refresh_token\":\"fixture-refreshtoken-7\",\"token_type\":\"Bearer\",\"expires_in\":3600}".utf8)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed); client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
