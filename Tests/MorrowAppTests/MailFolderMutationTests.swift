import XCTest
import MorrowCore
@testable import MorrowApp

final class MailFolderMutationTests: XCTestCase {
    @MainActor private func fixture(readWriter: (@Sendable (MailAccount, MailMessage, Bool) async throws -> Void)? = nil) async throws -> (AppModel, MailMessage, MailMessage, MailMessage, DelayedFolderMover) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("folder-mutation-" + UUID().uuidString)
        let model = AppModel(root: root, notifications: FolderTestNotifications(), writeReadFlag: readWriter); model.settings.enabled = false; model.workspacePreferences.memoryEnabled = false
        var account = MailAccount(); account.id = "move-test"; account.email = "me@example.invalid"
        model.accounts = [account]
        model.folders = [.init(accountID: account.id, path: "INBOX", role: "inbox"), .init(accountID: account.id, path: "Archive", role: "archive"), .init(accountID: account.id, path: "All Mail", role: "archive"), .init(accountID: account.id, path: "Trash", role: "trash")]
        var source = MailMessage(accountID: account.id, from: .init(email: "sender@example.invalid"), subject: "Move source proof", text: "Complete original body\nwith its formatting.")
        source.id = "original"; source.uid = 7; source.uidValidity = 42; source.messageID = "<move-source@example.invalid>"
        source.raw = Data("Original MIME fixture\r\nbody unchanged\r\n".utf8); source.html = "<p>Complete original body</p>"
        source.attachments = [.init(name: "proof.txt", mimeType: "text/plain", data: Data("Original attachment".utf8))]
        source.note = "Original note"; source.labels = ["project"]; source.isStarred = true
        let originalRaw = source.raw
        source = try await model.store.upsert(source)
        var alias = source; alias.id = "all-mail-alias"; alias.folder = "All Mail"; alias.uid = 81; alias.uidValidity = 43; alias.raw = originalRaw
        alias = try await model.store.upsert(alias)
        var other = source; other.id = "other-account"; other.accountID = "other"; other.raw = originalRaw
        other = try await model.store.upsert(other)
        try await model.store.putVectors(messageID: source.id, chunks: [source.text], vectors: [[1, 0]], model: "fixture", hash: "same-source")
        await model.reload(); model.destination = .inbox; model.selectedAccount = account.id; model.selectedID = source.id
        let server = DelayedFolderMover()
        model.performServerMailMove = { _, mail, destination in try await server.move(mail, destination: destination) }
        return (model, source, alias, other, server)
    }
    @MainActor func testArchiveShowsPendingThenRemovesInboxWithoutFetchingDestination() async throws {
        let (model, source, alias, other, server) = try await fixture(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        let chat = PartnerChat(role: "partner", text: "Original conclusion", messageIDs: [source.id])
        let artifact = AgentArtifact(runID: "fixture", title: "Original brief", kind: .report, content: "Original conclusion", sourceMailIDs: [source.id])
        model.chat = [chat]; model.agentArtifacts = [artifact]
        let raw = try await model.store.rawData(source)
        let operation = Task { await model.move(source, role: "archive") }
        try await server.waitForCall(1)
        XCTAssertTrue(model.visibleMails.isEmpty); XCTAssertNil(model.selectedID)
        XCTAssertEqual(model.projectedInboxUnreadCount(source.accountID), 0)
        XCTAssertTrue(model.batchStatus?.contains("等待确认") == true)
        await model.reload(); XCTAssertTrue(model.visibleMails.isEmpty)
        await server.finish(1); await operation.value
        let target = try XCTUnwrap(model.mails.first { $0.folder == "Archive" && $0.accountID == source.accountID })
        XCTAssertEqual(target.uid, 9); XCTAssertEqual(target.uidValidity, 99)
        let fetchedComplete = try await model.store.message(target.id), complete = try XCTUnwrap(fetchedComplete)
        XCTAssertEqual(complete.text, source.text); XCTAssertEqual(complete.html, source.html); XCTAssertEqual(complete.note, source.note)
        let movedRaw = try await model.store.rawData(complete), movedAttachment = try await model.store.attachmentData(complete.attachments[0])
        XCTAssertEqual(movedRaw, raw); XCTAssertEqual(movedAttachment, Data("Original attachment".utf8))
        let fetchedAlias = try await model.store.message(alias.id), survivingAlias = try XCTUnwrap(fetchedAlias)
        let survivingAttachment = try await model.store.attachmentData(survivingAlias.attachments[0])
        XCTAssertEqual(survivingAttachment, Data("Original attachment".utf8))
        XCTAssertNotEqual(complete.attachments[0].storedPath, survivingAlias.attachments[0].storedPath)
        XCTAssertEqual(model.mailByID(other.id)?.folder, "INBOX")
        let count = try await model.store.indexCount(); XCTAssertEqual(count, 1)
        let hits = try await model.store.keywordSearch("Move source proof", allowedIDs: [target.id]); XCTAssertEqual(hits.first?.id, target.id)
        XCTAssertNil(model.error); XCTAssertTrue(model.pendingMailMoves.isEmpty); XCTAssertNotNil(model.undoLabel)
        XCTAssertEqual(model.mailByID(source.id)?.id, target.id)
        XCTAssertEqual(model.chat.first?.messageIDs, [target.id]); XCTAssertEqual(model.agentArtifacts.first?.sourceMailIDs, [target.id])
        let savedChat = try await model.store.object(PartnerChat.self, kind: "chat", id: chat.id)
        XCTAssertEqual(savedChat?.messageIDs, [target.id])
        await model.reload(incoming: [source]); XCTAssertTrue(model.visibleMails.isEmpty)
    }
    @MainActor func testRejectedTrashRestoresRowAndPreservesUserChangedSelection() async throws {
        let (model, source, _, other, server) = try await fixture(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        let operation = Task { await model.move(source, role: "trash") }
        try await server.waitForCall(1); XCTAssertNil(model.selectedID)
        model.selectedAccount = other.accountID; model.selectedID = other.id
        await server.finish(1, failure: true); await operation.value
        XCTAssertEqual(model.mailByID(source.id)?.folder, "INBOX")
        XCTAssertEqual(model.selectedID, other.id); XCTAssertEqual(model.selectedAccount, other.accountID)
        XCTAssertTrue(model.pendingMailMoves.isEmpty); XCTAssertNotNil(model.error)
        let stored = try await model.store.message(source.id); XCTAssertEqual(stored?.folder, "INBOX")
        model.error = nil
        let retry = Task { await model.move(source, role: "trash") }; try await server.waitForCall(2)
        await server.finish(2); await retry.value
        XCTAssertNil(model.error); XCTAssertNotNil(model.mails.first { $0.folder == "Trash" && $0.accountID == source.accountID })
    }
    @MainActor func testSamePendingMoveIsCoalescedAndUndoUsesConfirmedUID() async throws {
        let (model, source, _, _, server) = try await fixture(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        let operation = Task { await model.move(source, role: "archive") }; try await server.waitForCall(1)
        let duplicate = Task { await model.move(source, role: "archive") }
        await Task.yield(); let firstCalls = await server.calls; XCTAssertEqual(firstCalls.count, 1)
        await server.finish(1); await operation.value; await duplicate.value
        let undo = Task { await model.undo() }; try await server.waitForCall(2)
        let calls = await server.calls; XCTAssertEqual(calls[1].uid, 9); XCTAssertEqual(calls[1].validity, 99); XCTAssertEqual(calls[1].destination, "INBOX")
        await server.finish(2); await undo.value
        let restored = try XCTUnwrap(model.visibleMails.first { $0.accountID == source.accountID })
        XCTAssertEqual(restored.uid, 11); XCTAssertEqual(restored.folder, "INBOX"); XCTAssertNil(model.undoLabel)
        XCTAssertEqual(model.mailByID(source.id)?.id, restored.id)
        let fetchedStored = try await model.store.message(restored.id), stored = try XCTUnwrap(fetchedStored); XCTAssertEqual(stored.text, source.text)
    }
    @MainActor func testForeignDestinationIsRejectedBeforeAnyServerRequest() async throws {
        let (model, source, _, _, server) = try await fixture(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        await model.move(source, folder: .init(accountID: "other", path: "Trash", role: "trash"))
        let calls = await server.calls; XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(model.mailByID(source.id)?.folder, "INBOX"); XCTAssertNotNil(model.error)
    }
    @MainActor func testBadCopyUIDDoesNotInventCompletionOrRestoreOldInboxAfterAcknowledgement() async throws {
        let (model, source, _, _, server) = try await fixture(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        let operation = Task { await model.move(source, role: "archive") }; try await server.waitForCall(1)
        await server.finish(1, wrongSource: true); await operation.value
        XCTAssertTrue(model.visibleMails.isEmpty); XCTAssertNil(model.undoLabel)
        XCTAssertTrue(model.batchStatus?.contains("等待同步") == true); XCTAssertNotNil(model.error)
        let pending = try XCTUnwrap(model.pendingMailMoves[source.id]); XCTAssertTrue(pending.awaitingSync)
        let stored = try await model.store.message(source.id); XCTAssertEqual(stored?.text, source.text)
    }
    @MainActor func testMoveWaitsForPendingReadWriteAndPreservesConfirmedReadFlags() async throws {
        let reader = DelayedMoveReadWriter()
        let (model, source, alias, _, server) = try await fixture(readWriter: { _, _, _ in await reader.write() })
        defer { try? FileManager.default.removeItem(at: model.store.root) }
        let read = try XCTUnwrap(model.beginReadMutation(source, value: true))
        try await reader.waitForCall()
        let operation = Task { await model.move(source, role: "archive") }
        for _ in 0..<100 { if model.pendingMailMoves[source.id] != nil { break }; await Task.yield() }
        let waitingCalls = await server.calls; XCTAssertTrue(waitingCalls.isEmpty)
        XCTAssertTrue(model.visibleMails.isEmpty)
        await reader.finish(); await read.value
        try await server.waitForCall(1)
        let calls = await server.calls; XCTAssertEqual(calls[0].uid, 7); XCTAssertEqual(calls[0].validity, 42)
        await server.finish(1); await operation.value
        let target = try XCTUnwrap(model.mails.first { $0.folder == "Archive" && $0.accountID == source.accountID })
        let stored = try await model.store.message(target.id), storedAlias = try await model.store.message(alias.id)
        XCTAssertEqual(stored?.isRead, true); XCTAssertEqual(storedAlias?.isRead, true)
        XCTAssertTrue(model.pendingReadMutations.isEmpty); XCTAssertNil(model.error)
    }
}

private actor DelayedFolderMover {
    struct Call: Sendable { let uid: UInt64; let validity: UInt64; let destination: String }
    var calls: [Call] = []
    private var pending: [Int: CheckedContinuation<MailMoveReceipt, Error>] = [:]
    func move(_ mail: MailMessage, destination: String) async throws -> MailMoveReceipt {
        calls.append(.init(uid: mail.uid, validity: mail.uidValidity, destination: destination))
        let call = calls.count
        return try await withCheckedThrowingContinuation { pending[call] = $0 }
    }
    func waitForCall(_ call: Int) async throws {
        for _ in 0..<400 { if pending[call] != nil { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw MailError.message("Synthetic move did not start")
    }
    func finish(_ call: Int, failure: Bool = false, wrongSource: Bool = false) {
        guard let continuation = pending.removeValue(forKey: call) else { return }
        if failure { continuation.resume(throwing: MailError.message("Synthetic MOVE rejected")); return }
        let value = calls[call - 1]
        let source = wrongSource ? value.uid + 1 : value.uid
        continuation.resume(returning: MailMoveReceipt.parse("[COPYUID \(value.destination == "INBOX" ? 42 : 99) \(source) \(value.destination == "INBOX" ? 11 : 9)]"))
    }
}

private actor DelayedMoveReadWriter {
    private var pending: CheckedContinuation<Void, Never>?
    func write() async { await withCheckedContinuation { pending = $0 } }
    func waitForCall() async throws {
        for _ in 0..<400 { if pending != nil { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw MailError.message("Synthetic read did not start")
    }
    func finish() { pending?.resume(); pending = nil }
}

@MainActor private final class FolderTestNotifications: MailNotificationManaging {
    func removePending(_ ids: [String]) {}
    func requestAuthorization() async throws -> Bool { false }
    func add(id: String, title: String, body: String, at date: Date?) async throws {}
}
