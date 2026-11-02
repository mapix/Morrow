import XCTest
import Network
@testable import MorrowCore

final class MailReadRecoveryTests: XCTestCase {
    private func account(_ port: Int) -> MailAccount {
        var account = MailAccount(); account.id = "fixture"; account.email = "fixture@example.invalid"
        account.imapHost = "127.0.0.1"; account.imapPort = port; return account
    }
    func testReadReconnectsOnceAfterServerClosesExistingSocket() async throws {
        let count = RecoveryPeerCount()
        let peer = try server(count: count, alwaysDrop: false); defer { peer.stop() }
        let transport = MailTransport(testOnlyPlaintextLoopback: true)
        let folders = try await transport.folders(account(peer.port), password: "synthetic")
        XCTAssertEqual(folders.map(\.path), ["INBOX"]); XCTAssertEqual(count.value, 2)
        await transport.closeAccount("fixture")
    }
    func testReadRecoveryIsBoundedToTwoConnections() async throws {
        let count = RecoveryPeerCount()
        let peer = try server(count: count, alwaysDrop: true); defer { peer.stop() }
        let transport = MailTransport(testOnlyPlaintextLoopback: true)
        do { _ = try await transport.folders(account(peer.port), password: "synthetic"); XCTFail("Closed socket was accepted") }
        catch { XCTAssertTrue(MailConnectionError.isTransient(error)) }
        XCTAssertEqual(count.value, 2)
    }
    func testMutationIsNeverAutomaticallyReplayedAfterLostResponse() async throws {
        let count = RecoveryPeerCount()
        let peer = try server(count: count, alwaysDrop: true); defer { peer.stop() }
        let transport = MailTransport(testOnlyPlaintextLoopback: true)
        do { try await transport.createFolder(account(peer.port), path: "Fixture", password: "synthetic"); XCTFail("Unacknowledged CREATE was accepted") } catch { }
        XCTAssertEqual(count.value, 1)
    }
    func testTimeoutIsTypedAsRecoverableAndCancelledReadDoesNotRetry() async throws {
        let peer = try PerformanceLoopbackPeer { connection in _ = connection.readLine() }; defer { peer.stop() }
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(peer.port))!, using: .tcp)
        try await MailNetworkIO.connect(connection)
        do { _ = try await MailNetworkIO.receive(connection, timeout: 0.05); XCTFail("Silent peer did not time out") }
        catch { XCTAssertTrue(error is MailConnectionError); XCTAssertTrue(MailConnectionError.isTransient(error)) }
        connection.cancel()
        XCTAssertFalse(MailConnectionError.isTransient(CancellationError()))
        XCTAssertFalse(MailConnectionError.isTransient(MailError.message("Authentication rejected")))
    }
    private func server(count: RecoveryPeerCount, alwaysDrop: Bool) throws -> PerformanceLoopbackPeer {
        try PerformanceLoopbackPeer { connection in
            let number = count.next()
            _ = connection.write("* OK synthetic IMAP\r\n")
            while let line = connection.readLine() {
                let parts = line.split(separator: " ", maxSplits: 1); guard parts.count == 2 else { return }
                let tag = String(parts[0]), command = String(parts[1])
                if command == "CAPABILITY" { _ = connection.write("* CAPABILITY IMAP4rev1\r\n\(tag) OK capability\r\n") }
                else if command.hasPrefix("LOGIN ") { _ = connection.write(tag + " OK login\r\n") }
                else if command.hasPrefix("LIST ") || command.hasPrefix("CREATE ") {
                    if number == 1 || alwaysDrop { return }
                    _ = connection.write("* LIST () \"/\" \"INBOX\"\r\n\(tag) OK listed\r\n")
                } else { _ = connection.write(tag + " BAD unexpected\r\n"); return }
            }
        }
    }
}
private final class RecoveryPeerCount: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
