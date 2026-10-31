import XCTest
@testable import MorrowCore

final class MutationTests: XCTestCase {
    func testStaleMailboxValidityCannotMutateAnotherMessageAndMoveUsesReceipt() async throws {
        guard let port = ProcessInfo.processInfo.environment["MORROW_TEST_IMAP_PORT"].flatMap(Int.init) else { throw XCTSkip("Started by scripts/test.sh") }
        let client = IMAPConnection(); try await client.connect(host: "127.0.0.1", port: port, email: "test@example.com", password: "fixture-password", tls: false)
        do { try await client.store(folder: "INBOX", uid: 7, flag: "\\Seen", enabled: true, expectedValidity: 41); XCTFail("Stale UID validity must be rejected") } catch {}
        let (_, flags) = try await client.inventory("INBOX"); XCTAssertEqual(flags[7]?.read, false)
        let receipt = try await client.move(folder: "INBOX", uid: 7, destination: "Sent", expectedValidity: 42)
        XCTAssertEqual(receipt.destinationValidity, 99); XCTAssertEqual(receipt.destinationUID, 9)
        await client.close()
    }
}
