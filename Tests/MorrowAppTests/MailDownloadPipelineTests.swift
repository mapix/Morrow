import XCTest
import MorrowCore
@testable import MorrowApp

final class MailDownloadPipelineTests: XCTestCase {
    private func raw() -> Data { Data("From: peer@example.invalid\r\nTo: owner@example.invalid\r\nSubject: Durable download\r\nMessage-ID: <download@example.invalid>\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nDownloaded body".utf8) }
    private func job(_ data: Data, uid: UInt64 = 1) -> MailDownloadJob { .init(accountID: "fixture", folder: "INBOX", uid: uid, validity: 7, read: true, starred: false, byteCount: data.count, inventoryStarted: Date()) }
    func testRawDownloadSurvivesRestartWithoutCreatingMailOrDuplicateRawCopy() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root), bytes = raw(), task = job(raw())
        let accepted = try await store.queueMailDownload(bytes, job: task); XCTAssertTrue(accepted)
        let before = try await store.message(task.id); XCTAssertNil(before)
        let reopened = try MailStore(root: root)
        let pending = try await reopened.queuedMailDownloads(); XCTAssertEqual(pending.map(\.id), [task.id])
        let path = await reopened.rawURL(task.id); XCTAssertEqual(try Data(contentsOf: path), bytes)
        var parsed = MIMEParser.parse(bytes, accountID: task.accountID, folder: task.folder, uid: task.uid, validity: task.validity)
        parsed.isRead = task.read
        let saved = try await reopened.commitDownloadedMail(parsed, job: task)
        XCTAssertEqual(saved?.text, "Downloaded body")
        let after = try await reopened.queuedMailDownloads(); XCTAssertTrue(after.isEmpty)
        XCTAssertEqual(try Data(contentsOf: path), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("raw").path).count, 1)
    }
    func testQueueRejectsDuplicatesWrongSourceAndMoreThanBoundedCapacity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root), bytes = raw(), task = job(raw())
        _ = try await store.queueMailDownload(bytes, job: task)
        let duplicate = try await store.queueMailDownload(bytes, job: task); XCTAssertFalse(duplicate)
        let wrong = MIMEParser.parse(bytes, accountID: "other", uid: 1, validity: 7)
        do { _ = try await store.commitDownloadedMail(wrong, job: task); XCTFail("Foreign result accepted") } catch {}
        for uid in 2...UInt64(MailDownloadJob.maximumPending) { _ = try await store.queueMailDownload(bytes, job: job(bytes, uid: uid)) }
        do { _ = try await store.queueMailDownload(bytes, job: job(bytes, uid: 100)); XCTFail("Queue capacity exceeded") } catch {}
        let state = try await store.mailDownloadQueueState(); XCTAssertEqual(state.count, MailDownloadJob.maximumPending)
    }
    @MainActor func testMIMEProcessingIsIndependentOfAIPauseAndCanResumeDurableJobs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(root: root); model.settings.enabled = false
        var account = MailAccount(); account.id = "fixture"; account.email = "owner@example.invalid"; account.isDemo = true; model.accounts = [account]
        let bytes = raw(), task = job(raw()); _ = try await model.store.queueMailDownload(bytes, job: task)
        model.scheduleMailDownloadProcessing()
        for _ in 0..<100 { if model.mailDownloadProcessingTask == nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        let stored = try await model.store.message(task.id)
        XCTAssertEqual(stored?.text, "Downloaded body"); XCTAssertEqual(stored?.isRead, true)
        XCTAssertEqual(model.mailProcessingProgress.completed, 1); XCTAssertEqual(model.mailProcessingProgress.pending, 0)
        XCTAssertNotNil(model.mailByID(task.id)); XCTAssertFalse(model.mailProcessingBusy)
    }
}
