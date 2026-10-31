import Foundation

/// Runs without a browser, credential store, Google request, or mailbox access:
/// xcrun swiftc iOS/MorrowMobile/GmailMobileAuthorization.swift scripts/gmail-mobile-oauth-contract-tests.swift -o /tmp/morrow-gmail-contract-tests
/// /tmp/morrow-gmail-contract-tests
@main
enum GmailMobileOAuthContractTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ description: String) throws {
            checks += 1
            guard condition() else { throw Failure(description: description) }
        }
        func rejects(_ callback: String, using attempt: GmailMobileOAuthAttempt) throws {
            let url = URL(string: callback)!
            do { _ = try attempt.authorizationCode(from: url) }
            catch { checks += 1; return }
            throw Failure(description: "Invalid callback was accepted")
        }
        let publicFixtureID = "1234567890-fixture.apps.googleusercontent.com"
        let scheme = "com.googleusercontent.apps.1234567890-fixture"
        let client = try GmailMobileOAuthClient(clientID: publicFixtureID, bundleID: "app.smail.mobile", registeredSchemes: [scheme])
        try check(client.callbackScheme == scheme, "Reversed Google iOS scheme")
        try check(client.redirectURI == scheme + ":/oauth2callback", "Official Google iOS path")
        let attempt = GmailMobileOAuthAttempt(client: client, state: "fixture-state", verifier: "fixture-verifier")
        let accepted = try attempt.authorizationCode(from: URL(string: client.redirectURI + "?state=fixture-state&code=fixture-code")!)
        try check(accepted == "fixture-code", "Valid callback")
        for callback in [
            client.redirectURI + "?state=other-state&code=fixture-code",
            client.redirectURI + "?code=fixture-code",
            client.redirectURI + "?state=fixture-state",
            client.redirectURI + "?state=fixture-state&code=",
            client.redirectURI + "?state=fixture-state&code",
            client.redirectURI + "?state=fixture-state&state=fixture-state&code=fixture-code",
            client.redirectURI + "?state=fixture-state&code=one&code=two",
            client.redirectURI + "?state=fixture-state&code=fixture-code#fragment",
            client.redirectURI + "?state=fixture-state&code=fixture%0Acode",
            client.redirectURI + "?state=fixture-state&code=fixture%00code",
            client.redirectURI + "?state=fixture-state&code=fixture-code&error=access_denied",
            client.redirectURI + "?state=fixture-state&error=invalid_request",
            client.redirectURI + "?state=other-state&error=access_denied",
            scheme + "://host/oauth2callback?state=fixture-state&code=fixture-code",
            scheme + ":///oauth2callback?state=fixture-state&code=fixture-code",
            scheme + ":/oauthredirect?state=fixture-state&code=fixture-code",
            scheme + ":/oauth2callback/extra?state=fixture-state&code=fixture-code",
            scheme + ":/%6fauth2callback?state=fixture-state&code=fixture-code",
            "other:/oauth2callback?state=fixture-state&code=fixture-code"
        ] { try rejects(callback, using: attempt) }
        var denialRecognized = false
        do { _ = try attempt.authorizationCode(from: URL(string: client.redirectURI + "?state=fixture-state&error=access_denied")!) }
        catch GmailMobileAuthorizationError.cancelled { denialRecognized = true }
        catch { throw Failure(description: "Denial was not recognized as cancellation") }
        try check(denialRecognized, "Denial recognized as cancellation")
        try check(GmailMobileOAuthAttempt.hasFullMailScope("openid email https://mail.google.com/"), "Full mail scope")
        try check(GmailMobileOAuthAttempt.hasFullMailScope("openid\nhttps://mail.google.com/\temail"), "Whitespace scope separation")
        for scope in [nil, "", "openid email", "https://www.googleapis.com/auth/gmail.readonly", "https://mail.google.com/extra", "https://mail.google.com", "https://mail.google.com/,email"] {
            try check(!GmailMobileOAuthAttempt.hasFullMailScope(scope), "Partial or deceptive scope rejected")
        }
        for (id, bundle, schemes) in [(publicFixtureID, "other.bundle", [scheme]), (publicFixtureID, "app.smail.mobile", []), ("invalid", "app.smail.mobile", [scheme])] {
            do { _ = try GmailMobileOAuthClient(clientID: id, bundleID: bundle, registeredSchemes: schemes) }
            catch { checks += 1; continue }
            throw Failure(description: "Invalid installation configuration was accepted")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("morrow-gmail-bundle-test-" + UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plist: [String: Any] = ["CFBundleIdentifier": "app.smail.mobile", "CFBundleName": "Morrow Fixture", "CFBundleURLTypes": [["CFBundleURLSchemes": [scheme]]]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: root.appendingPathComponent("Info.plist"))
        guard let fixtureBundle = Bundle(url: root) else { throw Failure(description: "Fixture bundle could not load") }
        let clientsURL = root.appendingPathComponent("oauth-clients.json")
        try JSONEncoder().encode(["google": publicFixtureID]).write(to: clientsURL)
        var desktopRejected = false
        do { _ = try GmailMobileOAuthClient.load(bundle: fixtureBundle) }
        catch { desktopRejected = true }
        try check(desktopRejected, "Desktop client cannot substitute for google_ios")
        try JSONEncoder().encode(["google": "desktop.apps.googleusercontent.com", "google_ios": publicFixtureID]).write(to: clientsURL)
        let loaded = try GmailMobileOAuthClient.load(bundle: fixtureBundle)
        try check(loaded.clientID == publicFixtureID, "Only google_ios is selected")
        print("Gmail iOS OAuth contract: \(checks) checks passed; no network or credentials used.")
    }
    struct Failure: Error { let description: String }
}
