import XCTest
import Darwin
@testable import MorrowCore

final class BulkIMAPFlagTests: XCTestCase {
    func testBatchBodyFetchUsesOnePeekCommandAndMapsReorderedResponses() async throws {
        let first = "Subject: first\r\n\r\nfirst body", second = "Subject: second\r\n\r\nsecond body"
        let server = try BulkFlagServer(validity: 42, bodies: [101: first, 102: second]); defer { server.stop() }
        let client = try await connect(server); defer { Task { await client.close() } }
        let fetched = try await client.fetchMany(folder: "INBOX", uids: [101, 102], expectedValidity: 42)
        XCTAssertEqual(fetched[101], Data(first.utf8)); XCTAssertEqual(fetched[102], Data(second.utf8))
        XCTAssertEqual(server.commands.filter { $0.hasPrefix("UID FETCH ") }, ["UID FETCH 101,102 (UID BODY.PEEK[])"])
        XCTAssertFalse(server.commands.contains { $0.hasPrefix("UID STORE ") })
    }
    func testUIDCompressionDeduplicationAndCommandBoundaries() throws {
        let batches = try IMAPConnection.flagBatches([20, 1, 3, 2, 10, 11, 20], flag: "\\Seen", enabled: true)
        XCTAssertEqual(batches.count, 1); XCTAssertEqual(batches[0].uids, [1, 2, 3, 10, 11, 20])
        XCTAssertEqual(batches[0].command, "UID STORE 1:3,10:11,20 +FLAGS.SILENT (\\Seen)")
        let dense = try IMAPConnection.flagBatches(Array(UInt64(1)...UInt64(2000)), flag: "\\Flagged", enabled: false)
        XCTAssertEqual(dense.count, 1); XCTAssertEqual(dense[0].uids.count, 2000)
        XCTAssertEqual(dense[0].command, "UID STORE 1:2000 -FLAGS.SILENT (\\Flagged)")
        let scattered = (0..<1200).map { UInt64($0 * 2 + 1) }
        let separated = try IMAPConnection.flagBatches(scattered, flag: "\\Seen", enabled: true)
        XCTAssertEqual(separated.flatMap(\.uids), scattered)
        XCTAssertTrue(separated.allSatisfy { $0.uids.count <= 500 && $0.command.utf8.count + 32 <= 4096 })
        let largeUIDs = (0..<600).map { UInt64(UInt32.max) - UInt64($0 * 2) }
        let lengthBounded = try IMAPConnection.flagBatches(largeUIDs, flag: "\\Seen", enabled: true)
        XCTAssertGreaterThan(lengthBounded.count, 1)
        XCTAssertTrue(lengthBounded.allSatisfy { $0.command.utf8.count + 32 <= 4096 })
        XCTAssertEqual(Set(lengthBounded.flatMap(\.uids)), Set(largeUIDs))
    }

    func testInvalidInputAndEmptySetDoNotConnect() async throws {
        XCTAssertThrowsError(try IMAPConnection.flagBatches([0], flag: "\\Seen", enabled: true))
        XCTAssertThrowsError(try IMAPConnection.flagBatches([UInt64(UInt32.max) + 1], flag: "\\Seen", enabled: true))
        XCTAssertThrowsError(try IMAPConnection.flagBatches([1], flag: "\\Deleted", enabled: true))
        XCTAssertThrowsError(try IMAPConnection.flagBatches([1], flag: "\\Seen\r\nUID STORE 1:*", enabled: true))
        XCTAssertThrowsError(try IMAPConnection.validateBulkFolder("INBOX\tInjected"))
        let client = IMAPConnection()
        let empty = try await client.storeMany(folder: "INBOX", uids: [], flag: "\\Seen", enabled: true, expectedValidity: 42)
        let connected = await client.connected
        XCTAssertEqual(empty.uids, []); XCTAssertFalse(connected)
        var account = MailAccount(); account.imapHost = "must-not-connect.example.invalid"
        let receipt = try await MailTransport().setFlags(account, folder: "INBOX", uids: [], expectedValidity: 42, flag: "\\Seen", enabled: true, password: "fixture-password")
        XCTAssertEqual(receipt.uids, [])
    }

