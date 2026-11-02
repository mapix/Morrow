import XCTest
@testable import MorrowCore

final class MailArrivalNotificationTests: XCTestCase {
    func testInitialHistoryValidityResetAndNonInboxNeverAlert() {
        var account = MailAccount(); account.id = "fixture"; account.email = "owner@example.invalid"
        let inbox = MailFolder(accountID: account.id, path: "INBOX", role: "inbox")
        let cursor = MailFolderSyncCursor(account: account, folder: inbox.path, validity: 7, highestModSequence: nil, uidNext: 101, knownUIDs: [1,50,100])
        let inventory = MailSyncInventory(validity: 7, flags: [:], presentUIDs: [1,50,100,101], highestModSequence: nil, uidNext: 102, incremental: true)
        XCTAssertFalse(MailArrivalNotificationPolicy.isNewArrival(uid: 100, inventory: inventory, previous: nil, account: account, folder: inbox))
        XCTAssertFalse(MailArrivalNotificationPolicy.isNewArrival(uid: 50, inventory: inventory, previous: cursor, account: account, folder: inbox))
        XCTAssertTrue(MailArrivalNotificationPolicy.isNewArrival(uid: 101, inventory: inventory, previous: cursor, account: account, folder: inbox))
        var reset = inventory; reset.validity = 8
        XCTAssertFalse(MailArrivalNotificationPolicy.isNewArrival(uid: 101, inventory: reset, previous: cursor, account: account, folder: inbox))
        XCTAssertFalse(MailArrivalNotificationPolicy.isNewArrival(uid: 101, inventory: inventory, previous: cursor, account: account, folder: .init(accountID: account.id, path: "Sent", role: "sent")))
    }
    func testFreshInboxJobsHavePriorityOverHistoricalBodiesAndLegacyJobsStayHistorical() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arrival-queue-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root), raw = Data("Synthetic MIME".utf8)
        let historical = MailDownloadJob(accountID: "fixture", folder: "INBOX", uid: 1, validity: 7, read: false, starred: false, byteCount: raw.count, inventoryStarted: Date())
        let fresh = MailDownloadJob(accountID: "fixture", folder: "INBOX", uid: 101, validity: 7, read: false, starred: false, byteCount: raw.count, inventoryStarted: Date(), isNewArrival: true)
        _ = try await store.queueMailDownload(raw, job: historical); _ = try await store.queueMailDownload(raw, job: fresh)
        let jobs = try await store.queuedMailDownloads(); XCTAssertEqual(jobs.first?.uid, 101)
        var value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fresh)) as! [String: Any]; value.removeValue(forKey: "isNewArrival")
        let legacy = try JSONDecoder().decode(MailDownloadJob.self, from: JSONSerialization.data(withJSONObject: value))
        XCTAssertNil(legacy.isNewArrival)
    }
    func testPOPBaselinePreventsInterruptedInitialHistoryFromLookingNew() {
        var account = MailAccount(); account.email = "owner@example.invalid"; account.receiveProtocol = "pop3"
        let cursor = POPArrivalCursor(account: account, knownUIDs: ["old-one", "old-two"])
        XCTAssertEqual(cursor.newUIDs(account: account, current: ["old-one", "old-two", "fresh"]), ["fresh"])
        account.email = "different@example.invalid"
        XCTAssertTrue(cursor.newUIDs(account: account, current: ["fresh"]).isEmpty)
    }
    func testArrivalIntentSurvivesCursorAdvanceFailedDownloadAndRestartUntilCanonicalDedup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arrival-intent-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root)
        var account = MailAccount(); account.id = "fixture"; account.email = "owner@example.invalid"
        let folder = "INBOX", previous = MailFolderSyncCursor(account: account, folder: "INBOX", validity: 7, highestModSequence: nil, uidNext: 2, knownUIDs: [1])
        try await store.save(previous, kind: "mail-sync-cursor", id: previous.id)
        let inventory = MailSyncInventory(validity: 7, flags: [:], presentUIDs: [1,2], highestModSequence: nil, uidNext: 3, incremental: true)
        _ = try await store.commitMailSyncInventory(inventory, account: account, folder: folder, updates: [], inventoryStarted: Date(), trackInboxArrivals: true)
        let committed = try await store.mailSyncCursor(account: account, folder: folder)
        XCTAssertEqual(committed?.uidNext, 3)
        // No MIME was staged: this represents a download failure/interruption.
        let restarted = try MailStore(root: root)
        _ = try await restarted.commitMailSyncInventory(inventory, account: account, folder: folder, updates: [], inventoryStarted: Date(), trackInboxArrivals: true)
        let pending = try await restarted.pendingArrivalUIDs(account: account, folder: folder, validity: 7)
        XCTAssertEqual(pending, [2])
        var mail = MailMessage(accountID: account.id, from: .init(email: "sender@example.invalid"), subject: "Arrival", text: "Original body")
        mail.id = "fixture:INBOX:7:2"; mail.uid = 2; mail.uidValidity = 7; mail.messageID = "<arrival-intent@example.invalid>"
        _ = try await restarted.upsert(mail)
        let afterParseCrash = try await restarted.committedArrivalIntentMailIDs()
        XCTAssertEqual(afterParseCrash, [mail.id])
        let notice = try await restarted.prepareArrivalNotification(mail)
        XCTAssertNotNil(notice)
        let converged = try await restarted.pendingArrivalUIDs(account: account, folder: folder, validity: 7)
        XCTAssertTrue(converged.isEmpty)
    }
    func testInitialInventoryAndUIDValidityResetDoNotCreateArrivalIntents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arrival-initial-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root); var account = MailAccount(); account.id = "fixture"
        var inventory = MailSyncInventory(validity: 7, flags: [:], presentUIDs: [1,2], highestModSequence: nil, uidNext: 3, incremental: false)
        _ = try await store.commitMailSyncInventory(inventory, account: account, folder: "INBOX", updates: [], inventoryStarted: Date(), trackInboxArrivals: true)
        let initial = try await store.pendingArrivalUIDs(account: account, folder: "INBOX", validity: 7); XCTAssertTrue(initial.isEmpty)
        inventory.presentUIDs.insert(3); inventory.uidNext = 4
        _ = try await store.commitMailSyncInventory(inventory, account: account, folder: "INBOX", updates: [], inventoryStarted: Date(), trackInboxArrivals: true)
        let fresh = try await store.pendingArrivalUIDs(account: account, folder: "INBOX", validity: 7); XCTAssertEqual(fresh, [3])
        inventory.validity = 8
        _ = try await store.commitMailSyncInventory(inventory, account: account, folder: "INBOX", updates: [], inventoryStarted: Date(), trackInboxArrivals: true)
        let reset = try await store.pendingArrivalUIDs(account: account, folder: "INBOX", validity: 8); XCTAssertTrue(reset.isEmpty)
    }
    func testPOPFetchFailureAndRestartKeepIntentWithoutAlertingInitialHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pop-intent-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root); var account = MailAccount(); account.id = "fixture"; account.receiveProtocol = "pop3"
        let initial = try await store.commitPOPArrivalInventory(["old"], account: account)
        XCTAssertTrue(initial.isEmpty)
        let fresh = try await store.commitPOPArrivalInventory(["old", "fresh"], account: account)
        XCTAssertEqual(fresh, ["fresh"])
        // No RETR body was persisted, simulating transport failure after UIDL.
        let restarted = try MailStore(root: root)
        let retry = try await restarted.commitPOPArrivalInventory(["old", "fresh"], account: account)
        XCTAssertEqual(retry, ["fresh"])
        var mail = MailMessage(accountID: account.id, from: .init(email: "sender@example.invalid"), subject: "POP arrival", text: "Source")
        mail.popUID = "fresh"; mail.id = account.id + ":pop:" + MailStore.hash("fresh"); mail.messageID = "<pop-fresh@example.invalid>"
        _ = try await restarted.upsert(mail)
        let parsed = try await restarted.committedArrivalIntentMailIDs(); XCTAssertEqual(parsed, [mail.id])
        _ = try await restarted.prepareArrivalNotification(mail)
        let completed = try await restarted.pendingPOPArrivalUIDs(account: account); XCTAssertTrue(completed.isEmpty)
    }
}
