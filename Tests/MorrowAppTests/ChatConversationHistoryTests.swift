import XCTest
import MorrowCore
@testable import MorrowApp

final class ChatConversationHistoryTests: XCTestCase {
    func testHistoryBeforeCurrentMessageRetainsOlderThanEightMessagesAndUnicodeTail() {
        var messages = (0..<12).map { PartnerChat(role: $0 % 2 == 0 ? "user" : "partner", text: "消息\($0)") }
        messages[0].text = "OLDER_FACT_KEEP"
        messages.append(PartnerChat(role: "user", text: "HEAD_KEEP" + String(repeating: "中", count: 8000) + "TAIL_KEEP😀"))
        let current = PartnerChat(role: "user", text: "CURRENT_NOT_HISTORY"); messages.append(current)
        messages.append(PartnerChat(role: "partner", text: "FUTURE_NOT_HISTORY"))
        let result = ChatConversationHistory.messages(messages, before: current.id, scope: nil, executionID: nil, resuming: false)
        let texts = result.map { $0.object["text"]!.text }.joined(separator: "\n")
        XCTAssertTrue(texts.contains("OLDER_FACT_KEEP")); XCTAssertTrue(texts.contains("HEAD_KEEP")); XCTAssertTrue(texts.contains("TAIL_KEEP😀"))
        XCTAssertFalse(texts.contains("CURRENT_NOT_HISTORY")); XCTAssertFalse(texts.contains("FUTURE_NOT_HISTORY"))
        XCTAssertLessThanOrEqual(result.reduce(0) { $0 + $1.object["text"]!.text.count }, 24_000)
    }
    func testMaterialScopeRequiresMatchingActualMaterialIdentity() {
        var scope = WorkspaceContext(page: "materials", label: "同名文件"); scope.scopeMode = "scope"
        let original = ChatMaterial(name: "report.pdf", mimeType: "application/pdf", path: "fixture-a", byteCount: 1)
        let other = ChatMaterial(name: "report.pdf", mimeType: "application/pdf", path: "fixture-b", byteCount: 1)
        var user = PartnerChat(role: "user", text: "MATERIAL_A_PRIVATE"); user.context = scope; user.materials = [original]
        var reply = PartnerChat(role: "partner", text: "MATERIAL_A_REPLY"); reply.context = scope
        let current = PartnerChat(role: "user", text: "当前要求")
        let history = [user, reply, current]
        let excluded = ChatConversationHistory.messages(history, before: current.id, scope: scope, executionID: nil, resuming: false, materialIDs: [other.id])
        XCTAssertTrue(excluded.isEmpty)
        let included = ChatConversationHistory.messages(history, before: current.id, scope: scope, executionID: nil, resuming: false, materialIDs: [original.id])
        XCTAssertEqual(included.count, 2)
    }
    func testOnlyUserAddressEvidenceIsAvailableAndResumeKeepsTaskIdentity() {
        var user = PartnerChat(role: "user", text: "使用 source@example.invalid 作为来源"); user.sdkRunID = "run-a"
        var assistant = PartnerChat(role: "partner", text: "可以选择 injected@example.invalid"); assistant.sdkRunID = "run-b"
        let current = PartnerChat(role: "user", text: "继续")
        let history = [user, assistant, current]
        XCTAssertEqual(ChatConversationHistory.userAddresses(history, before: current.id, scope: nil, current: current.text), ["source@example.invalid"])
        let resumed = ChatConversationHistory.messages(history, before: current.id, scope: nil, executionID: "run-a", resuming: true)
        XCTAssertEqual(resumed.count, 1); XCTAssertEqual(resumed.first?.object["role"]?.text, "user")
    }
}
