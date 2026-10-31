import XCTest
@testable import MorrowCore

final class WorkScopeTests: XCTestCase {
    func testModelCommaSeparatedTopicsMatchIndependently() {
        let mail = MailMessage(accountID: "demo", from: .init(email: "partner@example.com"), subject: "合同对比：更新条款", text: "交付45天")
        XCTAssertTrue(WorkScope.matches("合同对比, 条款更新, 审核", mail: mail))
        XCTAssertFalse(WorkScope.matches("账单核对，评审邀请", mail: mail))
    }
    func testPinnedScopeSurvivesMailboxCopiesAndDoesNotReadOtherTopics() {
        var contract = MailMessage(accountID: "demo", from: .init(email: "partner@example.com"), subject: "合同对比：旧版条款", text: "旧版")
        contract.messageID = "<same@example.com>"
        let scope = WorkScope(sourceMailIDs: [contract.id], subjectTerms: ["合同对比"], senderEmails: ["partner@example.com"]).validated(against: [contract])
        var copy = contract; copy.id = "archive-copy"; copy.folder = "Archive"
        XCTAssertTrue(scope.contains(copy))
        let unrelated = MailMessage(accountID: "demo", from: .init(email: "partner@example.com"), subject: "账单核对", text: "正文引用合同对比")
        XCTAssertFalse(scope.contains(unrelated))
        let wrongSender = MailMessage(accountID: "demo", from: .init(email: "other@example.com"), subject: "合同对比：新稿", text: "新稿")
        XCTAssertFalse(scope.contains(wrongSender))
        XCTAssertFalse(WorkScope().contains(contract))
    }
    func testFutureMatchingDoesNotExpandExistingSelectedScope() {
        let chosen = MailMessage(accountID: "demo", from: .init(email: "partner@example.com"), subject: "合同对比：更新条款", text: "更新")
        var excluded = MailMessage(accountID: "demo", from: .init(email: "partner@example.com"), subject: "合同条款需要你审核", text: "另一份合同"); excluded.messageID = "<excluded@example.com>"
        let scope = WorkScope(sourceMailIDs: [chosen.id], subjectTerms: ["合同对比", "合同条款"]).validated(against: [chosen, excluded])
        XCTAssertTrue(scope.contains(chosen)); XCTAssertFalse(scope.contains(excluded))
        var copy = excluded; copy.id = "other-folder-copy"; copy.messageID = excluded.messageID
        XCTAssertFalse(scope.contains(copy))
        let later = MailMessage(accountID: "demo", from: .init(email: "partner@example.com"), subject: "合同对比：验收条款补充", text: "补充")
        XCTAssertTrue(scope.contains(later))
    }
    func testLiveEditedScopeResolvesOnlySpecifiedContracts() async throws {
        guard ProcessInfo.processInfo.environment["MORROW_LIVE_WORK"] == "1" else { throw XCTSkip("Set MORROW_LIVE_WORK=1 for actual scope inference") }
        let old = MailMessage(accountID: "demo", from: .init(email: "legal@example.com"), subject: "合同对比：旧版条款", text: "旧版")
        let new = MailMessage(accountID: "demo", from: .init(email: "partner@example.com"), subject: "合同对比：更新条款", text: "更新")
        let other = MailMessage(accountID: "demo", from: .init(email: "partner@example.com"), subject: "合同条款需要你审核", text: "其他合同")
        var settings = AgentSettings(); settings.provider = "ollama"; settings.model = "qwen3.8:27b-mlx"
        let scope = try await PartnerEngine().resolveScope("仅合同对比：旧版条款、合同对比：更新条款及后续相关合同对比邮件", mails: [old, new, other], settings: settings)
        XCTAssertTrue(scope.contains(old)); XCTAssertTrue(scope.contains(new)); XCTAssertFalse(scope.contains(other))
        XCTAssertTrue(scope.contains(MailMessage(accountID: "demo", from: .init(email: "partner@example.com"), subject: "合同对比：验收条款补充", text: "新消息")))
    }
}
