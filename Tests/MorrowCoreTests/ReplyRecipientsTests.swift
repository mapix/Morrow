import XCTest
@testable import MorrowCore

final class ReplyRecipientsTests: XCTestCase {
    private var mail: MailMessage {
        var mail = MailMessage(accountID: "self", from: .init(email: "me@example.invalid"), subject: "Project", text: "")
        mail.to = [.init(email: "client@example.invalid")]
        mail.cc = [.init(email: "colleague@example.invalid"), .init(email: "ME@example.invalid"), .init(email: "CLIENT@example.invalid")]
        return mail
    }
    func testSentReplyUsesOriginalRecipientsInsteadOfSelf() {
        let result = ReplyRecipients.resolve(mail: mail, ownEmails: ["me@example.invalid"], isSent: true, replyAll: false)
        XCTAssertEqual(result.to.map(\.email), ["client@example.invalid"]); XCTAssertTrue(result.cc.isEmpty)
    }
    func testSentReplyAllPreservesCCWithoutDuplicatesOrOwnAddresses() {
        let result = ReplyRecipients.resolve(mail: mail, ownEmails: ["me@example.invalid"], isSent: true, replyAll: true)
        XCTAssertEqual(result.to.map(\.email), ["client@example.invalid"]); XCTAssertEqual(result.cc.map(\.email), ["colleague@example.invalid"])
    }
    func testReceivedReplyToAndReplyAllKeepTheirDirection() {
        var received = mail; received.from = .init(email: "sender@example.invalid")
        received.replyTo = [.init(email: "support@example.invalid")]; received.to = [.init(email: "me@example.invalid")]
        let result = ReplyRecipients.resolve(mail: received, ownEmails: ["me@example.invalid"], isSent: false, replyAll: true)
        XCTAssertEqual(result.to.map(\.email), ["support@example.invalid"])
        XCTAssertEqual(Set(result.cc.map(\.email)), ["colleague@example.invalid", "CLIENT@example.invalid"])
    }
    func testSelfAddressedSentNoteStillHasAnExplicitRecipient() {
        var note = mail; note.to = [.init(email: "me@example.invalid")]; note.cc = []
        XCTAssertEqual(ReplyRecipients.resolve(mail: note, ownEmails: ["me@example.invalid"], isSent: true, replyAll: false).to.map(\.email), ["me@example.invalid"])
    }
}
