import XCTest
import MorrowCore
@testable import MorrowApp

final class MailConnectionSearchTests: XCTestCase {
    @MainActor private func model() -> AppModel {
        let value = AppModel(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), notifications: MailConnectionNotifications())
        value.settings.enabled = false; value.workspacePreferences.memoryEnabled = false
        return value
    }
    func testGmailRequestSelectsBrowserOAuthAndPreservesExplicitCustomName() throws {
        let value = MailProvider.connectionDraft("帮我接入我的 Gmail 邮箱 fixture-person-3@example.invalid，我浏览器已登录", clientID: "own-client")
        XCTAssertEqual(value.name, "Gmail"); XCTAssertEqual(value.email, "fixture-person-3@example.invalid")
        XCTAssertEqual(value.imapHost, "imap.gmail.com"); XCTAssertEqual(value.authMethod, "oauth"); XCTAssertEqual(value.oauthProvider, "google")
        let old = MailAccount.preset("网易 163")
        let switched = MailProvider.switching(old, from: "网易 163", to: "Gmail")
        XCTAssertEqual(switched.name, "Gmail"); XCTAssertEqual(switched.authMethod, "oauth")
        var custom = old; custom.name = "私人邮件"; custom.email = "me@example.com"
        XCTAssertEqual(MailProvider.switching(custom, from: "网易 163", to: "Gmail").name, "私人邮件")
        let plain = MailProvider.connectionDraft("fixture-person-4@example.invalid")
        XCTAssertEqual(plain.name, "其他 IMAP 邮箱"); XCTAssertFalse(plain.imapHost.contains("163"))
    }
    func testGoogleAuthorizationRequestUsesOwnClientIdentityPKCEAndLoginHint() throws {
        var account = MailAccount.preset("Gmail"); account.email = "fixture-person-3@example.invalid"; account.oauthClientID = "own-sm ail-client"
        let url = try OAuthProvider.authorizationURL(account, redirect: "http://127.0.0.1:51234/oauth", state: "state-unique", verifier: "verifier-unique")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a,_ in a })
        XCTAssertEqual(url.host, "accounts.google.com"); XCTAssertEqual(values["client_id"], account.oauthClientID)
        XCTAssertEqual(values["login_hint"], account.email); XCTAssertEqual(values["code_challenge_method"], "S256")
        XCTAssertEqual(values["code_challenge"], OAuthProvider.challenge("verifier-unique"))
        XCTAssertTrue(values["scope"]?.contains("https://mail.google.com/") ?? false); XCTAssertTrue(values["scope"]?.contains("email") ?? false)
        XCTAssertEqual(values["access_type"], "offline"); XCTAssertNil(values["password"])
        let cached = try OAuthProvider.authorizationURL(account, redirect: "http://127.0.0.1:51234/oauth", state: "new-state", verifier: "new-verifier", forceConsent: false)
        let cachedValues = Dictionary(try XCTUnwrap(URLComponents(url: cached, resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a,_ in a })
        XCTAssertNil(cachedValues["prompt"]); XCTAssertEqual(cachedValues["access_type"], "offline"); XCTAssertEqual(cachedValues["login_hint"], account.email)
    }
    @MainActor func testSearchMailboxScopeIncludesArchivedMailAndCanRemainWithinView() {
        let model = model(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        model.folders = [.init(accountID: "a", path: "INBOX", role: "inbox"), .init(accountID: "a", path: "Archive", role: "archive"), .init(accountID: "a", path: "Trash", role: "trash")]
        let inbox = MailMessage(accountID: "a", from: .init(email: "x@example.com"), subject: "A", text: "")
        var archive = inbox; archive.id = "archive"; archive.folder = "Archive"
        var other = inbox; other.id = "other"; other.accountID = "b"
        var trash = inbox; trash.id = "trash"; trash.folder = "Trash"
        model.mails = [inbox,archive,other,trash]; model.chooseMailbox("a")
        XCTAssertEqual(model.searchStrategy, .semantic)
        XCTAssertEqual(model.mails.filter(model.matchesSearchScope).map(\.id), [inbox.id,archive.id])
        model.chooseFolder(model.folders[0]); XCTAssertEqual(model.searchScope, .currentView)
        XCTAssertEqual(model.mails.filter(model.matchesSearchScope).map(\.id), [inbox.id])
        model.searchScope = .allMailboxes
        XCTAssertEqual(model.mails.filter(model.matchesSearchScope).map(\.id), [inbox.id,archive.id,other.id])
    }
    @MainActor func testDemoWorkCannotExpandOntoNewRealAccount() async throws {
        let model = model(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        var demo = MailAccount(); demo.id = "demo"; demo.isDemo = true
        var real = MailAccount(); real.id = "real"; model.accounts = [demo,real]
        var delegation = Delegation(); delegation.match = "项目"; model.isDemo = true; await model.saveDelegation(delegation)
        let original = MailMessage(accountID: "demo", from: .init(email: "x@example.com"), subject: "项目", text: "")
        var live = original; live.accountID = "real"
        XCTAssertTrue(model.workMatches(original, delegation: delegation)); XCTAssertFalse(model.workMatches(live, delegation: delegation))
    }
}
@MainActor private final class MailConnectionNotifications: MailNotificationManaging {
    func removePending(_ ids: [String]) {}
    func requestAuthorization() async throws -> Bool { false }
    func add(id: String, title: String, body: String, at date: Date?) async throws {}
}
