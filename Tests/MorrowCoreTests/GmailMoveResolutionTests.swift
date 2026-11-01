import XCTest
@testable import MorrowCore

final class GmailMoveResolutionTests: XCTestCase {
    private let folder = "[Gmail]/All Mail", global = "18230923993923822931"
    private func identity() -> GmailMessageIdentity {
        .init(accountID: "fixture", folder: "INBOX", uid: 7, validity: 42, globalID: global, messageID: "<move@example.invalid>", rawSize: 300)
    }
    private func select(_ value: UInt64) -> [String] { ["* OK [UIDVALIDITY \(value)] synthetic", "* 1 EXISTS"] }
    private func header(uid: UInt64, global: String? = nil, size: UInt64 = 300, messageID: String = "<move@example.invalid>") -> [String] {
        let data = "Message-ID: \(messageID)\r\n\r\n"
        return ["* 1 FETCH (UID \(uid) X-GM-MSGID \(global ?? self.global) RFC822.SIZE \(size) BODY[HEADER.FIELDS (MESSAGE-ID)] {\(data.utf8.count)}", data, ")"]
    }
    private func fetch(_ uid: UInt64) -> String { "UID FETCH \(uid) (UID X-GM-MSGID RFC822.SIZE BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])" }
    private func peer(_ steps: [(String, [String])]) throws -> PerformanceLoopbackPeer {
        try PerformanceLoopbackPeer { connection in
            _ = connection.write("* OK synthetic Gmail\r\n"); var position = 0
            while let line = connection.readLine() {
                let parts = line.split(separator: " ", maxSplits: 1); guard parts.count == 2 else { return }
                let tag = String(parts[0]), command = String(parts[1])
                if command == "CAPABILITY" { _ = connection.write("* CAPABILITY IMAP4rev1 UIDPLUS MOVE X-GM-EXT-1\r\n\(tag) OK capabilities\r\n"); continue }
                if command.hasPrefix("LOGIN ") { _ = connection.write(tag + " OK login\r\n"); continue }
                guard position < steps.count else { XCTFail("Unexpected command: " + command); _ = connection.write(tag + " BAD unexpected\r\n"); return }
                XCTAssertEqual(command, steps[position].0)
                let lines = steps[position].1; position += 1
                _ = connection.write((lines.isEmpty ? "" : lines.joined(separator: "\r\n") + "\r\n") + tag + " OK done\r\n")
            }
            XCTAssertEqual(position, steps.count)
        }
    }
    private func connect(_ peer: PerformanceLoopbackPeer) async throws -> IMAPConnection {
        let client = IMAPConnection()
        try await client.connect(host: "127.0.0.1", port: peer.port, email: "fixture@example.invalid", password: "synthetic", tls: false)
        return client
    }
    func testPreMoveSourceIdentityResolvesExistingLabelWithoutCopyUIDOrBodyFetch() async throws {
        let server = try peer([
            (#"SELECT "INBOX""#, select(42)), (fetch(7), header(uid: 7)),
            (#"SELECT "INBOX""#, select(42)), (#"UID MOVE 7 "[Gmail]/All Mail""#, []),
            (#"SELECT "[Gmail]/All Mail""#, select(11)), ("UID SEARCH X-GM-MSGID \(global)", ["* SEARCH 9"]),
            (#"SELECT "[Gmail]/All Mail""#, select(11)), (fetch(9), header(uid: 9))
        ]); defer { server.stop() }
        let client = try await connect(server)
        let before = try await client.gmailIdentities(accountID: "fixture", folder: "INBOX", uids: [7], expectedValidity: 42)
        let source = try XCTUnwrap(before[7])
        let receipt = try await client.move(folder: "INBOX", uid: 7, destination: folder, expectedValidity: 42)
        XCTAssertNil(receipt.destinationUID)
        let resolved = await client.resolveGmailMove(accountID: "fixture", sourceIdentity: source, destination: folder)
        XCTAssertEqual(resolved?.sourceUID, 7); XCTAssertEqual(resolved?.destinationUID, 9); XCTAssertEqual(resolved?.destinationValidity, 11)
        await client.close()
    }
    func testPreviouslyCachedIdentityNeedsNoPostMoveSourceRequest() async throws {
        let server = try peer([
            (#"SELECT "INBOX""#, select(42)), (#"UID MOVE 7 "[Gmail]/All Mail""#, []),
            (#"SELECT "[Gmail]/All Mail""#, select(11)), ("UID SEARCH X-GM-MSGID \(global)", ["* SEARCH 9"]),
            (#"SELECT "[Gmail]/All Mail""#, select(11)), (fetch(9), header(uid: 9))
        ]); defer { server.stop() }
        let client = try await connect(server)
        _ = try await client.move(folder: "INBOX", uid: 7, destination: folder, expectedValidity: 42)
        let resolved = await client.resolveGmailMove(accountID: "fixture", sourceIdentity: identity(), destination: folder)
        XCTAssertEqual(resolved?.destinationUID, 9); XCTAssertEqual(resolved?.sourceUID, 7)
        await client.close()
    }
    func testAmbiguousOrMissingSearchResultDoesNotInventReceipt() async throws {
        for result in ["* SEARCH", "* SEARCH 9 10", "* SEARCH 4294967296", "* OK no search response"] {
            let server = try peer([(#"SELECT "[Gmail]/All Mail""#, select(11)), ("UID SEARCH X-GM-MSGID \(global)", [result])]); defer { server.stop() }
            let client = try await connect(server)
            let resolved = await client.resolveGmailMove(accountID: "fixture", sourceIdentity: identity(), destination: folder)
            XCTAssertNil(resolved); await client.close()
        }
    }
    func testGlobalIdentitySizeAndHeaderMismatchDoNotInventReceipt() async throws {
        for response in [header(uid: 9, global: "123"), header(uid: 9, size: 301), header(uid: 9, messageID: "<different@example.invalid>")] {
            let server = try peer([(#"SELECT "[Gmail]/All Mail""#, select(11)), ("UID SEARCH X-GM-MSGID \(global)", ["* SEARCH 9"]), (#"SELECT "[Gmail]/All Mail""#, select(11)), (fetch(9), response)]); defer { server.stop() }
            let client = try await connect(server)
            let resolved = await client.resolveGmailMove(accountID: "fixture", sourceIdentity: identity(), destination: folder)
            XCTAssertNil(resolved); await client.close()
        }
    }
    func testUIDValidityChangeBetweenSearchAndHeaderRejectsOldMapping() async throws {
        let server = try peer([(#"SELECT "[Gmail]/All Mail""#, select(11)), ("UID SEARCH X-GM-MSGID \(global)", ["* SEARCH 9"]), (#"SELECT "[Gmail]/All Mail""#, select(12))]); defer { server.stop() }
        let client = try await connect(server)
        let resolved = await client.resolveGmailMove(accountID: "fixture", sourceIdentity: identity(), destination: folder)
        XCTAssertNil(resolved); await client.close()
    }
    func testWrongAccountAndMalformedIdentityMakeNoLookupRequest() async throws {
        let server = try peer([]); defer { server.stop() }
        let client = try await connect(server)
        let foreign = await client.resolveGmailMove(accountID: "other", sourceIdentity: identity(), destination: folder)
        var invalid = identity(); invalid.globalID = "123\r\nUID STORE 1:* +FLAGS (\\Deleted)"
        let injected = await client.resolveGmailMove(accountID: "fixture", sourceIdentity: invalid, destination: folder)
        XCTAssertNil(foreign); XCTAssertNil(injected); await client.close()
    }
}
