import XCTest
import MorrowCore
import Combine
@testable import MorrowApp

final class ChatInputCompositionTests: XCTestCase {
    @MainActor func testTypingInLargeWorkspaceDoesNotInvalidateTheSharedAppModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("input-isolation-" + UUID().uuidString)
        let model = AppModel(root: root); model.settings.enabled = false
        defer { model.sessionDraftTask?.cancel(); try? FileManager.default.removeItem(at: root) }
        let sessions = (0..<500).map { ChatSession(id: "session-\($0)", title: "Synthetic conversation \($0)") }
        model.chatSessions = sessions; model.activeSessionID = sessions[0].id
        try await model.store.save(sessions[0], kind: "chat-session", id: sessions[0].id)
        let mail = MailMessage(accountID: "synthetic", from: .init(name: "Synthetic person", email: "person@example.invalid"), subject: "Fixture", text: "")
        let template = try XCTUnwrap(ContactProfileBuilder.build(mails: [mail], accounts: [], manual: []).first)
        model.contactProfiles = (0..<20000).map { index in var profile = template; profile.email = "person-\(index)@example.invalid"; return profile }
        var globalChanges = 0, inputChanges = 0
        let global = model.objectWillChange.sink { globalChanges += 1 }
        let local = model.chatInputState.objectWillChange.sink { inputChanges += 1 }
        let start = ProcessInfo.processInfo.systemUptime
        for index in 1...400 { model.setChatEditorInput(String(repeating: "字", count: index), in: sessions[0].id) }
        let elapsed = (ProcessInfo.processInfo.systemUptime - start) * 1000
        XCTAssertEqual(model.chatInput.count, 400); XCTAssertEqual(inputChanges, 400)
        XCTAssertEqual(globalChanges, 0, "Keystrokes must not invalidate contacts, mailbox and conversation history")
        try await Task.sleep(for: .milliseconds(420))
        XCTAssertEqual(globalChanges, 0, "Saving a draft must not invalidate the shared workspace either")
        let saved = try await model.store.object(ChatSession.self, kind: "chat-session", id: sessions[0].id)
        XCTAssertEqual(saved?.input, model.chatInput)
        print("CHAT_INPUT_ISOLATION: contacts=20000; sessions=500; edits=400; edit_ms=\(elapsed); immediate_app_notifications=0; settled_notifications=\(globalChanges)")
        withExtendedLifetime((global, local)) {}
    }
    @MainActor func testSettledDraftKeepsAConcurrentSessionRename() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("input-rename-" + UUID().uuidString)
        let model = AppModel(root: root); model.settings.enabled = false
        defer { model.sessionDraftTask?.cancel(); try? FileManager.default.removeItem(at: root) }
        await model.restoreChatSessions(); let session = model.activeSessionID
        model.setChatEditorInput("A pending native edit", in: session)
        await model.renameChatSession(session, title: "Renamed while typing")
        try await Task.sleep(for: .milliseconds(420))
        XCTAssertEqual(model.activeSession?.title, "Renamed while typing")
        XCTAssertEqual(model.activeSession?.input, "A pending native edit")
        let saved = try await model.store.object(ChatSession.self, kind: "chat-session", id: session)
        XCTAssertEqual(saved?.title, "Renamed while typing"); XCTAssertEqual(saved?.input, "A pending native edit")
    }
    @MainActor func testImmediateQuitFlushesTheLastEditBeforeDebounce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("input-quit-" + UUID().uuidString)
        let model = AppModel(root: root); model.settings.enabled = false
        defer { model.sessionDraftTask?.cancel(); try? FileManager.default.removeItem(at: root) }
        await model.restoreChatSessions(); let session = model.activeSessionID
        model.setChatEditorInput("Last edit before quitting", in: session)
        try await model.flushCurrentSessionDraft()
        let saved = try await model.store.object(ChatSession.self, kind: "chat-session", id: session)
        XCTAssertEqual(saved?.input, "Last edit before quitting")
    }
    func testModelEchoCannotReplaceMarkedChineseComposition() {
        XCTAssertNil(ChatEditorSynchronization.replacement(model: "你好", native: "你好zhongwen", hasMarkedText: true))
        XCTAssertNil(ChatEditorSynchronization.replacement(model: "", native: "zhong", hasMarkedText: true))
        XCTAssertNil(ChatEditorSynchronization.replacement(model: "你好中文", native: "你好中文", hasMarkedText: false))
        XCTAssertEqual(ChatEditorSynchronization.replacement(model: "新的明确输入", native: "旧输入", hasMarkedText: false), "新的明确输入")
        XCTAssertTrue(ChatEditorSynchronization.isPendingModelEcho(model: "你好", native: "你好中文", publishedNative: "你好中文", previousModel: "你好"))
        XCTAssertFalse(ChatEditorSynchronization.isPendingModelEcho(model: "你好中文", native: "你好中文", publishedNative: "你好中文", previousModel: "你好"))
        XCTAssertFalse(ChatEditorSynchronization.isPendingModelEcho(model: "明确替换", native: "你好中文", publishedNative: "你好中文", previousModel: "你好"))
    }
    func testProgrammaticChangesPreserveSelectionAndEndCaretInUTF16Coordinates() {
        let original = "你好💌继续"
        let appended = original + "输入"
        let end = NSRange(location: original.utf16.count, length: 0)
        XCTAssertEqual(ChatEditorSynchronization.selection(end, replacing: original, with: appended), NSRange(location: appended.utf16.count, length: 0))
        let selectedEmoji = NSRange(location: 2, length: 2)
        XCTAssertEqual(ChatEditorSynchronization.selection(selectedEmoji, replacing: original, with: appended), selectedEmoji)
        XCTAssertEqual(ChatEditorSynchronization.selection(NSRange(location: 8, length: 20), replacing: original, with: "短"), NSRange(location: 1, length: 0))
        XCTAssertEqual(ChatEditorSynchronization.selection(NSRange(location: 0, length: 0), replacing: "", with: "新输入"), NSRange(location: 3, length: 0))
    }
    @MainActor func testLateCompositionCommitStaysWithOriginalSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ime-session-" + UUID().uuidString)
        let model = AppModel(root: root)
        model.settings.enabled = false; model.workspacePreferences.memoryEnabled = false
        defer { model.sessionDraftTask?.cancel(); try? FileManager.default.removeItem(at: root) }
        await model.restoreChatSessions()
        let first = model.activeSessionID
        model.setChatEditorInput("第一段已提交", in: first)
        let second = await model.createChatSession(title: "Second synthetic conversation")
        model.setChatEditorInput("第二段输入", in: second)
        // Simulates AppKit finishing the old view's IME after the new session
        // becomes active. Its binding remains explicitly owned by `first`.
        model.setChatEditorInput("第一段已提交中文", in: first)
        XCTAssertEqual(model.activeSessionID, second)
        XCTAssertEqual(model.chatInput, "第二段输入")
        XCTAssertEqual(model.chatEditorInput(in: first), "第一段已提交中文")
        model.switchChatSession(first)
        XCTAssertEqual(model.chatInput, "第一段已提交中文")
        XCTAssertEqual(model.chatEditorInput(in: second), "第二段输入")
        var stored: ChatSession?
        for _ in 0..<50 {
            stored = try await model.store.object(ChatSession.self, kind: "chat-session", id: first)
            if stored?.input == "第一段已提交中文" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(stored?.input, "第一段已提交中文")
    }
    @MainActor func testDebouncedDraftSaveUsesCapturedInputRatherThanLaterGlobalState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ime-draft-" + UUID().uuidString)
        let model = AppModel(root: root)
        model.settings.enabled = false; model.workspacePreferences.memoryEnabled = false
        defer { model.sessionDraftTask?.cancel(); try? FileManager.default.removeItem(at: root) }
        await model.restoreChatSessions()
        let session = model.activeSessionID
        model.chatInput = "本次输入快照"; model.scheduleSessionDraft()
        model.chatInput = "未排程的后续状态"
        try await Task.sleep(for: .milliseconds(380))
        let stored = try await model.store.object(ChatSession.self, kind: "chat-session", id: session)
        XCTAssertEqual(stored?.input, "本次输入快照")
    }
}
