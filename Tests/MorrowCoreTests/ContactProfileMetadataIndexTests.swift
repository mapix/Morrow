import XCTest
@testable import MorrowCore

final class ContactProfileMetadataIndexTests: XCTestCase {
    private func mail(_ id: String, sender: String, body: String = "original") -> MailMessage {
        var m = MailMessage(accountID: "fixture", from: .init(email: sender), subject: "Thread " + id, text: body)
        m.id = id; m.to = [.init(email: "owner@example.invalid")]; m.contentRevision = MailStore.hash(body)
        return m
    }
    func testOnlyAffectedContactsChangeAndFlagsDoNotCauseWork() {
        var account = MailAccount(); account.email = "owner@example.invalid"
        var first = mail("one", sender: "a@example.invalid")
        let second = mail("two", sender: "b@example.invalid")
        var cache = ContactProfileMetadataIndex()
        let original = cache.build(mails: [first, second], accounts: [account], manual: [], previous: [])
        first.isRead = true; first.isStarred = true; first.note = "local note"
        let unchanged = cache.build(mails: [first, second], accounts: [account], manual: [], previous: original)
        XCTAssertEqual(cache.affectedProfileCount, 0)
        XCTAssertEqual(unchanged.map(\.fingerprint), original.map(\.fingerprint))
        let added = mail("three", sender: "a@example.invalid")
        let updated = cache.build(mails: [first, second, added], accounts: [account], manual: [], previous: unchanged)
        XCTAssertEqual(cache.affectedEmails, ["a@example.invalid"])
        XCTAssertEqual(updated.first { $0.email == "a@example.invalid" }?.mailCount, 2)
        XCTAssertEqual(updated.first { $0.email == "b@example.invalid" }?.fingerprint, original.first { $0.email == "b@example.invalid" }?.fingerprint)
        let removed = cache.build(mails: [second], accounts: [account], manual: [], previous: updated)
        XCTAssertNil(removed.first { $0.email == "a@example.invalid" })
    }
    func testFullBodyAndHeaderProduceSameFingerprintAndBodyChangeInvalidatesIt() {
        var full = mail("one", sender: "a@example.invalid", body: String(repeating: "full source ", count: 5000))
        let header = MailMessageSummary(message: full).displayMessage
        let original = ContactProfileBuilder.build(mails: [full], accounts: [], manual: [])
        XCTAssertEqual(original[0].fingerprint, ContactProfileBuilder.build(mails: [header], accounts: [], manual: [])[0].fingerprint)
        var completed = original[0]; completed.analyzedMailVersions = [full.id: full.bodyVersion]; completed.analysisFingerprint = "profile-ai-v2:" + completed.fingerprint
        XCTAssertTrue(ContactProfileBuilder.canPreserveCompletedAnalysis(completed, original[0], versions: [full.id: full.bodyVersion]))
        full.contentRevision = MailStore.hash("changed")
        let updated = ContactProfileBuilder.build(mails: [full], accounts: [], manual: [])[0]
        XCTAssertNotEqual(updated.fingerprint, original[0].fingerprint)
        XCTAssertFalse(ContactProfileBuilder.canPreserveCompletedAnalysis(completed, updated, versions: [full.id: full.bodyVersion]))
    }
    func testTwentyThousandHeadersWithOneNewMailOnlyRefreshOneProfile() {
        var account = MailAccount(); account.email = "owner@example.invalid"
        var mails = (0..<20_000).map { mail("fixture-\($0)", sender: "person-\($0 % 1000)@example.invalid") }
        var cache = ContactProfileMetadataIndex()
        let original = cache.build(mails: mails, accounts: [account], manual: [], previous: [])
        mails.append(mail("new", sender: "person-1@example.invalid"))
        let start = ProcessInfo.processInfo.systemUptime
        let updated = cache.build(mails: mails, accounts: [account], manual: [], previous: original)
        XCTAssertEqual(cache.affectedProfileCount, 1); XCTAssertEqual(updated.count, 1000)
        XCTAssertEqual(updated.first { $0.email == "person-1@example.invalid" }?.mailCount, 21)
        print("CONTACT_METADATA_20000: one_new_mail_ms=\((ProcessInfo.processInfo.systemUptime-start)*1000); affected=\(cache.affectedProfileCount)")
    }
}
