import XCTest
import MorrowCore
@testable import MorrowApp

final class WorkspaceIterationTests: XCTestCase {
    @MainActor func model() throws -> AppModel { let model = AppModel(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), notifications: IterationNotifications()); model.settings.enabled = false; return model }
    @MainActor func testProfilesAreAutomaticallyPersistedAndContextTracksSelections() async throws {
        let model = try model(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        var account = MailAccount(); account.email = "me@example.com"; model.accounts = [account]
        var mail = MailMessage(accountID: account.id, from: .init(name: "客户", email: "client@example.com"), subject: "合同确认", text: "请核对条款")
        mail.attachments = [.init(name: "条款.txt", mimeType: "text/plain", data: Data("验收7天".utf8))]
        try await model.store.upsert(mail); await model.reload()
        let profiles = try await model.store.load(ContactProfile.self, kind: "contact-profile"); XCTAssertEqual(profiles.count, 1)
        model.selectProfile("client@example.com"); let frozen = model.currentContext; XCTAssertEqual(frozen.contactEmail, "client@example.com")
        model.revealMail(mail); XCTAssertEqual(model.currentContext.mailIDs, [mail.id]); XCTAssertEqual(model.currentContext.page, "mail")
        model.selectAttachment(model.attachmentRecords[0].id); XCTAssertEqual(model.currentContext.attachmentIDs.count, 1); XCTAssertEqual(frozen.page, "people")
        let receipt = try await model.execute(.init(type: "navigate", text: "联系人")); XCTAssertTrue(receipt.contains("联系人")); XCTAssertEqual(model.workspacePage, .people)
    }
    @MainActor func testChatFilesArePersistedWithoutCreatingMailAndRejectTraversal() async throws {
        let model = try model(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        try await model.addChatData(Data("请核对验收条款7个工作日".utf8), name: "条款.md", mime: "text/markdown")
        let material = try XCTUnwrap(model.chatMaterials.first); XCTAssertEqual(model.mailCount, 0)
        let evidence = try await model.materialEvidence([material]); XCTAssertTrue(evidence.contains("7个工作日"))
        let stored = try await model.store.load(ChatMaterial.self, kind: "chat-material"); XCTAssertEqual(stored.count, 1)
        var invalid = material; invalid.path = "../../outside.txt"; XCTAssertThrowsError(try model.chatMaterialData(invalid))
    }
    @MainActor func testDraftEditUpdatesSameDraftAndPreservesConcurrentUserChanges() async throws {
        let model = try model(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        var draft = ComposeDraft(); draft.body = "原始正文"; draft.subject = "核对"; draft.to = "client@example.com"
        model.composer = draft; await model.saveDraft(draft)
        let receipt = try await model.applySidebarDraftEdit(.init(type: "updateDraft", text: "更简洁的正文", kind: draft.id), snapshot: draft)
        XCTAssertTrue(receipt.contains("已更新")); XCTAssertEqual(model.composer?.body, "更简洁的正文"); XCTAssertEqual(model.drafts.count, 1)
        let snapshot = try XCTUnwrap(model.composer); model.composer?.body = "用户正在修改的新正文"
        _ = try await model.applySidebarDraftEdit(.init(type: "updateDraft", text: "第二次AI建议", kind: snapshot.id), snapshot: snapshot)
        XCTAssertEqual(model.composer?.body, "用户正在修改的新正文"); XCTAssertEqual(model.drafts.count, 2)
    }
    @MainActor func testSidebarMailActionsUseExplicitIDsAndLeaveUndo() async throws {
        let model = try model(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        var account = MailAccount(); account.id = "demo"; account.email = "me@example.com"; account.isDemo = true; model.accounts = [account]
        model.folders = [.init(accountID: "demo", path: "INBOX", role: "inbox"), .init(accountID: "demo", path: "Trash", role: "trash")]
        let mail = MailMessage(accountID: "demo", from: .init(email: "client@example.com"), subject: "确认", text: "请回复")
        try await model.store.upsert(mail); await model.reload(); model.selectedID = nil
        _ = try await model.execute(.init(type: "select", messageID: mail.id)); XCTAssertEqual(model.selectedID, mail.id); XCTAssertFalse(model.mails[0].isRead)
        _ = try await model.execute(.init(type: "trash", messageID: mail.id)); XCTAssertEqual(model.mails[0].folder, "Trash"); XCTAssertNotNil(model.undoLabel)
        await model.undo(); XCTAssertEqual(model.mails[0].folder, "INBOX")
    }
    @MainActor func testMirroredOpenUIEditsMergeBeforeAsynchronousPersistence() async throws {
        let model = try model(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        let page = OpenUIInteraction(source: "root = Form(\"scope\", [Input(\"a\", \"A\", \"\"), Input(\"b\", \"B\", \"\")])")
        await model.saveOpenUIInteraction(page)
        _ = model.editOpenUIField(.string("左侧修改"), key: "scope:a", interactionID: page.id)
        _ = model.editOpenUIField(.string("Chat修改"), key: "scope:b", interactionID: page.id)
        XCTAssertEqual(model.openUIInteractions.first?.stateRevision, 2)
        for _ in 0..<30 {
            let stored = try await model.store.object(OpenUIInteraction.self, kind: "openui-interaction", id: page.id)
            if stored?.stateRevision == 2 { XCTAssertEqual(stored?.values["scope:a"]?.text, "左侧修改"); XCTAssertEqual(stored?.values["scope:b"]?.text, "Chat修改"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Latest merged fields must persist")
    }
    @MainActor func testLiveSidebarDraftEditProducesAStoredChange() async throws {
        guard ProcessInfo.processInfo.environment["MORROW_LIVE_EDIT"] == "1" else { throw XCTSkip("Set MORROW_LIVE_EDIT for actual structured draft editing") }
        let model = try model(); defer { try? FileManager.default.removeItem(at: model.store.root) }; model.settings.enabled = true; model.settings.autoAnalyze = false
        var draft = ComposeDraft(); draft.subject = "协同验收"; draft.to = "lin@example.com"; draft.body = "原始正文"
        model.composer = draft; await model.saveDraft(draft)
        let context = model.currentContext
        await model.editDraftFromSidebar("把当前草稿正文改为：这是原生 Chat 协同测试，请核对验收条款。保留主题和收件人。", context: context, materials: [])
        let stored = try await model.store.object(ComposeDraft.self, kind: "draft", id: draft.id)
        XCTAssertEqual(stored?.body, "这是原生 Chat 协同测试，请核对验收条款。")
        XCTAssertEqual(model.composer?.body, stored?.body); XCTAssertEqual(stored?.to, draft.to); XCTAssertEqual(stored?.subject, draft.subject)
        XCTAssertTrue(model.chat.last?.text.contains("已更新") == true)
    }
    func testLiveAppleOnDeviceSpeechFile() async throws {
        guard ProcessInfo.processInfo.environment["MORROW_LIVE_SPEECH"] == "1", let path = ProcessInfo.processInfo.environment["MORROW_SPEECH_FILE"] else { throw XCTSkip("Set MORROW_LIVE_SPEECH and MORROW_SPEECH_FILE for actual Apple ASR") }
        let text = try await LocalSpeech.transcribeFile(URL(fileURLWithPath: path)); print("ACTUAL_APPLE_ASR: " + text); XCTAssertTrue(text.contains("附件"))
    }
}
@MainActor private final class IterationNotifications: MailNotificationManaging {
    func removePending(_ ids: [String]) {}
    func requestAuthorization() async throws -> Bool { false }
    func add(id: String, title: String, body: String, at date: Date?) async throws {}
}
