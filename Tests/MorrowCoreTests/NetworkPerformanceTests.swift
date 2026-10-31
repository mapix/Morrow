import XCTest
import Darwin
@testable import MorrowCore

final class NetworkPerformanceTests: XCTestCase {
    func testCancelledQueuedPermitNeverStartsAndInvalidationClearsQueue() async throws {
        let gate = NetworkOperationGate(maximumWaiters: 2)
        let active = try await gate.acquire()
        let waiting = Task { try await gate.acquire() }
        try await waitForQueue(gate, count: 1)
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Cancelled waiter received a permit") } catch is CancellationError { }
        let afterCancel = await gate.counts(); XCTAssertEqual(afterCancel.waiting, 0)
        let pending = Task { try await gate.acquire() }
        try await waitForQueue(gate, count: 1)
        await gate.invalidate()
        do { _ = try await pending.value; XCTFail("Invalidated waiter received a permit") } catch is CancellationError { }
        await gate.release(active)
        let final = await gate.counts(); XCTAssertEqual(final.active, 0); XCTAssertEqual(final.waiting, 0)
        do { _ = try await gate.acquire(); XCTFail("Invalidated gate reopened") } catch is CancellationError { }
    }

    func testBackgroundReserveAllowsInteractiveWorkAndQueueIsBounded() async throws {
        let gate = NetworkOperationGate(capacity: 2, maximumBackground: 1, maximumWaiters: 1)
        let background = try await gate.acquire(priority: .background)
        let waiting = Task { try await gate.acquire(priority: .background) }
        try await waitForQueue(gate, count: 1)
        // A foreground request must use the idle reserve even when the waiting
        // queue already contains its maximum number of background requests.
        let foreground = Task { try await gate.acquire(priority: .interactive) }
        do {
            let permit = try await foreground.value
            await gate.release(permit)
        } catch { XCTFail("Idle interactive reserve was blocked by queue capacity: \(error)") }
        do { _ = try await gate.acquire(priority: .background); XCTFail("Queue limit was not enforced") } catch { }
        waiting.cancel(); _ = try? await waiting.value; await gate.release(background)
    }

