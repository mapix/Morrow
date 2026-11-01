import XCTest
@testable import MorrowCore

final class ContactTriageTests: XCTestCase {
    func testDirectExchangesOutrankHighVolumeBroadcastsAndCopiedContacts() {
        var account = MailAccount(); account.email = "me@example.invalid"
        var direct = MailMessage(accountID: account.id, from: .init(name: "Alice", email: "alice@example.invalid"), subject: "Review", text: "Review ready")
        direct.to = [.init(email: account.email)]
        var reply = MailMessage(accountID: account.id, from: .init(email: account.email), subject: "Re: Review", text: "Approved")
        reply.to = [direct.from]; reply.cc = [.init(email: "copied@example.invalid")]
        var duplicate = direct; duplicate.id = "duplicate"; direct.messageID = "canonical"; duplicate.messageID = "canonical"
        let broadcasts = (0..<80).map { _ -> MailMessage in
            var mail = MailMessage(accountID: account.id, from: .init(email: "newsletter@example.invalid"), subject: "Update", text: "Broadcast")
            mail.to = [.init(email: account.email)]; return mail
        }
        let mails = [direct, duplicate, reply] + broadcasts
        let profiles = ContactProfileBuilder.build(mails: mails, accounts: [account], manual: [])
        let rows = ContactTriage.build(profiles: profiles, mails: mails, accounts: [account], includeUnmailed: true).sorted(by: ContactTriage.interactionOrder)
        XCTAssertEqual(rows.first?.profile.email, "alice@example.invalid")
        XCTAssertEqual(rows.first?.directReceived, 1); XCTAssertEqual(rows.first?.directSent, 1)
        XCTAssertEqual(rows.first?.samples.count, 2)
        XCTAssertFalse(rows.first { $0.profile.email == "copied@example.invalid" }?.hasDirectExchange ?? true)
        XCTAssertEqual(rows.first { $0.profile.email == "newsletter@example.invalid" }?.automationHints, ["newsletter"])
        let restricted = ContactTriage.build(profiles: profiles, mails: [reply], accounts: [account], includeUnmailed: false)
        XCTAssertEqual(restricted.first { $0.profile.email == "alice@example.invalid" }?.directReceived, 0)
        XCTAssertFalse(restricted.contains { $0.profile.email == "newsletter@example.invalid" })
    }
    func testBatchStoreReadPreservesOrderDeduplicatesAndKeepsFlags() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root)
        var a = MailMessage(accountID: "a", from: .init(email: "a@example.invalid"), subject: "A", text: "A"); a.id = "a"
        var b = a; b.id = "b"; b.isRead = true
        try await store.upsert(a); try await store.upsert(b)
        let result = try await store.messages(ids: ["b", "a", "b", "missing"])
        XCTAssertEqual(result.map(\.id), ["b", "a"]); XCTAssertEqual(result.map(\.isRead), [true, false])
        do { _ = try await store.messages(ids: Array(repeating: "a", count: 13)); XCTFail("Unbounded batch accepted") } catch {}
    }
}
