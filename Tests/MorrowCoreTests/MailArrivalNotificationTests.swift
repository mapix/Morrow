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
}
