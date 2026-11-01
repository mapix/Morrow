import XCTest
import MorrowCore
@testable import MorrowApp

final class MailProjectionTests: XCTestCase {
    @MainActor func testIncrementalFlagsNeverReuseAnotherDestinationCache() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(root: root); defer { try? FileManager.default.removeItem(at: root) }
        var mail = MailMessage(accountID: "fixture", from: .init(email: "sender@example.invalid"), subject: "star", text: "preview")
        mail.isStarred = true; model.mails = [mail]; model.destination = .starred
        XCTAssertEqual(model.visibleMails.count, 1)
        model.destination = .inbox
        model.cacheStarStates([mail.id: false], modifiedAt: Date())
        model.destination = .starred
        XCTAssertTrue(model.visibleMails.isEmpty)
    }

    func testMetadataUpdatesKeepThreadAndAttachmentSourcesCurrentWithoutRenormalizing() {
        var mail = MailMessage(accountID: "fixture", from: .init(email: "sender@example.invalid"), subject: "Thread", text: "preview")
        mail.attachments = [.init(name: "fixture.txt", mimeType: "text/plain", data: Data())]
        var reply = mail; reply.id = "reply"; reply.messageID = "reply@example.invalid"; reply.subject = "Re: Thread"
        var cache = MailProjectionCache(); cache.rebuild([mail, reply])
        let normalizationCount = cache.normalizationCount, ordering = cache.primary.map(\.id)
        reply.isRead = true; reply.note = "new note"
        XCTAssertTrue(cache.applyMetadataUpdates([reply]))
        XCTAssertEqual(cache.primary.map(\.id), ordering)
        XCTAssertEqual(cache.byID[reply.id]?.note, reply.note)
        XCTAssertEqual(cache.related(to: mail).first?.isRead, true)
        XCTAssertEqual(cache.attachments.first(where: { $0.mail.id == reply.id })?.mail.note, reply.note)
        XCTAssertEqual(cache.normalizationCount, normalizationCount)
        var structural = mail; structural.subject = "new thread"
        reply.note = "must not publish partially"
        XCTAssertFalse(cache.applyMetadataUpdates([reply, structural]))
        XCTAssertEqual(cache.byID[reply.id]?.note, "new note")
    }

    @MainActor func testTwentyThousandMessageFlagChangesPreservePageAndCurrentValues() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(root: root); defer { try? FileManager.default.removeItem(at: root) }
        model.settings.enabled = false; model.destination = .inbox
        model.mails = (0..<20_000).map { i in
            var mail = MailMessage(accountID: "fixture", from: .init(email: "sender@example.invalid"), subject: "Mail \(i)", text: "preview")
            mail.id = "fixture-\(i)"; mail.date = Date(timeIntervalSince1970: Double(i)); return mail
        }
        let ordering = model.pagedMails.map(\.id), start = ProcessInfo.processInfo.systemUptime
        for id in ordering.prefix(10) {
            model.cacheReadStates([id: true], modifiedAt: Date())
            XCTAssertEqual(model.pagedMails.map(\.id), ordering)
        }
        let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
        XCTAssertEqual(model.pagedMails.map(\.id), ordering)
        XCTAssertTrue(ordering.prefix(10).allSatisfy { model.mailByID($0)?.isRead == true })
        XCTAssertEqual(model.primaryMails.count, 20_000)
        print("PROJECTION_FLAGS_20000: ten_updates_ms=\(milliseconds)")
    }

    @MainActor func testLocalFlagAndNoteUpdatesKeepSelectedProjectionCurrent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("projection-edit-" + UUID().uuidString)
        let model = AppModel(root: root); defer { model.navigate(.inbox); try? FileManager.default.removeItem(at: root) }
        model.settings.enabled = false; model.destination = .inbox
        var account = MailAccount(); account.id = "synthetic"; account.isDemo = true; model.accounts = [account]
        let mail = MailMessage(accountID: account.id, from: .init(email: "team@example.invalid"), subject: "review", text: "Review documents")
        try await model.store.upsert(mail); model.mails = [mail]; model.selectedID = mail.id
        model.unreadOnly = true; XCTAssertEqual(model.visibleMails.count, 1)
        await model.markRead(mail, true)
        XCTAssertEqual(model.selected?.isRead, true); XCTAssertTrue(model.visibleMails.isEmpty)
        let current = try XCTUnwrap(model.selected)
        await model.star(current); XCTAssertEqual(model.selected?.isStarred, true)
        await model.update(try XCTUnwrap(model.selected)) { $0.note = "User note" }
        XCTAssertEqual(model.selected?.note, "User note")
        let stored = try await model.store.message(mail.id)
        XCTAssertEqual(stored?.note, "User note"); XCTAssertEqual(stored?.isRead, true); XCTAssertEqual(stored?.isStarred, true)
    }
    func testThreadLookupReusesNormalizationAndDeduplicatesFolderAliases() {
        let mail = MailMessage(accountID: "a", from: .init(email: "team@example.invalid"), subject: "Contract review", text: "first")
        var reply = mail; reply.id = "reply"; reply.messageID = "reply@example.invalid"; reply.subject = "Re: Contract review"
        var alias = reply; alias.id = "archive-alias"; alias.folder = "Archive"
        var unrelated = reply; unrelated.id = "other-account"; unrelated.accountID = "b"
        var cache = MailProjectionCache(); cache.rebuild([mail, reply, alias, unrelated])
        XCTAssertEqual(cache.related(to: mail).map(\.id), [reply.id])
        let normalized = cache.normalizationCount
        for _ in 0..<1000 { _ = cache.related(to: mail); _ = cache.byID[reply.id]; _ = cache.primary }
        XCTAssertEqual(cache.normalizationCount, normalized)
        reply.isRead = true
        cache.rebuild([mail, reply, alias, unrelated])
        XCTAssertEqual(cache.normalizationCount, normalized, "Read flags must not renormalize unchanged subjects")
        XCTAssertEqual(cache.related(to: mail).first?.isRead, true)
        reply.subject = "Different topic"; cache.rebuild([mail, reply, unrelated])
        XCTAssertTrue(cache.related(to: mail).isEmpty)
        XCTAssertEqual(cache.normalizationCount, normalized + 1)
    }

    @MainActor func testVisibleProjectionInvalidatesForScopeAndMetadataChanges() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("projection-" + UUID().uuidString)
        let model = AppModel(root: root); defer { try? FileManager.default.removeItem(at: root) }
        model.settings.enabled = false; model.destination = .inbox
        var mail = MailMessage(accountID: "a", from: .init(email: "team@example.invalid"), subject: "hello", text: "hello")
        var other = mail; other.id = "other"; other.accountID = "b"
        model.mails = [mail, other]
        XCTAssertEqual(model.visibleMails.count, 2)
        model.selectedAccount = "a"; XCTAssertEqual(model.visibleMails.map(\.id), [mail.id])
        model.selectedID = mail.id; XCTAssertEqual(model.selected?.id, mail.id)
        mail.isRead = true; model.mails = [mail, other]; model.unreadOnly = true
        XCTAssertTrue(model.visibleMails.isEmpty)
        model.unreadOnly = false; model.folders = [.init(accountID: "a", path: "INBOX", role: "sent")]
        model.destination = .sent; XCTAssertEqual(model.visibleMails.map(\.id), [mail.id])
    }
}