    func testBulkUsesOneFreshSelectAndNoBodyFetch() async throws {
        let server = try BulkFlagServer(validity: 42); defer { server.stop() }
        let client = try await connect(server); defer { Task { await client.close() } }
        let receipt = try await client.storeMany(folder: "INBOX", uids: [7, 8, 9, 11], flag: "\\Seen", enabled: true, expectedValidity: 42)
        XCTAssertEqual(receipt.uids, [7, 8, 9, 11]); XCTAssertNil(receipt.failure)
        let commands = server.commands
        XCTAssertEqual(commands.filter { $0.hasPrefix("SELECT ") }.count, 1)
        XCTAssertEqual(commands.filter { $0.hasPrefix("UID STORE ") }, ["UID STORE 7:9,11 +FLAGS.SILENT (\\Seen)"])
        XCTAssertFalse(commands.contains { $0.contains("FETCH") || $0.contains("BODY") })
    }

    func testUIDValidityMismatchThrowsBeforeWrite() async throws {
        let server = try BulkFlagServer(validity: 99); defer { server.stop() }
        let client = try await connect(server)
        do { _ = try await client.storeMany(folder: "INBOX", uids: [7], flag: "\\Seen", enabled: true, expectedValidity: 42); XCTFail("Expected UIDVALIDITY mismatch") }
        catch { }
        XCTAssertEqual(server.commands.filter { $0.hasPrefix("SELECT ") }.count, 1)
        XCTAssertFalse(server.commands.contains { $0.hasPrefix("UID STORE ") })
        let connected = await client.connected; XCTAssertFalse(connected)
    }

    func testPartialReceiptContainsOnlyAcknowledgedBatchAndClosesConnection() async throws {
        let server = try BulkFlagServer(validity: 42, failedStore: 2); defer { server.stop() }
        let client = try await connect(server)
        let values = (0..<1200).map { UInt64($0 * 2 + 1) }
        let receipt = try await client.storeMany(folder: "INBOX", uids: values, flag: "\\Seen", enabled: true, expectedValidity: 42)
        XCTAssertEqual(receipt.uids, Array(values.prefix(500))); XCTAssertNotNil(receipt.failure)
        XCTAssertEqual(server.commands.filter { $0.hasPrefix("UID STORE ") }.count, 2)
        XCTAssertEqual(server.commands.filter { $0.hasPrefix("SELECT ") }.count, 1)
        let connected = await client.connected; XCTAssertFalse(connected)
        XCTAssertFalse(server.commands.contains { $0.contains("FETCH") })
    }

    func testFolderReadUsesExactUnseenSnapshotWithoutNewArrivalWildcard() async throws {
        let server = try BulkFlagServer(validity: 42, unseen: [7, 9, 11]); defer { server.stop() }
        let client = try await connect(server); defer { Task { await client.close() } }
        let receipt = try await client.markFolderRead(folder: "INBOX", expectedValidity: 42)
        XCTAssertEqual(receipt.uids, [7, 9, 11]); XCTAssertNil(receipt.failure)
        XCTAssertEqual(server.commands.filter { $0.hasPrefix("SELECT ") }.count, 1)
        XCTAssertEqual(server.commands.filter { $0.hasPrefix("UID SEARCH ") }, ["UID SEARCH UNSEEN"])
        XCTAssertEqual(server.commands.filter { $0.hasPrefix("UID STORE ") }, ["UID STORE 7,9,11 +FLAGS.SILENT (\\Seen)"])
        XCTAssertFalse(server.commands.contains { $0.contains("FETCH") || $0.contains("1:*") || $0.contains("13") })
    }

    private func connect(_ server: BulkFlagServer) async throws -> IMAPConnection {
        let client = IMAPConnection()
        try await client.connect(host: "127.0.0.1", port: server.port, email: "fixture@example.invalid", password: "fixture-password", tls: false)
        return client
    }
}

