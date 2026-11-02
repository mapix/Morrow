import XCTest
import MorrowCore
@testable import MorrowApp

private actor MailDeliveryFixture {
    var attempts = 0
    func send(_ draft: ComposeDraft, account: MailAccount) throws -> Data { attempts += 1; return try MIMEWriter.encode(draft, account: account) }
    func count() -> Int { attempts }
}
@MainActor final class DraftDeliveryTests: XCTestCase {
    private func setup() async throws -> (AppModel, MailAccount, ComposeDraft, MailDeliveryFixture) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("delivery-test-" + UUID().uuidString)
        let model = AppModel(root: root, notifications: DeliveryNotifications()); model.settings.enabled = false; model.workspacePreferences.memoryEnabled = false
        var account = MailAccount(); account.id = "fixture"; account.email = "sender@example.invalid"; account.smtpHost = "smtp.fixture.invalid"; account.isDemo = false
        model.accounts = [account]; model.folders = [MailFolder(accountID: account.id, path: "Sent Items", role: "sent")]
        var draft = ComposeDraft(); draft.accountID = account.id; draft.to = "recipient@example.invalid"; draft.subject = "Synthetic delivery"; draft.body = "No real mail is transmitted"
        try await model.store.commitWorkingDraft(draft, artifact: nil); try await model.store.queueReviewedDraft(draft, now: .distantPast)
        let stored = try await model.store.object(ComposeDraft.self, kind: "draft", id: draft.id); model.drafts = [try XCTUnwrap(stored)]
        let fixture = MailDeliveryFixture(); model.sendMailOverride = { account, draft in try await fixture.send(draft, account: account) }
        return (model, account, draft, fixture)
    }
    func testSMTPConfirmationCreatesVisibleSentCopyAndNeverSendsAgain() async throws {
        let (model, _, draft, fixture) = try await setup(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        await model.sendPending()
        let stored = try await model.store.object(ComposeDraft.self, kind: "draft", id: draft.id)
        XCTAssertEqual(stored?.state, "sent"); XCTAssertNil(model.error); XCTAssertTrue(model.outboxDrafts.isEmpty)
        model.navigate(.sent)
        XCTAssertEqual(model.visibleMails.first?.messageID, "<" + draft.id + "@morrow.local>")
        model.openDraft(try XCTUnwrap(stored))
        XCTAssertEqual(model.destination, .sent); XCTAssertNil(model.composer)
        XCTAssertEqual(model.selected?.messageID, "<" + draft.id + "@morrow.local>")
        await model.sendPending(); let count = await fixture.count(); XCTAssertEqual(count, 1)
        do { try await model.store.queueReviewedDraft(draft); XCTFail("Sent mail must remain protected") } catch {}
    }
    func testCopyFailurePreservesSentStateAndRecoveryDoesNotRetransmit() async throws {
        let (model, _, draft, fixture) = try await setup(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        let blocked = await model.store.rawURL("sent:" + draft.id)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        await model.sendPending()
        let stored = try await model.store.object(ComposeDraft.self, kind: "draft", id: draft.id)
        XCTAssertEqual(stored?.state, "sent"); XCTAssertNotNil(stored?.error)
        await model.sendPending(); let count = await fixture.count(); XCTAssertEqual(count, 1)
        try FileManager.default.removeItem(at: blocked)
        await model.reconcileStoredDeliveries(); await model.reload(); model.navigate(.sent)
        XCTAssertEqual(model.visibleMails.count, 1)
        let afterRecovery = await fixture.count(); XCTAssertEqual(afterRecovery, 1)
    }
    func testServerAppendFailureIsStillSuccessfulDelivery() async throws {
        let (model, _, draft, fixture) = try await setup(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        model.appendSentMailOverride = { _, _, _ in throw MailError.message("synthetic append failure") }
        await model.sendPending()
        let stored = try await model.store.object(ComposeDraft.self, kind: "draft", id: draft.id)
        XCTAssertEqual(stored?.state, "sent"); XCTAssertNil(model.error)
        let count = await fixture.count(); XCTAssertEqual(count, 1)
        XCTAssertTrue(model.events.contains { $0.detail.contains("synthetic append failure") })
    }
    func testUncertainSMTPResultStaysInOutboxAndDoesNotRetry() async throws {
        let (model, _, draft, _) = try await setup(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        let fixture = FailingMailFixture()
        model.sendMailOverride = { _, _ in try await fixture.send() }
        await model.sendPending(); await model.sendPending()
        let stored = try await model.store.object(ComposeDraft.self, kind: "draft", id: draft.id)
        XCTAssertEqual(stored?.state, "uncertain"); XCTAssertEqual(model.outboxDrafts.first?.id, draft.id)
        let count = await fixture.count(); XCTAssertEqual(count, 1)
    }
    func testOutboxAndDraftsSeparatePendingFromConfirmedAndServerCopyWins() async throws {
        let (model, account, draft, _) = try await setup(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        var editable = draft; editable.id = "editable"; editable.state = "draft"
        var uncertain = draft; uncertain.id = "unverified"; uncertain.state = "uncertain"
        model.drafts += [editable, uncertain]
        XCTAssertEqual(Set(model.outboxDrafts.map(\.id)), [draft.id, uncertain.id]); XCTAssertEqual(model.editableDrafts.map(\.id), [editable.id])
        var local = MIMEParser.parse(try MIMEWriter.encode(draft, account: account), accountID: account.id, folder: "Sent Items"); local.id = "sent:" + draft.id
        var server = local; server.id = "server-sent"; server.uid = 7; server.uidValidity = 2
        model.mails = [local, server]; model.navigate(.sent)
        XCTAssertEqual(model.visibleMails.map(\.id), [server.id])
    }
}
private actor FailingMailFixture {
    var attempts = 0
    func send() throws -> Data { attempts += 1; throw MailError.message("Synthetic connection lost after SMTP submission") }
    func count() -> Int { attempts }
}
@MainActor private final class DeliveryNotifications: MailNotificationManaging {
    func removePending(_ ids: [String]) {}
    func requestAuthorization() async throws -> Bool { false }
    func add(id: String, title: String, body: String, at date: Date?) async throws {}
}
