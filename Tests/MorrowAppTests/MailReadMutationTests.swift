import XCTest
import MorrowCore
@testable import MorrowApp

final class MailReadMutationTests: XCTestCase {
    @MainActor private func fixture(_ writer: DelayedReadWriter) async throws -> (URL, AppModel, MailMessage, MailMessage, MailMessage) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("read-mutation-" + UUID().uuidString)
        let model = AppModel(root: root, writeReadFlag: { account, mail, value in try await writer.write(value) })
        model.settings.enabled = false; model.destination = .inbox
        var account = MailAccount(); account.id = "synthetic"; account.email = "reader@example.invalid"; model.accounts = [account]
        var mail = MailMessage(accountID: account.id, from: .init(email: "sender@example.invalid"), subject: "Synthetic unread mail", text: "Complete body")
        mail.uid = 7; mail.uidValidity = 42; mail.messageID = "<read-test@example.invalid>"; mail.note = "Original note"
        mail = try await model.store.upsert(mail)
        var alias = mail; alias.id = "archive-copy"; alias.folder = "Archive"; alias.uid = 8
        alias = try await model.store.upsert(alias)
        var other = mail; other.id = "other-account"; other.accountID = "unrelated"
        other = try await model.store.upsert(other)
        await model.reload(); model.selectedID = mail.id
        return (root, model, mail, alias, other)
    }

    @MainActor func testManualMarkPublishesBeforeSlowServerAndUpdatesAliasesAndCounts() async throws {
        let writer = DelayedReadWriter(), (root, model, mail, alias, other) = try await fixture(writer)
        defer { try? FileManager.default.removeItem(at: root) }
        let originalVersion = mail.bodyVersion
        XCTAssertEqual(model.projectedInboxUnreadCount(mail.accountID), 1)
        let request = Task { await model.markRead(mail, true) }
        try await writer.waitForCall(1)
        XCTAssertEqual(model.selected?.isRead, true)
        XCTAssertEqual(model.visibleMails.first(where: { $0.id == mail.id })?.isRead, true)
        XCTAssertEqual(model.mailByID(alias.id)?.isRead, true)
        XCTAssertEqual(model.mailByID(other.id)?.isRead, false)
        XCTAssertEqual(model.projectedInboxUnreadCount(mail.accountID), 0)
        let waiting = try await model.store.message(mail.id)
        XCTAssertEqual(waiting?.isRead, false, "Server acknowledgement is still withheld")
        await writer.finish(1); await request.value
        let saved = try await model.store.message(mail.id), savedAlias = try await model.store.message(alias.id)
        XCTAssertEqual(saved?.isRead, true); XCTAssertEqual(savedAlias?.isRead, true)
        XCTAssertEqual(saved?.bodyVersion, originalVersion); XCTAssertEqual(saved?.text, mail.text)
        XCTAssertNil(model.error); XCTAssertTrue(model.pendingReadMutations.isEmpty)
    }

    @MainActor func testOpeningMailMarksReadSynchronouslyAndDoesNotRepeatForSameSelection() async throws {
        let writer = DelayedReadWriter(), (root, model, mail, _, _) = try await fixture(writer)
        defer { try? FileManager.default.removeItem(at: root) }
        model.selectedID = nil; model.select(mail)
        XCTAssertEqual(model.selectedID, mail.id); XCTAssertEqual(model.selected?.isRead, true)
        let request = try XCTUnwrap(model.pendingReadMutations[MailReadMutationKey(mail)]?.task)
        model.select(mail)
        try await writer.waitForCall(1)
        let calls = await writer.values; XCTAssertEqual(calls, [true])
        await writer.finish(1); await request.value
        let saved = try await model.store.message(mail.id); XCTAssertEqual(saved?.isRead, true)
    }

    @MainActor func testReloadStartedDuringPendingWriteKeepsReadStateAndFreshOtherMetadata() async throws {
        let writer = DelayedReadWriter(), (root, model, mail, _, _) = try await fixture(writer)
        defer { try? FileManager.default.removeItem(at: root) }
        let request = try XCTUnwrap(model.beginReadMutation(mail, value: true))
        try await writer.waitForCall(1)
        await model.reload()
        XCTAssertEqual(model.selected?.isRead, true, "A reload sees old storage while the server is delayed")
        var incoming = mail; incoming.isStarred = true; incoming.note = "Fresh note"
        await model.reload(incoming: [incoming])
        XCTAssertEqual(model.selected?.isRead, true); XCTAssertEqual(model.selected?.isStarred, true)
        XCTAssertEqual(model.selected?.note, "Fresh note")
        let inventoryStarted = Date()
        await writer.finish(1); await request.value
        let override = model.bulkSeenValue(account: mail.accountID, folder: mail.folder, validity: mail.uidValidity, uid: mail.uid, inventoryStarted: inventoryStarted)
        XCTAssertEqual(override?.0, true, "An inventory captured before acknowledgement must stay older")
        let saved = try await model.store.message(mail.id); XCTAssertGreaterThan(try XCTUnwrap(saved?.localFlagModifiedAt), inventoryStarted)
        XCTAssertEqual(model.selected?.note, "Fresh note"); XCTAssertEqual(model.selected?.isStarred, true)
    }

    @MainActor func testRapidReadUnreadRequestsRemainOrderedAndOlderCompletionCannotChangeUI() async throws {
        let writer = DelayedReadWriter(), (root, model, mail, _, _) = try await fixture(writer)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try XCTUnwrap(model.beginReadMutation(mail, value: true))
        try await writer.waitForCall(1)
        let second = try XCTUnwrap(model.beginReadMutation(mail, value: false))
        XCTAssertEqual(model.selected?.isRead, false)
        let waiting = await writer.values; XCTAssertEqual(waiting, [true])
        await writer.finish(1); await first.value
        try await writer.waitForCall(2)
        XCTAssertEqual(model.selected?.isRead, false)
        await model.reload(); XCTAssertEqual(model.selected?.isRead, false)
        await writer.finish(2); await second.value
        let values = await writer.values; XCTAssertEqual(values, [true, false])
        let saved = try await model.store.message(mail.id); XCTAssertEqual(saved?.isRead, false)
        XCTAssertTrue(model.pendingReadMutations.isEmpty)
    }

    @MainActor func testLatestFailureRestoresConfirmedEarlierStateWithoutLosingOtherEdits() async throws {
        let writer = DelayedReadWriter(), (root, model, mail, alias, _) = try await fixture(writer)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try XCTUnwrap(model.beginReadMutation(mail, value: true))
        try await writer.waitForCall(1)
        let second = try XCTUnwrap(model.beginReadMutation(mail, value: false))
        await writer.finish(1); await first.value; try await writer.waitForCall(2)
        model.cacheStarStates([mail.id: true], modifiedAt: Date())
        await writer.finish(2, failure: true); await second.value
        XCTAssertEqual(model.selected?.isRead, true); XCTAssertEqual(model.mailByID(alias.id)?.isRead, true)
        XCTAssertEqual(model.selected?.isStarred, true); XCTAssertEqual(model.selected?.note, "Original note")
        XCTAssertNotNil(model.error); XCTAssertTrue(model.pendingReadMutations.isEmpty)
        let saved = try await model.store.message(mail.id); XCTAssertEqual(saved?.isRead, true)
    }

    @MainActor func testFailedMarkRestoresUnreadAndCanRetry() async throws {
        let writer = DelayedReadWriter(), (root, model, mail, alias, _) = try await fixture(writer)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try XCTUnwrap(model.beginReadMutation(mail, value: true))
        try await writer.waitForCall(1); await writer.finish(1, failure: true); await first.value
        XCTAssertEqual(model.selected?.isRead, false); XCTAssertEqual(model.mailByID(alias.id)?.isRead, false)
        XCTAssertEqual(model.projectedInboxUnreadCount(mail.accountID), 1); XCTAssertNotNil(model.error)
        model.error = nil
        let retry = try XCTUnwrap(model.beginReadMutation(mail, value: true))
        try await writer.waitForCall(2); await writer.finish(2); await retry.value
        XCTAssertEqual(model.selected?.isRead, true); XCTAssertNil(model.error)
    }

    @MainActor func testBatchFeedbackIsImmediateAndRestoresUnacknowledgedRows() async throws {
        let writer = DelayedReadWriter(), (root, model, mail, alias, _) = try await fixture(writer)
        defer { try? FileManager.default.removeItem(at: root) }
        var second = mail; second.id = "second-message"; second.messageID = "<second@example.invalid>"; second.uid = 9
        second = try await model.store.upsert(second); await model.reload()
        let selectedIDs: Set<String> = [mail.id, second.id]
        let request = Task {
            await model.withReadBatchFeedback(ids: selectedIDs, value: true) {
                try? await writer.write(true)
                _ = try? await model.store.setReadState(ids: [mail.id], read: true, includeCanonicalCopies: true)
            }
        }
        try await writer.waitForCall(1)
        XCTAssertTrue(selectedIDs.allSatisfy { model.mailByID($0)?.isRead == true })
        XCTAssertEqual(model.mailByID(alias.id)?.isRead, true)
        await model.reload(); XCTAssertTrue(selectedIDs.allSatisfy { model.mailByID($0)?.isRead == true })
        await writer.finish(1); await request.value
        XCTAssertEqual(model.mailByID(mail.id)?.isRead, true); XCTAssertEqual(model.mailByID(alias.id)?.isRead, true)
        XCTAssertEqual(model.mailByID(second.id)?.isRead, false)
        XCTAssertFalse(model.batchBusy); XCTAssertTrue(model.pendingReadMutations.isEmpty)
    }

    @MainActor func testEarlierFailureCannotRollbackNewerSuccessfulRequest() async throws {
        let writer = DelayedReadWriter(), (root, model, mail, _, _) = try await fixture(writer)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try XCTUnwrap(model.beginReadMutation(mail, value: true))
        try await writer.waitForCall(1)
        let latest = try XCTUnwrap(model.beginReadMutation(mail, value: false))
        await writer.finish(1, failure: true); await first.value
        try await writer.waitForCall(2)
        XCTAssertEqual(model.selected?.isRead, false); XCTAssertNil(model.error)
        await writer.finish(2); await latest.value
        XCTAssertEqual(model.selected?.isRead, false); XCTAssertTrue(model.pendingReadMutations.isEmpty)
    }

    @MainActor func testWholeFolderLocalFeedbackKeepsUndoOriginals() async throws {
        let writer = DelayedReadWriter(), (root, model, mail, alias, other) = try await fixture(writer)
        defer { try? FileManager.default.removeItem(at: root) }
        model.accounts[0].isDemo = true
        await model.markFoldersRead([(model.accounts[0], "INBOX")])
        XCTAssertEqual(model.mailByID(mail.id)?.isRead, true); XCTAssertEqual(model.mailByID(alias.id)?.isRead, true)
        XCTAssertEqual(model.mailByID(other.id)?.isRead, false)
        await model.undo()
        XCTAssertEqual(model.mailByID(mail.id)?.isRead, false); XCTAssertEqual(model.mailByID(alias.id)?.isRead, false)
    }
}

private actor DelayedReadWriter {
    private(set) var values: [Bool] = []
    private var acknowledgements: [Int: CheckedContinuation<Void, Error>] = [:]
    func write(_ value: Bool) async throws {
        values.append(value); let call = values.count
        try await withCheckedThrowingContinuation { acknowledgements[call] = $0 }
    }
    func waitForCall(_ count: Int) async throws {
        for _ in 0..<400 {
            if acknowledgements[count] != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw MailError.message("Synthetic read write did not start")
    }
    func finish(_ call: Int, failure: Bool = false) {
        let acknowledgement = acknowledgements.removeValue(forKey: call)
        if failure { acknowledgement?.resume(throwing: MailError.message("Synthetic server rejected flag")) }
        else { acknowledgement?.resume() }
    }
}
