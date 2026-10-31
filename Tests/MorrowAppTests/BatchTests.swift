import XCTest
import MorrowCore
@testable import MorrowApp

final class BatchTests: XCTestCase {
    @MainActor func testBatchFlagsLabelsAndUndoPreserveOriginalPerMessageState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(root: root, notifications: TestNotifications()); model.settings.enabled = false
        var account = MailAccount(); account.id = "demo"; account.isDemo = true; account.email = "you@example.com"; model.accounts = [account]
        var first = MailMessage(accountID: "demo", from: .init(email: "first@example.com"), subject: "First", text: "First message")
        var second = MailMessage(accountID: "demo", from: .init(email: "second@example.com"), subject: "Second", text: "Second message"); second.isRead = true; second.labels = ["existing"]
        first = try await model.store.upsert(first); second = try await model.store.upsert(second); await model.reload()
        let ids: Set<String> = [first.id, second.id]
        await model.batch(ids, action: .read(true)); XCTAssertTrue(model.mails.allSatisfy(\.isRead))
        await model.undo(); XCTAssertEqual(model.mails.first { $0.id == first.id }?.isRead, false); XCTAssertEqual(model.mails.first { $0.id == second.id }?.isRead, true)
        await model.batch(ids, action: .label("project")); XCTAssertTrue(model.mails.allSatisfy { $0.labels.contains("project") })
        await model.undo(); XCTAssertEqual(model.mails.first { $0.id == first.id }?.labels, []); XCTAssertEqual(model.mails.first { $0.id == second.id }?.labels, ["existing"])
    }
    @MainActor func testBatchTrashAndUndoRestoreEachSourceFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let notificationSink = TestNotifications(); let model = AppModel(root: root, notifications: notificationSink); model.settings.enabled = false
        var account = MailAccount(); account.id = "demo"; account.isDemo = true; account.email = "you@example.com"; model.accounts = [account]
        model.folders = [MailFolder(accountID: "demo", path: "INBOX", role: "inbox"), MailFolder(accountID: "demo", path: "Archive", role: "archive"), MailFolder(accountID: "demo", path: "Trash", role: "trash")]
        let first = MailMessage(accountID: "demo", from: .init(email: "first@example.com"), subject: "First", text: "First")
        var second = MailMessage(accountID: "demo", from: .init(email: "second@example.com"), subject: "Second", text: "Second"); second.folder = "Archive"
        try await model.store.upsert(first); try await model.store.upsert(second); await model.reload()
        await model.batch([first.id, second.id], action: .move("trash")); XCTAssertTrue(model.mails.allSatisfy { $0.folder == "Trash" })
        await model.undo(); XCTAssertEqual(model.mails.first { $0.id == first.id }?.folder, "INBOX"); XCTAssertEqual(model.mails.first { $0.id == second.id }?.folder, "Archive")
        XCTAssertNil(model.undoLabel)
        XCTAssertTrue(notificationSink.removed.contains("due:" + first.id)); XCTAssertTrue(notificationSink.removed.contains("due:" + second.id))
    }
}
@MainActor private final class TestNotifications: MailNotificationManaging {
    var removed: [String] = []
    func removePending(_ ids: [String]) { removed += ids }
    func requestAuthorization() async throws -> Bool { false }
    func add(id: String, title: String, body: String, at date: Date?) async throws {}
}