    func testHTTPContentLengthRejectedBeforeBodyAndChunkedOverflowCancelsSocket() async throws {
        let lengthPeer = try PerformanceLoopbackPeer { connection in
            guard connection.readHTTPRequest() != nil else { return }
            _ = connection.write("HTTP/1.1 200 OK\r\nContent-Length: 100000\r\nConnection: close\r\n\r\n")
            _ = connection.readLine()
        }; defer { lengthPeer.stop() }
        do { _ = try await BoundedHTTPClient.load(URLRequest(url: lengthPeer.url), maximumBytes: 256); XCTFail("Declared oversized body accepted") } catch { }

        let stopped = expectation(description: "Oversized stream socket cancelled")
        let peer = try PerformanceLoopbackPeer { connection in
            guard connection.readHTTPRequest() != nil else { return }
            guard connection.write("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n") else { return }
            for _ in 0..<100 {
                if !connection.write(Data(repeating: 65, count: 128)) { stopped.fulfill(); return }
                usleep(2000)
            }
        }; defer { peer.stop() }
        do { _ = try await BoundedHTTPClient.load(URLRequest(url: peer.url), maximumBytes: 256); XCTFail("Unknown-length oversized body accepted") } catch { }
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testHTTPErrorUsesSmallerCapAndCancellationEndsPendingResponse() async throws {
        let errorPeer = try PerformanceLoopbackPeer { connection in
            guard connection.readHTTPRequest() != nil else { return }
            _ = connection.write("HTTP/1.1 500 Error\r\nContent-Length: 1000\r\nConnection: close\r\n\r\n" + String(repeating: "x", count: 1000))
        }; defer { errorPeer.stop() }
        do { _ = try await BoundedHTTPClient.load(URLRequest(url: errorPeer.url), maximumBytes: 4096, errorMaximumBytes: 128); XCTFail("Error body used success cap") } catch { }
        let accepted = expectation(description: "Pending HTTP request accepted")
        let closed = expectation(description: "Cancelled HTTP socket closed")
        let peer = try PerformanceLoopbackPeer { connection in
            guard connection.readHTTPRequest() != nil else { return }; accepted.fulfill()
            _ = connection.write("HTTP/1.1 200 OK\r\nContent-Length: 1000\r\nConnection: close\r\n\r\n")
            if connection.readLine() == nil { closed.fulfill() }
        }; defer { peer.stop() }
        let request = Task { try await BoundedHTTPClient.load(URLRequest(url: peer.url)) }
        await fulfillment(of: [accepted], timeout: 2); request.cancel()
        let start = ContinuousClock.now
        do { _ = try await request.value; XCTFail("Cancelled HTTP request returned success") } catch is CancellationError { }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        await fulfillment(of: [closed], timeout: 2)
    }

    func testHTTPRedirectCannotReplayCredentialToOtherHost() async throws {
        let peer = try PerformanceLoopbackPeer { connection in
            guard connection.readHTTPRequest() != nil else { return }
            _ = connection.write("HTTP/1.1 302 Found\r\nLocation: http://localhost:9/private\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        }; defer { peer.stop() }
        var request = URLRequest(url: peer.url); request.setValue("Bearer synthetic-only", forHTTPHeaderField: "Authorization")
        do { _ = try await BoundedHTTPClient.load(request); XCTFail("Cross-origin redirect accepted") } catch { }
    }

    func testIMAPAggregateLiteralCapClosesConnection() async throws {
        let peer = try imapPeer { _, tag, command, connection in
            guard command == "NOOP" else { return false }
            _ = connection.write("* 1 FETCH (BODY[] {300}\r\n" + String(repeating: "a", count: 300) + "\r\n* 2 FETCH (BODY[] {300}\r\n" + String(repeating: "b", count: 300) + "\r\n" + tag + " OK done\r\n")
            return true
        }; defer { peer.stop() }
        let client = IMAPConnection(maximumResponseBytes: 512)
        try await client.connect(host: "127.0.0.1", port: peer.port, email: "fixture@example.invalid", password: "synthetic", tls: false)
        do { _ = try await client.command("NOOP"); XCTFail("Multiple literals exceeded aggregate cap") } catch { }
        let connected = await client.connected; XCTAssertFalse(connected)
    }

    func testIMAPReadCancellationReturnsPromptlyAndInvalidPortDoesNotTrap() async throws {
        let accepted = expectation(description: "IMAP NOOP pending")
        let peer = try imapPeer { _, _, command, connection in
            guard command == "NOOP" else { return false }
            accepted.fulfill(); _ = connection.readLine(); return true
        }; defer { peer.stop() }
        let client = IMAPConnection()
        try await client.connect(host: "127.0.0.1", port: peer.port, email: "fixture@example.invalid", password: "synthetic", tls: false)
        let task = Task { try await client.command("NOOP") }
        await fulfillment(of: [accepted], timeout: 2); let start = ContinuousClock.now; task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled IMAP read succeeded") } catch is CancellationError { }
        XCTAssertLessThan(start.duration(to: .now), .seconds(1))
        let invalid = IMAPConnection()
        do { try await invalid.connect(host: "127.0.0.1", port: Int.max, email: "fixture@example.invalid", password: "synthetic", tls: false); XCTFail("Invalid port accepted") } catch { }
    }

    func testIMAPInventoryStreamsTwentyThousandRowsAndLiteralSpansReceiveChunks() async throws {
        let body = Data(repeating: 120, count: 600 * 1024)
        let peer = try imapPeer { _, tag, command, connection in
            if command == "UID FETCH 1:* (UID FLAGS)" {
                for uid in 1...20_000 { guard connection.write("* \(uid) FETCH (FLAGS (\(uid.isMultiple(of: 2) ? "\\Seen" : "") \(uid.isMultiple(of: 3) ? "\\Flagged" : "")) UID \(uid))\r\n") else { return true } }
                _ = connection.write(tag + " OK inventory\r\n"); return true
            }
            if command == "UID FETCH 7 (UID BODY.PEEK[])" {
                guard connection.write("* 7 FETCH (UID 7 BODY[] {\(body.count)}\r\n"), connection.write(body) else { return true }
                _ = connection.write(")\r\n" + tag + " OK fetched\r\n"); return true
            }
            return false
        }; defer { peer.stop() }
        let client = IMAPConnection()
        try await client.connect(host: "127.0.0.1", port: peer.port, email: "fixture@example.invalid", password: "synthetic", tls: false)
        let start = ContinuousClock.now
        let (validity, flags) = try await client.inventory("INBOX")
        XCTAssertEqual(validity, 42); XCTAssertEqual(flags.count, 20_000)
        XCTAssertEqual(flags[2]?.read, true); XCTAssertEqual(flags[3]?.starred, true); XCTAssertEqual(flags[5]?.read, false)
        print("Synthetic IMAP inventory 20000 rows: \(start.duration(to: .now))")
        let data = try await client.fetch(folder: "INBOX", uid: 7, expectedValidity: 42)
        XCTAssertEqual(data, body); await client.close()
        let parsed = MailTransport.parseFlags("* 1 FETCH (UID 1 FLAGS (\\Seened \\FlaggedExtra))\r\n* 2 FETCH (FLAGS (\\Seen) UID 2)\r\n")
        XCTAssertEqual(parsed[1]?.read, false); XCTAssertEqual(parsed[1]?.starred, false); XCTAssertEqual(parsed[2]?.read, true)
    }

    private func waitForQueue(_ gate: NetworkOperationGate, count: Int) async throws {
        for _ in 0..<200 { if await gate.counts().waiting == count { return }; try await Task.sleep(for: .milliseconds(2)) }
        XCTFail("Permit queue did not reach expected state")
    }
    private func imapPeer(handler: @escaping @Sendable (Int, String, String, PerformanceLoopbackConnection) -> Bool) throws -> PerformanceLoopbackPeer {
        try PerformanceLoopbackPeer { connection in
            guard connection.write("* OK synthetic IMAP\r\n") else { return }; var index = 0
            while let line = connection.readLine() {
                let pieces = line.split(separator: " ", maxSplits: 1); guard pieces.count == 2 else { return }
                let tag = String(pieces[0]), command = String(pieces[1]); index += 1
                if command == "CAPABILITY" { _ = connection.write("* CAPABILITY IMAP4rev1\r\n" + tag + " OK capability\r\n") }
                else if command.hasPrefix("LOGIN ") { _ = connection.write(tag + " OK authenticated\r\n") }
                else if command.hasPrefix("SELECT ") { _ = connection.write("* OK [UIDVALIDITY 42] fixture\r\n" + tag + " OK selected\r\n") }
                else if !handler(index, tag, command, connection) { _ = connection.write(tag + " BAD unexpected\r\n"); return }
            }
        }
    }
}

/// Small in-process peers bind only loopback and close all descriptors on stop.
/// They never read credentials or create fixture mailboxes on disk.
final class PerformanceLoopbackPeer: @unchecked Sendable {
    let port: Int
    var url: URL { URL(string: "http://127.0.0.1:\(port)")! }
    private let listener: Int32
    private let lock = NSLock()
    private var clients: Set<Int32> = []
    private var stopped = false
    init(handler: @escaping @Sendable (PerformanceLoopbackConnection) -> Void) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw PeerError.socket }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else { Darwin.close(fd); throw PeerError.socket }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard named == 0 else { Darwin.close(fd); throw PeerError.socket }
        listener = fd; port = Int(UInt16(bigEndian: address.sin_port))
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let client = accept(fd, nil, nil); guard client >= 0 else { return }
                lock.lock(); if stopped { lock.unlock(); Darwin.close(client); return }; clients.insert(client); lock.unlock()
                DispatchQueue.global(qos: .utility).async { [self] in
                    let connection = PerformanceLoopbackConnection(client)
                    handler(connection)
                    lock.lock(); clients.remove(client); lock.unlock(); Darwin.close(client)
                }
            }
        }
    }
    func stop() {
        lock.lock(); guard !stopped else { lock.unlock(); return }; stopped = true; let active = clients; lock.unlock()
        for client in active { _ = shutdown(client, SHUT_RDWR) }
        _ = shutdown(listener, SHUT_RDWR); Darwin.close(listener)
    }
    private enum PeerError: Error { case socket }
}

