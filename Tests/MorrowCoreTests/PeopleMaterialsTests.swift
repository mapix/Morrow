import XCTest
@testable import MorrowCore

final class PeopleMaterialsTests: XCTestCase {
    func testHistoryDiscoversHeaderParticipantsAndDeduplicatesMailboxCopies() {
        var account = MailAccount(); account.id = "a"; account.email = "me@example.com"
        var first = MailMessage(accountID: "a", from: .init(name: "陈岚", email: "CLIENT@example.com"), subject: "合同", text: "负责项目交付")
        first.messageID = "<one@example.com>"; first.to = [.init(email: "me@example.com")]; first.cc = [.init(name: "财务", email: "finance@example.com")]; first.replyTo = [.init(email: "reply@example.com")]
        var copy = first; copy.id = "copy"; copy.folder = "Archive"
        var sent = MailMessage(accountID: "a", from: .init(email: "me@example.com"), subject: "Re: 合同", text: "收到")
        sent.messageID = "<two@example.com>"; sent.to = [.init(name: "陈岚", email: "client@example.com")]; sent.bcc = [.init(email: "hidden@example.com")]
        let profiles = ContactProfileBuilder.build(mails: [first, copy, sent], accounts: [account], manual: [])
        XCTAssertEqual(Set(profiles.map(\.email)), Set(["client@example.com", "finance@example.com", "reply@example.com", "hidden@example.com"]))
        let client = profiles.first { $0.email == "client@example.com" }!
        XCTAssertEqual(client.mailCount, 2); XCTAssertEqual(client.received, 1); XCTAssertEqual(client.sent, 1); XCTAssertEqual(client.name, "陈岚")
    }
    func testCorrectionSurvivesHistoryRefreshAndSourceQuotesAreRequired() {
        var account = MailAccount(); account.email = "me@example.com"
        let mail = MailMessage(accountID: account.id, from: .init(name: "项目组", email: "team@example.com"), subject: "项目评审", text: "我负责材料清单。")
        var profiles = ContactProfileBuilder.build(mails: [mail], accounts: [account], manual: [])
        profiles[0].correction = "是外部项目联系人，职务未确认"
        let newMail = MailMessage(accountID: account.id, from: mail.from, subject: "排期", text: "下周讨论")
        let changed = ContactProfileBuilder.build(mails: [mail, newMail], accounts: [account], manual: [], previous: profiles)
        XCTAssertEqual(changed[0].correction, profiles[0].correction); XCTAssertNotEqual(changed[0].fingerprint, profiles[0].fingerprint)
        let claims = [.init(text: "负责材料", mailID: mail.id, quote: "我负责材料清单。"), ProfileClaim(text: "总监", mailID: mail.id, quote: "总监"), ProfileClaim(text: "未知", mailID: "missing", quote: "我负责材料清单。")]
        XCTAssertEqual(ContactProfileBuilder.validatedClaims(claims, mails: [mail]).count, 1)
    }
    func testAttachmentIndexPreservesSameNamedSlotsButCollapsesCopies() {
        var mail = MailMessage(accountID: "a", from: .init(email: "sender@example.com"), subject: "材料", text: "")
        mail.messageID = "<material@example.com>"; mail.attachments = [.init(name: "报告.pdf", mimeType: "application/pdf", data: Data("one".utf8)), .init(name: "报告.pdf", mimeType: "application/pdf", data: Data("two".utf8))]
        var copy = mail; copy.id = "copy"; copy.folder = "Archive"
        let index = MailAttachmentRecord.index([mail, copy]); XCTAssertEqual(index.count, 2); XCTAssertNotEqual(index[0].id, index[1].id)
    }
    func testBccHistoryParsingAndOldChatDecodeRemainCompatible() throws {
        let mail = MIMEParser.parse(Data("From: me@example.com\r\nTo: user@example.com\r\nBcc: hidden@example.com\r\nSubject: test\r\n\r\nHello".utf8), accountID: "a")
        XCTAssertEqual(mail.bcc?.first?.email, "hidden@example.com")
        let old = Data("{\"id\":\"old\",\"role\":\"user\",\"text\":\"hi\",\"date\":0,\"messageIDs\":[]}".utf8)
        let chat = try JSONDecoder().decode(PartnerChat.self, from: old); XCTAssertNil(chat.context); XCTAssertNil(chat.materials)
    }
}