/// A one-connection loopback-only IMAP peer; records commands, never mail bodies.
private final class BulkFlagServer: @unchecked Sendable {
    let port: Int
    private let listener: Int32
    private let validity: UInt64
    private let failedStore: Int?
    private let unseen: [UInt64]
    private let bodies: [UInt64: String]
    private let lock = NSLock()
    private var recorded: [String] = []
    private var client: Int32 = -1
    private var stopped = false
    var commands: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    init(validity: UInt64, failedStore: Int? = nil, unseen: [UInt64] = [], bodies: [UInt64: String] = [:]) throws {
        self.validity = validity; self.failedStore = failedStore; self.unseen = unseen; self.bodies = bodies
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw FixtureError.socket }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else { Darwin.close(fd); throw FixtureError.socket }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard named == 0 else { Darwin.close(fd); throw FixtureError.socket }
        self.listener = fd; self.port = Int(UInt16(bigEndian: address.sin_port))
        DispatchQueue.global(qos: .utility).async { [self] in serve() }
    }
    func stop() {
        lock.lock(); guard !stopped else { lock.unlock(); return }; stopped = true; let active = client; lock.unlock()
        if active >= 0 { _ = shutdown(active, SHUT_RDWR) }
        _ = shutdown(listener, SHUT_RDWR); Darwin.close(listener)
    }
    private func serve() {
        let fd = accept(listener, nil, nil); guard fd >= 0 else { return }
        lock.lock(); if stopped { lock.unlock(); Darwin.close(fd); return }; client = fd; lock.unlock()
        defer { lock.lock(); client = -1; lock.unlock(); Darwin.close(fd) }
        var noPipe: Int32 = 1; _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 10, tv_usec: 0); _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard send("* OK synthetic peer\r\n", fd: fd) else { return }
        var stores = 0
        while let line = receiveLine(fd) {
            let pieces = line.split(separator: " ", maxSplits: 1); guard pieces.count == 2 else { return }
            let tag = String(pieces[0]), command = String(pieces[1])
            lock.lock(); recorded.append(command); lock.unlock()
            if command == "CAPABILITY" { guard send("* CAPABILITY IMAP4rev1\r\n", fd: fd) else { return } }
            else if command.hasPrefix("LOGIN ") { }
            else if command.hasPrefix("SELECT ") { guard send("* 1201 EXISTS\r\n* OK [UIDVALIDITY \(validity)] validity\r\n", fd: fd) else { return } }
            else if command == "UID SEARCH UNSEEN" { guard send("* SEARCH " + unseen.map(String.init).joined(separator: " ") + "\r\n* 1202 EXISTS\r\n", fd: fd) else { return } }
            else if command.hasPrefix("UID FETCH ") && command.hasSuffix("(UID BODY.PEEK[])") {
                for (uid, body) in bodies.sorted(by: { $0.key > $1.key }) {
                    guard send("* \(uid) FETCH (BODY[] {\(body.utf8.count)}\r\n" + body + " UID \(uid))\r\n", fd: fd) else { return }
                }
            }
            else if command.hasPrefix("UID STORE ") {
                stores += 1
                if stores == failedStore { _ = send(tag + " NO synthetic store failure\r\n", fd: fd); return }
            } else { _ = send(tag + " BAD unexpected command\r\n", fd: fd); return }
            guard send(tag + " OK completed\r\n", fd: fd) else { return }
        }
    }
    private func receiveLine(_ fd: Int32) -> String? {
        var bytes: [UInt8] = []; var byte: UInt8 = 0
        while bytes.count < 8192 {
            guard Darwin.recv(fd, &byte, 1, 0) == 1 else { return nil }
            bytes.append(byte)
            if bytes.count >= 2, bytes[bytes.count - 2] == 13, byte == 10 { return String(bytes: bytes.dropLast(2), encoding: .utf8) }
        }
        return nil
    }
    private func send(_ text: String, fd: Int32) -> Bool {
        let data = Data(text.utf8)
        return data.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) in
            var written = 0
            while written < data.count {
                let count = Darwin.send(fd, pointer.baseAddress!.advanced(by: written), data.count - written, 0)
                guard count > 0 else { return false }; written += count
            }
            return true
        }
    }
    private enum FixtureError: Error { case socket }
}
