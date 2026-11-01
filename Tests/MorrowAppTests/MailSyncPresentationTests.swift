import XCTest
import MorrowCore
@testable import MorrowApp

final class MailSyncPresentationTests: XCTestCase {
    @MainActor func testBulkSyncDoesNotRepeatedlyRerunTheVisibleSearch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(root: root); defer { try? FileManager.default.removeItem(at: root) }
        model.syncBusy = true; model.searchMode = true; model.searchText = "fixture"; model.searchStatus = "cached snapshot"
        model.mails = [MailMessage(accountID: "fixture", from: .init(email: "sender@example.invalid"), subject: "fixture", text: "cached body")]
        XCTAssertTrue(model.searchUpdatesAvailable)
        try await Task.sleep(for: .seconds(6))
        XCTAssertFalse(model.searchBusy); XCTAssertNil(model.error); XCTAssertEqual(model.searchStatus, "cached snapshot")
    }
    func testUnknownInventoryDoesNotPretendToHaveDeterminateProgress() {
        XCTAssertNil(MailSyncProgress().fraction)
        XCTAssertEqual(MailSyncProgress(processed: 50, total: 200).fraction, 0.25)
        XCTAssertEqual(MailSyncProgress(processed: 201, total: 200).fraction, 1)
    }
    @MainActor func testSyncHasOneOwnerAndCanStopThenStartAgain() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(root: root); defer { try? FileManager.default.removeItem(at: root) }
        var started = false, cancelled = false, duplicateStarted = false, restarted = false
        let running = Task { @MainActor in
            await model.runMailSynchronization {
                model.syncBusy = true; defer { model.syncBusy = false }
                started = true
                do { try await Task.sleep(for: .seconds(20)) } catch { cancelled = true }
            }
        }
        while !started { await Task.yield() }
        await model.runMailSynchronization { duplicateStarted = true }
        XCTAssertFalse(duplicateStarted)
        model.stopMailSynchronization(); await running.value
        XCTAssertTrue(cancelled); XCTAssertFalse(model.syncBusy)
        await model.runMailSynchronization { restarted = true }
        XCTAssertTrue(restarted)
    }
    @MainActor func testStoppedSyncDoesNotReportSuccessfulAccountTimestamp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(root: root); defer { try? FileManager.default.removeItem(at: root) }
        var account = MailAccount(); account.id = "fixture"
        var status = AccountSyncState(accountID: account.id)
        status.lastSyncAt = Date(timeIntervalSince1970: 100); status.syncing = true
        model.accountSyncStates[account.id] = status
        await model.setAccountSyncState(account, syncing: false, completed: false)
        XCTAssertEqual(model.accountSyncStates[account.id]?.lastSyncAt, status.lastSyncAt)
        XCTAssertEqual(model.accountSyncStates[account.id]?.syncing, false)
    }
}
