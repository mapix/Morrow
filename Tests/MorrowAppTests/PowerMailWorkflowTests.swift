import XCTest
import MorrowCore
@testable import MorrowApp

final class PowerMailWorkflowTests: XCTestCase {
    @MainActor private func makeModel() -> AppModel {
        let model = AppModel(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), notifications: PowerMailNotifications())
        model.settings.enabled = false; model.settings.autoAnalyze = false
        model.settings.embeddingDirectory = model.store.root.appendingPathComponent("missing-embedding-model").path
        model.workspacePreferences.memoryEnabled = false
        var a = MailAccount(); a.id = "a"; a.email = "a@example.com"; a.isDemo = true
        var b = a; b.id = "b"; b.email = "b@example.com"
        model.accounts = [a, b]
        model.folders = ["a", "b"].flatMap { id in [MailFolder(accountID: id, path: "INBOX", role: "inbox"), MailFolder(accountID: id, path: "Archive", role: "archive")] }
        return model
    }
    @MainActor private func waitForSearch(_ model: AppModel) async throws {
        for _ in 0..<100 {
            if !model.searchBusy { XCTAssertNil(model.error); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Scoped keyword search did not finish")
    }
    private func mail(_ id: String, account: String, folder: String = "INBOX", read: Bool = false, category: MailCategory = .work) -> MailMessage {
        var mail = MailMessage(accountID: account, from: .init(email: "client@example.com"), subject: "needle " + id, text: "材料核对")
        mail.id = id; mail.folder = folder; mail.isRead = read
        mail.analysis = .init(summary: id, category: category)
        return mail
    }
    @MainActor func testSearchScopesBeforeLimitAndChatUsesSameFilteredResults() async throws {
        let model = makeModel(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        for i in 0..<245 { try await model.store.upsert(mail("a-\(i)", account: "a")) }
        var wanted = mail("b-work", account: "b"); wanted.date = Date().addingTimeInterval(-1000)
        try await model.store.upsert(wanted)
        try await model.store.upsert(mail("b-read", account: "b", read: true))
        try await model.store.upsert(mail("b-finance", account: "b", category: .finance))
        try await model.store.upsert(mail("b-archive", account: "b", folder: "Archive"))
        await model.reload(); model.chooseMailbox("b"); model.searchScope = .currentView; model.unreadOnly = true; model.category = .work
        model.searchText = "needle"; model.search(); try await waitForSearch(model)
        XCTAssertEqual(model.searchHits.map(\.id), [wanted.id])
        XCTAssertEqual(model.visibleMails.map(\.id), [wanted.id])
        XCTAssertEqual(model.currentContext.mailIDs, [wanted.id])
        model.unreadOnly = false; model.category = nil; try await waitForSearch(model)
        XCTAssertEqual(Set(model.visibleMails.map(\.id)), ["b-work", "b-read", "b-finance"])
        model.selectedFolder = "Archive"; try await waitForSearch(model)
        XCTAssertEqual(model.visibleMails.map(\.id), ["b-archive"])
        XCTAssertEqual(model.currentContext.mailIDs, ["b-archive"])
    }
    @MainActor func testReadMutationRefreshesSearchRowsWithoutClosingReader() async throws {
        let model = makeModel(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        let message = mail("b-incoming", account: "b")
        try await model.store.upsert(message); await model.reload(); model.chooseMailbox("b")
        model.searchText = "needle"; model.search(); try await waitForSearch(model)
        model.selectedID = message.id
        await model.markRead(message, true)
        XCTAssertTrue(try XCTUnwrap(model.visibleMails.first).isRead)
        XCTAssertEqual(model.selectedID, message.id)
        XCTAssertEqual(model.inboxUnreadCount("b"), 0)
        try await waitForSearch(model)
        model.unreadOnly = true
        XCTAssertTrue(model.visibleMails.isEmpty)
        try await waitForSearch(model)
        XCTAssertTrue(model.searchHits.isEmpty)
        model.unreadOnly = false; try await waitForSearch(model)
        XCTAssertEqual(model.visibleMails.map(\.id), [message.id])
    }
    @MainActor func testVectorScopeIsAppliedBeforeResultLimit() async throws {
        let model = makeModel(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        for i in 0..<40 {
            let message = mail("a-vector-\(i)", account: "a"); try await model.store.upsert(message)
            try await model.store.putVectors(messageID: message.id, chunks: ["A"], vectors: [[1, 0]], model: "fixture", hash: message.id)
        }
        let wanted = mail("b-vector", account: "b"); try await model.store.upsert(wanted)
        try await model.store.putVectors(messageID: wanted.id, chunks: ["B"], vectors: [[0.5, 0.5]], model: "fixture", hash: wanted.id)
        let hits = try await model.store.vectorSearch([1, 0], model: "fixture", limit: 1, allowedIDs: [wanted.id])
        XCTAssertEqual(hits.map(\.id), [wanted.id])
        let conditional = try await model.index.search("subject:needle", store: model.store, allowedIDs: [wanted.id])
        XCTAssertEqual(conditional.map(\.id), [wanted.id])
    }
    @MainActor func testDraftEditPreservesConcurrentSenderInEditorAndStore() async throws {
        let model = makeModel(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        var snapshot = ComposeDraft(); snapshot.accountID = "a"; snapshot.to = "client@example.com"; snapshot.subject = "核对"; snapshot.body = "原稿"
        model.composer = snapshot; await model.saveDraft(snapshot)
        model.composer?.accountID = "b"
        let receipt = try await model.applySidebarDraftEdit(.init(type: "updateDraft", text: "AI建议", kind: snapshot.id), snapshot: snapshot)
        XCTAssertEqual(model.composer?.accountID, "b"); XCTAssertEqual(model.composer?.body, "原稿")
        let original = try await model.store.object(ComposeDraft.self, kind: "draft", id: snapshot.id)
        XCTAssertEqual(original?.accountID, "b"); XCTAssertEqual(original?.body, "原稿")
        let suggestion = try XCTUnwrap(model.drafts.first { $0.id != snapshot.id })
        XCTAssertEqual(suggestion.accountID, "a"); XCTAssertEqual(suggestion.body, "AI建议")
        XCTAssertTrue(receipt.contains("已保留"))
    }
    @MainActor func testPinnedDraftResolvesFromStoreAndMissingSourceLeavesReceipt() async throws {
        let model = makeModel(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        await model.restoreChatSessions()
        var pinned = ComposeDraft(); pinned.accountID = "b"; pinned.to = "client@example.com"; pinned.subject = "固定源"; pinned.body = "原稿"
        try await model.store.save(pinned, kind: "draft", id: pinned.id)
        model.workspacePage = .people; model.composer = nil
        let source = try await model.sidebarDraft(id: pinned.id)
        XCTAssertEqual(source.id, pinned.id)
        let receipt = try await model.applySidebarDraftEdit(.init(type: "updateDraft", text: "改稿", kind: source.id), snapshot: source)
        XCTAssertNil(model.composer); XCTAssertEqual(model.workspacePage, .people)
        XCTAssertTrue(receipt.contains("固定范围"))
        let saved = try await model.store.object(ComposeDraft.self, kind: "draft", id: pinned.id)
        XCTAssertEqual(saved?.body, "改稿"); XCTAssertEqual(saved?.accountID, "b")
        var context = WorkspaceContext(page: "compose", label: "已删除草稿"); context.draftID = "missing"
        await model.editDraftFromSidebar("把这份草稿改简短", context: context, materials: [])
        XCTAssertEqual(model.visibleChat.count, 2)
        XCTAssertEqual(model.visibleChat.first?.role, "user")
        XCTAssertEqual(model.visibleChat.first?.context?.draftID, "missing")
        XCTAssertTrue(model.visibleChat.last?.text.contains("不存在或已删除") == true)
        XCTAssertEqual(model.drafts.count, 1)
    }
}

@MainActor private final class PowerMailNotifications: MailNotificationManaging {
    func removePending(_ ids: [String]) {}
    func requestAuthorization() async throws -> Bool { false }
    func add(id: String, title: String, body: String, at date: Date?) async throws {}
}
