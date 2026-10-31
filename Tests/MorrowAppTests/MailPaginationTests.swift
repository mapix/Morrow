import XCTest
import MorrowCore
@testable import MorrowApp

final class MailPaginationTests: XCTestCase {
    func testGmailSizedPagesClampAtDatasetBoundaries() {
        let empty = MailPageWindow(total: 0, index: 80)
        XCTAssertEqual(empty.range, 0..<0); XCTAssertFalse(empty.hasPrevious); XCTAssertFalse(empty.hasNext)
        let first = MailPageWindow(total: 14_003, index: 0)
        XCTAssertEqual(first.range, 0..<50); XCTAssertEqual(first.pageCount, 281)
        let last = MailPageWindow(total: 14_003, index: 999)
        XCTAssertEqual(last.range, 14_000..<14_003); XCTAssertTrue(last.hasPrevious); XCTAssertFalse(last.hasNext)
        XCTAssertEqual(MailPageWindow(total: 51, index: 1).range, 50..<51)
    }
    @MainActor func testPageSelectionAndBulkReadOnlyAffectCurrentPage() async throws {
        let model = try await fixture(count: 123)
        defer { try? FileManager.default.removeItem(at: model.store.root) }
        XCTAssertEqual(model.pagedMails.count, 50)
        let firstIDs = Set(model.pagedMails.map(\.id))
        model.turnMailPage(1)
        let pageIDs = Set(model.pagedMails.map(\.id))
        XCTAssertTrue(firstIDs.isDisjoint(with: pageIDs)); XCTAssertEqual(pageIDs.count, 50)
        await model.batch(pageIDs, action: .read(true))
        XCTAssertTrue(model.mails.filter { pageIDs.contains($0.id) }.allSatisfy(\.isRead))
        XCTAssertTrue(model.mails.filter { !pageIDs.contains($0.id) }.allSatisfy { !$0.isRead })
        await model.undo(); XCTAssertTrue(model.mails.allSatisfy { !$0.isRead })
        model.selectedAccount = "another"; XCTAssertEqual(model.mailPageIndex, 0)
    }
    @MainActor func testAllReadIsAcrossPagesAndUndoPreservesAlreadyReadMail() async throws {
        let model = try await fixture(count: 123)
        defer { try? FileManager.default.removeItem(at: model.store.root) }
        let existing = model.mails[0]
        let loadedOriginal = try await model.store.message(existing.id)
        let original = try XCTUnwrap(loadedOriginal)
        await model.markRead(existing, true)
        model.turnMailPage(2)
        await model.markAllReadInCurrentList()
        XCTAssertTrue(model.mails.allSatisfy(\.isRead))
        XCTAssertEqual(model.pagedMails.count, 23)
        await model.undo()
        XCTAssertEqual(model.mails.filter(\.isRead).map(\.id), [existing.id])
        let stored = try await model.store.message(existing.id)
        XCTAssertEqual(stored?.text, original.text); XCTAssertEqual(stored?.html, original.html)
    }
    @MainActor func testBulkSeenOverridesProtectNewlyFetchedMailFromOlderInventory() {
        let model = AppModel(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: model.store.root) }
        let old = Date(timeIntervalSince1970: 100), change = old.addingTimeInterval(5)
        model.noteBulkSeen(account: "a", folder: "INBOX", validity: 9, uids: [101], value: true, modifiedAt: change)
        XCTAssertEqual(model.bulkSeenValue(account: "a", folder: "INBOX", validity: 9, uid: 101, inventoryStarted: old)?.0, true)
        XCTAssertNil(model.bulkSeenValue(account: "b", folder: "INBOX", validity: 9, uid: 101, inventoryStarted: old))
        XCTAssertNil(model.bulkSeenValue(account: "a", folder: "INBOX", validity: 10, uid: 101, inventoryStarted: old))
        XCTAssertNil(model.bulkSeenValue(account: "a", folder: "INBOX", validity: 9, uid: 101, inventoryStarted: change.addingTimeInterval(1)))
    }
    @MainActor private func fixture(count: Int) async throws -> AppModel {
        let model = AppModel(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        model.settings.enabled = false; model.workspacePreferences.memoryEnabled = false
        model.setMailPageSize(50, persist: false)
        var account = MailAccount(); account.id = "demo"; account.email = "owner@example.invalid"; account.isDemo = true
        model.accounts = [account]; model.folders = [.init(accountID: account.id, path: "INBOX", role: "inbox")]
        for i in 0..<count {
            var mail = MailMessage(accountID: account.id, from: .init(email: "fixture@example.invalid"), subject: "Mail \(i)", text: "Body \(i)")
            mail.id = "mail-\(i)"; mail.messageID = "<mail-\(i)@example.invalid>"; mail.date = Date(timeIntervalSince1970: Double(i)); mail.html = "<p>Body \(i)</p>"
            try await model.store.upsert(mail)
        }
        await model.reload(); model.destination = .inbox
        return model
    }
}
