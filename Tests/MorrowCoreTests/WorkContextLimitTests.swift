import XCTest
@testable import MorrowCore

final class WorkContextLimitTests: XCTestCase {
    private func mail(_ account: String = "a", sender: String = "lin@example.com", subject: String = "项目") -> MailMessage {
        MailMessage(accountID: account, from: .init(email: sender), subject: subject, text: "核对资料")
    }
    func testContactFutureRequiresParticipationAndSubmittedAccount() {
        let original = mail()
        let limit = WorkContextLimit(kind: .contact, label: "林舟", existingMailIDs: [original.canonicalID], accountIDs: ["a", "b"], contactEmail: "lin@example.com", allowsFuture: true)
        var outgoing = mail("b", sender: "me@example.com"); outgoing.to = [.init(email: "LIN@example.com")]
        var copied = mail("a", sender: "team@example.com"); copied.cc = [.init(email: "lin@example.com")]
        XCTAssertTrue(limit.contains(original)); XCTAssertTrue(limit.contains(outgoing)); XCTAssertTrue(limit.contains(copied))
        XCTAssertFalse(limit.contains(mail("c"))); XCTAssertFalse(limit.contains(mail("a", sender: "other@example.com")))
        var agreement = WorkAgreement(goal: "跟进", doneWhen: "已确认", scope: "项目", boundaries: [], steps: [])
        agreement.hostScope = limit; agreement.resolvedScope = WorkScope(sourceMailIDs: [original.id], subjectTerms: ["项目"])
        XCTAssertTrue(agreement.contains(outgoing)); XCTAssertFalse(agreement.contains(mail("c"))); XCTAssertFalse(agreement.contains(mail("a", sender: "other@example.com")))
    }
    func testSelectionCannotExpandFromModelSourcesOrFutureTerms() {
        let selected = mail(), excluded = mail(sender: "other@example.com")
        let limit = WorkContextLimit(kind: .selection, label: "指定邮件", existingMailIDs: [selected.canonicalID], accountIDs: ["a"], allowsFuture: true)
        let broad = WorkScope(sourceMailIDs: [selected.id, excluded.id], subjectTerms: ["项目"], senderEmails: ["lin@example.com"])
        let result = limit.constrain(broad, against: [selected, excluded])
        XCTAssertTrue(result.contains(selected)); XCTAssertFalse(result.contains(excluded)); XCTAssertFalse(result.contains(mail()))
        XCTAssertTrue(result.subjectTerms.isEmpty); XCTAssertTrue(result.senderEmails.isEmpty)
    }
    func testMailboxCeilingSurvivesCodingAndDoesNotReadExcludedExistingMail() throws {
        let selected = mail(), excluded = mail(sender: "other@example.com")
        var agreement = WorkAgreement(goal: "跟进", doneWhen: "已确认", scope: "邮箱A项目新邮件", boundaries: [], steps: [])
        let limit = WorkContextLimit(kind: .mailbox, label: "邮箱A", existingMailIDs: [selected.id], accountIDs: ["a"], allowsFuture: true)
        agreement.hostScope = limit; agreement.resolvedScope = limit.constrain(WorkScope(sourceMailIDs: [selected.id, excluded.id], subjectTerms: ["项目"]), against: [selected, excluded])
        let restored = try JSONDecoder().decode(WorkAgreement.self, from: JSONEncoder().encode(agreement))
        XCTAssertEqual(restored.hostScope, limit); XCTAssertTrue(restored.contains(selected)); XCTAssertFalse(restored.contains(excluded))
        XCTAssertTrue(restored.contains(mail())); XCTAssertFalse(restored.contains(mail("b")))
        let legacy = WorkAgreement(goal: "旧委托", doneWhen: "完成", scope: "项目", boundaries: [], steps: [])
        XCTAssertNil(try JSONDecoder().decode(WorkAgreement.self, from: JSONEncoder().encode(legacy)).hostScope)
    }
}
