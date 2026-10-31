import XCTest
@testable import MorrowCore

final class POPTests: XCTestCase {
    func testRealPOPUIDLStableIdentityAndDotUnstuffing() async throws {
        guard let port = ProcessInfo.processInfo.environment["MORROW_TEST_POP_PORT"].flatMap(Int.init) else { throw XCTSkip("Started by scripts/test.sh") }
        let client = POP3Client(); try await client.connect(host: "127.0.0.1", port: port, email: "test@example.com", password: "fixture-password", tls: false)
        let ids = try await client.inventory(); XCTAssertEqual(ids["stable-id-1"], 1)
        let raw = try await client.fetch(number: 1, expectedUID: "stable-id-1")
        let message = MIMEParser.parse(raw, accountID: "test"); XCTAssertEqual(message.subject, "Fixture mail"); XCTAssertTrue(message.text.contains(".Leading dot")); XCTAssertFalse(message.text.contains("..Leading dot"))
        do { _ = try await client.fetch(number: 1, expectedUID: "wrong-id"); XCTFail("A shifted UID must not return the wrong message") } catch {}
        let after = try await client.inventory(); XCTAssertEqual(after, ids)
        await client.quit()
    }
    func testPlaintextPOPIsOnlyAllowedForLoopbackFixtures() async {
        let client = POP3Client()
        do { try await client.connect(host: "mail.example.com", port: 110, email: "test@example.com", password: "test", tls: false); XCTFail("Plaintext remote POP must be rejected") } catch {}
    }
    func testExistingAccountWithoutProtocolFieldStillDecodesAsIMAP() throws {
        var account = MailAccount(); account.email = "test@example.com"; account.imapHost = "imap.example.com"; account.smtpHost = "smtp.example.com"
        let data = try JSONEncoder().encode(account)
        let restored = try JSONDecoder().decode(MailAccount.self, from: data); XCTAssertFalse(restored.usesPOP)
        account.receiveProtocol = "pop3"; let pop = try JSONDecoder().decode(MailAccount.self, from: JSONEncoder().encode(account)); XCTAssertTrue(pop.usesPOP)
    }
}
