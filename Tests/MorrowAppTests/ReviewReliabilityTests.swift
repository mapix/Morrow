import XCTest
import MorrowCore
@testable import MorrowApp

final class ReviewReliabilityTests: XCTestCase {
    @MainActor private func model() -> AppModel {
        let value = AppModel(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), notifications: ReviewNotifications())
        value.settings.enabled = false; value.workspacePreferences.memoryEnabled = false
        return value
    }
    @MainActor func testFileImportStaysWithOriginSessionAfterSwitch() async throws {
        let model = model(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        await model.restoreChatSessions(); let first = model.activeSessionID
        let second = await model.createChatSession(title: "另一件事")
        try await model.addChatData(Data("只属于原会话".utf8), name: "原会话.txt", mime: "text/plain", sessionID: first)
        XCTAssertEqual(model.activeSessionID, second); XCTAssertTrue(model.chatMaterials.isEmpty)
        model.switchChatSession(first); XCTAssertEqual(model.chatMaterials.map(\.name), ["原会话.txt"])
        let saved = try await model.store.object(ChatSession.self, kind: "chat-session", id: first)
        XCTAssertEqual(saved?.materials.count, 1)
    }
    @MainActor func testParallelImportsCannotExceedLimit() async throws {
        let model = model(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        await model.restoreChatSessions()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<12 { group.addTask { try? await model.addChatData(Data("test".utf8), name: "file\(i).txt", mime: "text/plain") } }
        }
        XCTAssertEqual(model.chatMaterials.count, 8)
        XCTAssertEqual(Set(model.chatMaterials.map(\.id)).count, 8)
    }
    @MainActor func testEmptySubmissionDoesNotConsumeOneRoundContext() async throws {
        let model = model(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        await model.restoreChatSessions(); model.chatPinnedContext = .init(page: "materials", label: "本轮带入资料")
        model.beginSidebarChat()
        XCTAssertNil(model.sidebarTask); XCTAssertEqual(model.chatPinnedContext?.page, "materials")
        model.chatInput = "分析资料"; model.beginSidebarChat()
        XCTAssertNil(model.chatPinnedContext)
        await model.sidebarTask?.value
    }
    @MainActor func testInvalidModelConfigurationDoesNotReplaceActiveSettings() async throws {
        let model = model(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        var draft = model.settings; draft.provider = "openai"; draft.openAIURL = "http://remote.example.com/v1"; draft.openAIModel = "test"
        do { try await model.saveModelConfiguration(draft); XCTFail("invalid URL accepted") } catch { }
        XCTAssertEqual(model.settings.provider, "auto")
        let before = try await model.store.load(AgentSettings.self, kind: "settings")
        XCTAssertTrue(before.isEmpty)
        draft.provider = "ollama"; draft.ollamaURL = "http://127.0.0.1:11434"; draft.model = "test-model"
        try await model.saveModelConfiguration(draft)
        XCTAssertEqual(model.settings.model, "test-model"); XCTAssertFalse(model.settings.enabled)
        let stored = try await model.store.load(AgentSettings.self, kind: "settings")
        XCTAssertEqual(stored.first?.model, "test-model")
    }
    @MainActor func testHostScopeRejectsOtherMailAccountAndMaterialsMutation() throws {
        let model = model(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        let a = MailMessage(accountID: "a", from: .init(email: "a@example.com"), subject: "A", text: "")
        let b = MailMessage(accountID: "b", from: .init(email: "b@example.com"), subject: "B", text: "")
        model.mails = [a,b]
        var context = WorkspaceContext(page: "mail", label: "A", mailIDs: [a.id]); context.accountID = "a"
        XCTAssertThrowsError(try model.validateChatOperation(.init(type: "star", messageID: b.id), context: context))
        XCTAssertThrowsError(try model.validateChatOperation(.init(type: "draft", messageID: a.id, accountID: "b"), context: context))
        XCTAssertNoThrow(try model.validateChatOperation(.init(type: "draft", messageID: a.id, accountID: "a"), context: context))
        XCTAssertThrowsError(try model.validateChatOperation(.init(type: "createFolder", text: "New", accountID: "b"), context: .init(page: "materials", label: "资料")))
        XCTAssertNoThrow(try model.validateChatOperation(.init(type: "draft", text: "文档生成的草稿"), context: .init(page: "materials", label: "资料")))
        var draftContext = WorkspaceContext(page: "draft", label: "固定A"); draftContext.draftID = "A"
        XCTAssertThrowsError(try model.validateChatOperation(.init(type: "updateDraft", text: "修改", kind: "B"), context: draftContext))
    }
    @MainActor func testMemoryRevocationAndCorrectionDuringEmbeddingUseLatestState() async throws {
        let model = model(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        model.workspacePreferences.memoryEnabled = true
        // This controlled embedding boundary yields while the user's edit is persisted.
        var old = AgentMemory(content: "过时的英文偏好", kind: .preference); old.confirmed = true; old.topicKey = "language"
        model.memories = [old]; model.workspacePreferences.memoryEnabled = false; try await model.saveMemory(old); model.workspacePreferences.memoryEnabled = true
        let paused = await model.memoryPrompt("语言", context: nil, embed: { _ in await model.changeMemoryState(old.id, status: "paused"); return nil })
        XCTAssertFalse(paused.contains(old.content)); XCTAssertTrue(model.retrievedMemoryIDs[model.activeSessionID]?.isEmpty ?? true)
        await model.changeMemoryState(old.id, status: "active")
        var new = AgentMemory(content: "新确认的中文偏好", kind: .preference); new.confirmed = true; new.topicKey = "language"
        let corrected = await model.memoryPrompt("语言", context: nil, embed: { _ in try? await model.saveMemory(new, supersede: true); return nil })
        XCTAssertFalse(corrected.contains(old.content)); XCTAssertTrue(corrected.contains(new.content))
        let disabled = await model.memoryPrompt("语言", context: nil, embed: { _ in model.workspacePreferences.memoryEnabled = false; return nil })
        XCTAssertEqual(disabled, "")
    }
    @MainActor func testExplicitRepeatOfExpiredMemoryCreatesUsableEvidence() async throws {
        let model = model(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        await model.restoreChatSessions()
        var expired = AgentMemory(content: "以后用中文", kind: .preference); expired.confirmed = true; expired.expiresAt = .distantPast
        try await model.saveMemory(expired)
        await model.rememberFromChat("以后用中文", context: .init(page: "global", label: "全局"), user: "记住：以后用中文")
        let current = model.memories.filter { $0.eligible(sessionID: model.activeSessionID, contactEmail: nil) }
        XCTAssertEqual(current.count, 1); XCTAssertEqual(current.first?.content, expired.content)
        XCTAssertTrue(model.visibleChat.last?.text.hasPrefix("已记住") ?? false)
    }
    @MainActor func testNewComposeAndFolderSelectionUseCurrentAccount() async throws {
        let model = model(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        var a = MailAccount(); a.id = "a"; a.isDemo = true
        var b = a; b.id = "b"; model.accounts = [a,b]
        model.chooseMailbox("b"); await model.compose(); XCTAssertEqual(model.composer?.accountID, "b")
        model.selectedID = "old-mail"; model.searchText = "old-query"; model.searchMode = true
        model.chooseFolder(.init(accountID: "b", path: "Archive", role: "archive"))
        XCTAssertNil(model.selectedID); XCTAssertNil(model.composer); XCTAssertFalse(model.searchMode); XCTAssertEqual(model.searchText, "")
        XCTAssertEqual(model.selectedFolder, "Archive"); XCTAssertEqual(model.selectedAccount, "b")
    }
}
@MainActor private final class ReviewNotifications: MailNotificationManaging {
    func removePending(_ ids: [String]) {}
    func requestAuthorization() async throws -> Bool { false }
    func add(id: String, title: String, body: String, at date: Date?) async throws {}
}