final class PerformanceLoopbackConnection: @unchecked Sendable {
    private let descriptor: Int32
    init(_ descriptor: Int32) {
        self.descriptor = descriptor
        var noPipe: Int32 = 1; _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0); _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
    func readLine() -> String? {
        var bytes: [UInt8] = [], byte: UInt8 = 0
        while bytes.count < 8192 {
            guard Darwin.recv(descriptor, &byte, 1, 0) == 1 else { return nil }; bytes.append(byte)
            if bytes.count >= 2, bytes[bytes.count - 2] == 13, byte == 10 { return String(bytes: bytes.dropLast(2), encoding: .utf8) }
        }
        return nil
    }
    func readHTTPRequest() -> Data? {
        guard readLine() != nil else { return nil }; var length = 0
        while let line = readLine() {
            if line.isEmpty { break }
            if line.lowercased().hasPrefix("content-length:") { length = Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)) ?? 0 }
        }
        guard length >= 0, length <= 512 * 1024 else { return nil }
        var data = Data(); data.reserveCapacity(length)
        while data.count < length {
            var buffer = [UInt8](repeating: 0, count: min(8192, length - data.count))
            let count = Darwin.recv(descriptor, &buffer, buffer.count, 0); guard count > 0 else { return nil }; data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
    @discardableResult func write(_ text: String) -> Bool { write(Data(text.utf8)) }
    @discardableResult func write(_ data: Data) -> Bool {
        data.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < data.count {
                let count = Darwin.send(descriptor, pointer.baseAddress!.advanced(by: offset), data.count - offset, 0)
                guard count > 0 else { return false }; offset += count
            }
            return true
        }
    }
}
