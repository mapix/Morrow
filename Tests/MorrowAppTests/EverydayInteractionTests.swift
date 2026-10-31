import XCTest
import MorrowCore
@testable import MorrowApp

final class EverydayInteractionTests: XCTestCase {
    @MainActor private func makeModel() -> AppModel {
        let model = AppModel(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), notifications: EverydayNotifications())
        model.settings.enabled = false
        model.workspacePreferences.memoryEnabled = false
        return model
    }

    @MainActor func testMemoryReferenceOpensOnlyActualMemoriesIncludingPausedOnes() {
        let model = makeModel()
        defer { try? FileManager.default.removeItem(at: model.store.root) }
        let unrelated = AgentMemory(content: "另一条记忆")
        let first = AgentMemory(content: "本次第一条记忆")
        var paused = AgentMemory(content: "引用后已停用的记忆"); paused.status = "paused"
        model.memories = [unrelated, paused, first]
        model.composer = ComposeDraft()

        model.revealMemories([first.id, paused.id, first.id])

        XCTAssertEqual(model.workspacePage, .memory)
        XCTAssertNil(model.composer)
        XCTAssertEqual(model.memoryRevealIDs, [first.id, paused.id])
        XCTAssertEqual(model.revealedMemories.map(\.content), [first.content, paused.content])
        XCTAssertEqual(model.revealedMemories.last?.status, "paused")
    }

    @MainActor func testEditingSuggestedMemoryConfirmsUsageAndPreservesEvidence() async throws {
        let model = makeModel()
        defer { try? FileManager.default.removeItem(at: model.store.root) }
        var entry = AgentMemory(content: "候选偏好", kind: .preference)
        entry.status = "suggested"; entry.source = "自动候选"; entry.evidence = "用户的原始陈述"
        try await model.saveMemory(entry)
        entry.content = "用户修正后的偏好"

        try await model.saveUserEditedMemory(entry)

        let saved = try XCTUnwrap(model.memories.first { $0.id == entry.id })
        XCTAssertEqual(saved.status, "active")
        XCTAssertTrue(saved.confirmed)
        XCTAssertEqual(saved.source, "用户编辑")
        XCTAssertEqual(saved.evidence, "用户的原始陈述")
        XCTAssertEqual(saved.revisions.last?.content, "候选偏好")
        XCTAssertTrue(saved.eligible(sessionID: nil, contactEmail: nil))
        let stored = try await model.store.load(AgentMemory.self, kind: "agent-memory")
        XCTAssertEqual(stored.first?.status, "active")
    }

    @MainActor func testEditingPausedAndForgottenMemoriesDoesNotRestoreUsage() async throws {
        let model = makeModel()
        defer { try? FileManager.default.removeItem(at: model.store.root) }
        for state in ["paused", "forgotten", "superseded"] {
            var entry = AgentMemory(content: "\(state)记忆"); entry.status = state
            try await model.saveUserEditedMemory(entry)
            let saved = try XCTUnwrap(model.memories.first { $0.id == entry.id })
            XCTAssertEqual(saved.status, state)
            XCTAssertFalse(saved.eligible(sessionID: nil, contactEmail: nil))
        }
    }

    @MainActor func testArchivedSourceRestoresOpensAndCurrentSourceReopensChat() async throws {
        let model = makeModel()
        defer { try? FileManager.default.removeItem(at: model.store.root) }
        await model.restoreChatSessions()
        let sourceID = model.activeSessionID
        var original = PartnerChat(role: "user", text: "记忆的实际来源"); original.sessionID = sourceID
        try await model.recordChat(original)
        _ = await model.createChatSession(title: "另一会话")
        await model.archiveChatSession(sourceID)
        model.chatExpanded = false

        await model.openSessionSource(sourceID, chatID: original.id)

        XCTAssertEqual(model.activeSessionID, sourceID)
        XCTAssertTrue(model.chatExpanded)
        XCTAssertEqual(model.scrollChatID, original.id)
        XCTAssertEqual(model.visibleChat.map(\.text), [original.text])
        XCTAssertFalse(try XCTUnwrap(model.chatSessions.first { $0.id == sourceID }).archived)
        let stored = try await model.store.load(ChatSession.self, kind: "chat-session")
        XCTAssertFalse(try XCTUnwrap(stored.first { $0.id == sourceID }).archived)

        model.chatExpanded = false
        let previousFocus = model.chatFocusNonce
        await model.openSessionSource(sourceID, chatID: original.id)
        XCTAssertTrue(model.chatExpanded)
        XCTAssertGreaterThan(model.chatFocusNonce, previousFocus)
        XCTAssertEqual(model.scrollChatID, original.id)
    }

    @MainActor func testMissingSourceMessageReportsFailureWithoutRestoringArchive() async throws {
        let model = makeModel()
        defer { try? FileManager.default.removeItem(at: model.store.root) }
        await model.restoreChatSessions()
        let sourceID = model.activeSessionID
        let currentID = await model.createChatSession(title: "当前会话")
        await model.archiveChatSession(sourceID)

        await model.openSessionSource(sourceID, chatID: "missing-message")

        XCTAssertEqual(model.activeSessionID, currentID)
        XCTAssertTrue(try XCTUnwrap(model.chatSessions.first { $0.id == sourceID }).archived)
        XCTAssertEqual(model.error, "来源消息已不存在。")
    }
}

@MainActor private final class EverydayNotifications: MailNotificationManaging {
    func removePending(_ ids: [String]) {}
    func requestAuthorization() async throws -> Bool { false }
    func add(id: String, title: String, body: String, at date: Date?) async throws {}
}
