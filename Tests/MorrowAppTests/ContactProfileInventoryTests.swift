import XCTest
import MorrowCore
@testable import MorrowApp

final class ContactProfileInventoryTests: XCTestCase {
    func testStreamingInventoryPreservesExistingDigestAcrossUTF8Boundaries() {
        var mail = MailMessage(accountID: "first", from: .init(name: "发件人", email: "sender@example.invalid"), subject: "历史邮件", text: String(repeating: "中文é📬\n", count: 20_000))
        mail.messageID = "<synthetic@example.invalid>"
        mail.to = [.init(name: "收件人", email: "me@example.invalid")]
        mail.cc = [.init(name: "另一位", email: "peer@example.invalid")]
        var contact = ContactEntry(); contact.name = "手动联系人"; contact.email = "manual@example.invalid"
        var account = MailAccount(); account.id = "first"; account.email = "me@example.invalid"
        let participants = ContactProfileBuilder.participants(mail).map { $0.name + $0.email }.joined()
        let legacyBytes = Data((mail.canonicalID + mail.subject + mail.text + participants + contact.name + contact.email + account.id + account.email).utf8)
        XCTAssertGreaterThan(mail.text.utf8.count, 64 * 1024)
        XCTAssertEqual(ContactProfileInventory.fingerprint(mails: [mail], contacts: [contact], accounts: [account]), MailStore.hash(legacyBytes))
        XCTAssertEqual(ContactProfileInventory.fingerprint(mails: [], contacts: [], accounts: []), MailStore.hash(Data()))
    }

    func testInventoryCoversEveryMailboxAndContentChangeWithoutReadFlagChurn() {
        var first = MailMessage(accountID: "first", from: .init(email: "sender@example.invalid"), subject: "A", text: "first body")
        var second = MailMessage(accountID: "second", from: .init(email: "other@example.invalid"), subject: "B", text: "second body")
        var a = MailAccount(); a.id = "first"; a.email = "first@example.invalid"
        var b = MailAccount(); b.id = "second"; b.email = "second@example.invalid"
        let baseline = ContactProfileInventory.fingerprint(mails: [first, second], contacts: [], accounts: [a, b])
        first.isRead = true; first.isStarred = true
        XCTAssertEqual(ContactProfileInventory.fingerprint(mails: [first, second], contacts: [], accounts: [a, b]), baseline)
        second.text += " new evidence"
        XCTAssertNotEqual(ContactProfileInventory.fingerprint(mails: [first, second], contacts: [], accounts: [a, b]), baseline)
        XCTAssertNotEqual(ContactProfileInventory.fingerprint(mails: [first], contacts: [], accounts: [a, b]), baseline)
        second.text = "second body"; second.cc = [.init(email: "new-person@example.invalid")]
        XCTAssertNotEqual(ContactProfileInventory.fingerprint(mails: [first, second], contacts: [], accounts: [a, b]), baseline)
        second.cc = []; b.email = "changed@example.invalid"
        XCTAssertNotEqual(ContactProfileInventory.fingerprint(mails: [first, second], contacts: [], accounts: [a, b]), baseline)
        b.email = "second@example.invalid"
        var manual = ContactEntry(); manual.name = "Manual"; manual.email = "manual@example.invalid"
        XCTAssertNotEqual(ContactProfileInventory.fingerprint(mails: [first, second], contacts: [manual], accounts: [a, b]), baseline)
    }
}
