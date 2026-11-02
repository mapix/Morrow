import XCTest
import MorrowCore
@testable import MorrowApp

@MainActor final class QualityChatMemoryTests: XCTestCase {
    func testQualityModeNeverSchedulesMemoryOrChatInferenceEvenWhenPreferencesEnableIt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quality-memory-chat-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(root: root, qualityPreview: .init(directory: root))
        model.settings.enabled = true; model.settings.autoAnalyze = true
        model.workspacePreferences.memoryEnabled = true; model.workspacePreferences.autoMemory = true
        model.settings.embeddingDirectory = root.appendingPathComponent("no-embedding-model").path
        model.memories = [AgentMemory(content: "本机验收资料，不允许推理", kind: .fact)]
        await model.restoreChatSessions()
        let human = PartnerChat(role: "user", text: "这段本机验收文字不应触发记忆提取或任何模型请求")
        model.scheduleMemoryIndex(); model.scheduleMemoryExtraction(human)
        try await model.recordChat(human)
        XCTAssertEqual(model.chat.count, 1, "Local history storage remains available to the renderer")
        model.chatInput = "应保留的未提交输入"
        model.beginSidebarChat()
        await model.submitSidebarChat()
        await model.askSDKPartner("禁止创建任何SDK任务", runID: nil, uiContext: nil, materials: [])
        await Task.yield()
        XCTAssertNil(model.memoryTask); XCTAssertNil(model.memoryExtractionTask); XCTAssertTrue(model.memoryExtractionQueue.isEmpty)
        XCTAssertNil(model.sidebarTask); XCTAssertFalse(model.partnerBusy)
        XCTAssertEqual(model.chatInput, "应保留的未提交输入"); XCTAssertEqual(model.chat.count, 1)
    }
    func testProtectedDraftPreviewReceiptsNeverClaimMailIsUnsent() {
        let unsent = DraftPresentationState("draft").previewReceipt
        XCTAssertEqual(DraftPresentationState("sent").previewReceipt, DraftPresentationState("sent").receipt)
        for value in ["sent", "queued", "sending", "uncertain"] { XCTAssertNotEqual(DraftPresentationState(value).previewReceipt, unsent) }
    }
}
