import XCTest
import CMail
@testable import MorrowCore

final class IncrementalIMAPTests: XCTestCase {
    func testLargeAttachmentSyncFetchesTextAndKeepsRemoteLinkWithoutDownloadingAttachment() async throws {
        let headers = "From: fixture@example.invalid\r\nSubject: Large attachment fixture\r\nMessage-ID: <large@example.invalid>\r\nContent-Type: multipart/mixed; boundary=fixture\r\n\r\n"
        let mime = "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 7bit\r\n\r\n"
        let structure = #"(("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 12 1 NIL NIL NIL NIL)("APPLICATION" "PDF" ("NAME" "large.pdf") NIL NIL "BASE64" 94371840 NIL ("ATTACHMENT" ("FILENAME" "large.pdf")) NIL NIL) "MIXED")"#
        let peer = try scripted("", [
            (#"SELECT "INBOX""#, selected()),
            ("UID FETCH 3 (UID RFC822.SIZE)", ["* 3 FETCH (UID 3 RFC822.SIZE 95000000)"]),
            ("UID FETCH 3 (UID BODYSTRUCTURE BODY.PEEK[HEADER])", ["* 3 FETCH (UID 3 BODYSTRUCTURE " + structure + " BODY[HEADER] {\(headers.utf8.count)}", headers, ")"]),
            ("UID FETCH 3 (BODY.PEEK[1]<0.12>)", ["* 3 FETCH (UID 3 BODY[1]<0> {12}", "Hello world!", ")"]),
            ("UID FETCH 3 (BODY.PEEK[1.MIME])", ["* 3 FETCH (UID 3 BODY[1.MIME] {\(mime.utf8.count)}", mime, ")"])
        ])
        defer { peer.stop() }
        let client = try await connect(peer)
        let result = try await client.fetchForSync(accountID: "fixture", folder: "INBOX", uid: 3, expectedValidity: 42, attachmentLimit: 10 * 1024 * 1024)
        guard case .selective(let mail) = result else { return XCTFail("Large message fetched whole") }
        XCTAssertEqual(mail.text, "Hello world!"); XCTAssertEqual(mail.subject, "Large attachment fixture")
        XCTAssertEqual(mail.attachments.first?.name, "large.pdf"); XCTAssertEqual(mail.attachments.first?.remoteReference?.section, "2"); XCTAssertTrue(mail.attachments.first?.isRemoteOnly == true)
        XCTAssertTrue(mail.attachments.first?.data.isEmpty == true)
        await client.close()
    }
    private var account: MailAccount { var value = MailAccount(); value.id = "fixture"; value.email = "fixture@example.invalid"; return value }
    private func cursor(_ uids: Set<UInt64> = [1, 2, 3], validity: UInt64 = 42, mod: UInt64? = 10, next: UInt64? = 4) -> MailFolderSyncCursor {
        .init(account: account, folder: "INBOX", validity: validity, highestModSequence: mod, uidNext: next, knownUIDs: uids)
    }
    private func selected(_ validity: UInt64 = 42, mod: UInt64? = 10, next: UInt64 = 4, count: Int = 3) -> [String] {
        ["* OK [UIDVALIDITY \(validity)] fixture", "* OK [UIDNEXT \(next)] fixture", "* \(count) EXISTS", mod.map { "* OK [HIGHESTMODSEQ \($0)] fixture" } ?? "* OK [NOMODSEQ] fixture"]
    }
    private func row(_ uid: UInt64, _ flags: String = "", mod: UInt64 = 10) -> String { "* \(uid) FETCH (UID \(uid) FLAGS (\(flags)) MODSEQ (\(mod)))" }
    private func connect(_ peer: PerformanceLoopbackPeer) async throws -> IMAPConnection {
        let client = IMAPConnection()
        try await client.connect(host: "127.0.0.1", port: peer.port, email: "fixture@example.invalid", password: "synthetic", tls: false)
        return client
    }
    private func scripted(_ capabilities: String, _ steps: [(String, [String])]) throws -> PerformanceLoopbackPeer {
        try PerformanceLoopbackPeer { connection in
            _ = connection.write("* OK synthetic IMAP\r\n"); var position = 0
            while let line = connection.readLine() {
                let words = line.split(separator: " ", maxSplits: 1); guard words.count == 2 else { return }
                let tag = String(words[0]), command = String(words[1])
                if command == "CAPABILITY" { _ = connection.write("* CAPABILITY IMAP4rev1 \(capabilities)\r\n\(tag) OK capabilities\r\n"); continue }
                if command.hasPrefix("LOGIN ") { _ = connection.write(tag + " OK authenticated\r\n"); continue }
                guard position < steps.count else { XCTFail("Unexpected command: " + command); _ = connection.write(tag + " BAD unexpected\r\n"); return }
                XCTAssertEqual(command, steps[position].0)
                let lines = steps[position].1; position += 1
                _ = connection.write((lines.isEmpty ? "" : lines.joined(separator: "\r\n") + "\r\n") + tag + " OK done\r\n")
            }
            XCTAssertEqual(position, steps.count)
        }
    }
    func testCondstoreOnlyFetchesChangedFlagsAndReconcilesDeletion() async throws {
        let peer = try scripted("CONDSTORE", [
            ("SELECT \"INBOX\" (CONDSTORE)", selected()),
            ("UID FETCH 1:* (UID FLAGS)", [row(1), row(2), row(3)]),
            ("SELECT \"INBOX\" (CONDSTORE)", selected(mod: 11, next: 5)),
            ("UID FETCH 1:* (UID FLAGS) (CHANGEDSINCE 10)", [row(2, "\\Seen \\Flagged", mod: 12), row(4, mod: 11)]),
            ("UID SEARCH ALL", ["* SEARCH 1 2 4"])
        ]); defer { peer.stop() }
        let client = try await connect(peer)
        let initial = try await client.syncInventory("INBOX", cursor: nil)
        XCTAssertFalse(initial.incremental); XCTAssertEqual(initial.presentUIDs, [1, 2, 3])
        let delta = try await client.syncInventory("INBOX", cursor: initial.cursor(account: account, folder: "INBOX"))
        XCTAssertTrue(delta.incremental); XCTAssertEqual(Set(delta.flags.keys), [2, 4]); XCTAssertEqual(delta.presentUIDs, [1, 2, 4])
        XCTAssertTrue(try XCTUnwrap(delta.flags[2]).read); XCTAssertTrue(try XCTUnwrap(delta.flags[2]).starred)
        XCTAssertEqual(delta.highestModSequence, 11, "SELECT watermark must replay later concurrent changes")
        await client.close()
    }
    func testUnchanged85433MailNeedsNoFetchOrSearch() async throws {
        let peer = try scripted("CONDSTORE", [("SELECT \"INBOX\" (CONDSTORE)", selected(next: 85_434, count: 85_433))]); defer { peer.stop() }
        let client = try await connect(peer)
        let delta = try await client.syncInventory("INBOX", cursor: cursor(Set(1...85_433), next: 85_434))
        XCTAssertTrue(delta.incremental); XCTAssertTrue(delta.flags.isEmpty); XCTAssertEqual(delta.presentUIDs.count, 85_433)
        await client.close()
    }
    func testQresyncUsesVanishedWithoutFullMembershipSearch() async throws {
        let peer = try scripted("ENABLE QRESYNC CONDSTORE", [
            ("ENABLE QRESYNC", ["* ENABLED QRESYNC"]),
            ("SELECT \"INBOX\" (QRESYNC (42 10))", selected(mod: 11, next: 5) + ["* VANISHED (EARLIER) 2", row(3, "\\Flagged", mod: 11)]),
            ("UID FETCH 4:4294967295 (UID FLAGS)", [row(4, mod: 11)])
        ]); defer { peer.stop() }
        let client = try await connect(peer), delta = try await client.syncInventory("INBOX", cursor: cursor())
        XCTAssertTrue(delta.incremental); XCTAssertEqual(delta.presentUIDs, [1, 3, 4]); XCTAssertEqual(Set(delta.flags.keys), [3, 4])
        await client.close()
    }
    func testValidityResetAndNoModseqFallBackToFullInventory() async throws {
        for mod: UInt64? in [11, nil] {
            let peer = try scripted("CONDSTORE", [("SELECT \"INBOX\" (CONDSTORE)", selected(43, mod: mod, next: 8, count: 1)), ("UID FETCH 1:* (UID FLAGS)", [row(7)])])
            let client = try await connect(peer), snapshot = try await client.syncInventory("INBOX", cursor: cursor())
            XCTAssertFalse(snapshot.incremental); XCTAssertEqual(snapshot.validity, 43); XCTAssertEqual(snapshot.presentUIDs, [7])
            await client.close(); peer.stop()
        }
    }
    func testLegacyIMAPRetainsCompatibleInventory() async throws {
        let peer = try scripted("", [("SELECT \"INBOX\"", selected(mod: nil)), ("UID FETCH 1:* (UID FLAGS)", [row(1), row(2), row(3)])]); defer { peer.stop() }
        let client = try await connect(peer), snapshot = try await client.syncInventory("INBOX", cursor: cursor(mod: nil))
        XCTAssertFalse(snapshot.incremental); XCTAssertEqual(snapshot.presentUIDs, [1, 2, 3]); await client.close()
    }
    func testVanishedRangesAndMissingFlagsAreValidated() throws {
        XCTAssertEqual(try IMAPConnection.vanishedUIDs("* VANISHED (EARLIER) 1:3,7,10:9"), [1, 2, 3, 7, 9, 10])
        for invalid in ["* VANISHED 0", "* VANISHED 1:4294967295", "* VANISHED 1,,2", "* VANISHED *"] {
            XCTAssertThrowsError(try IMAPConnection.vanishedUIDs(invalid))
        }
        XCTAssertNil(IMAPFlagRow.parse("* 1 FETCH (UID 1 MODSEQ (10))"))
    }
    func testGmailAllMailSpecialUseIsAnArchiveFolder() {
        let folders = MailTransport.parseFolders(#"* LIST (\HasNoChildren \All) "/" "[Gmail]/All Mail""#, accountID: "fixture")
        XCTAssertEqual(folders.first?.role, "archive"); XCTAssertEqual(folders.first?.path, "[Gmail]/All Mail")
    }
    func testIdleSendsDoneOnEventAndCanRunAnotherCommand() async throws {
        let done = expectation(description: "DONE acknowledged")
        let peer = try idlePeer { connection, tag in
            _ = connection.write("+ idling\r\n* 4 EXISTS\r\n")
            XCTAssertEqual(connection.readLine(), "DONE"); _ = connection.write(tag + " OK idle ended\r\n"); done.fulfill()
        }; defer { peer.stop() }
        let client = try await connect(peer)
        let changed = try await client.waitForChange(folder: "INBOX")
        XCTAssertTrue(changed); _ = try await client.command("NOOP")
        await fulfillment(of: [done], timeout: 2); await client.close()
    }
    func testIdleRenewsAndCancellationClosesPendingRead() async throws {
        let waiting = expectation(description: "IDLE waiting")
        waiting.expectedFulfillmentCount = 2
        let peer = try idlePeer { connection, tag in
            _ = connection.write("+ idling\r\n"); waiting.fulfill()
            if connection.readLine() == "DONE" { _ = connection.write(tag + " OK renewed\r\n") }
        }; defer { peer.stop() }
        let client = try await connect(peer)
        let changed = try await client.waitForChange(folder: "INBOX", renewAfter: 0.05)
        XCTAssertFalse(changed); await client.close()
        let second = try await connect(peer)
        let task = Task { try await second.waitForChange(folder: "INBOX") }
        await fulfillment(of: [waiting], timeout: 2)
        let start = ContinuousClock.now; task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled IDLE succeeded") } catch is CancellationError { }
        let connected = await second.connected
        XCTAssertLessThan(start.duration(to: .now), .seconds(1)); XCTAssertFalse(connected)
    }
    private func idlePeer(_ idle: @escaping @Sendable (PerformanceLoopbackConnection, String) -> Void) throws -> PerformanceLoopbackPeer {
        try PerformanceLoopbackPeer { connection in
            _ = connection.write("* OK synthetic IMAP\r\n")
            while let line = connection.readLine() {
                let words = line.split(separator: " ", maxSplits: 1); guard words.count == 2 else { return }
                let tag = String(words[0]), command = String(words[1])
                if command == "CAPABILITY" { _ = connection.write("* CAPABILITY IMAP4rev1 IDLE\r\n\(tag) OK capability\r\n") }
                else if command.hasPrefix("SELECT ") { _ = connection.write("* OK [UIDVALIDITY 42] fixture\r\n\(tag) OK selected\r\n") }
                else if command == "IDLE" { idle(connection, tag) }
                else { _ = connection.write(tag + " OK done\r\n") }
            }
        }
    }
    func testCursorAndQueuedFlagsSurviveRestartBeforeHistoryFinishes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root), raw = Data("From: fixture@example.invalid\r\nSubject: synthetic\r\n\r\nbody".utf8)
        let job = MailDownloadJob(accountID: account.id, folder: "INBOX", uid: 1, validity: 42, read: false, starred: false, byteCount: raw.count, inventoryStarted: Date(timeIntervalSince1970: 10))
        try await store.queueMailDownload(raw, job: job)
        let inventory = MailSyncInventory(validity: 42, flags: [1: .init(read: true, starred: true)], presentUIDs: [1, 2], highestModSequence: 11, uidNext: 3, incremental: true)
        _ = try await store.commitMailSyncInventory(inventory, account: account, folder: "INBOX", updates: [], inventoryStarted: Date(timeIntervalSince1970: 20))
        let reopened = try MailStore(root: root)
        let saved = try await reopened.mailSyncCursor(account: account, folder: "INBOX")
        XCTAssertEqual(saved?.knownUIDs, [1, 2]); XCTAssertEqual(saved?.highestModSequence, 11)
        let queued = try await reopened.queuedMailDownloads(); XCTAssertEqual(queued.map(\.uid), [1])
        var parsed = MIMEParser.parse(raw, accountID: account.id, folder: "INBOX", uid: 1, validity: 42); parsed.isRead = false; parsed.isStarred = false
        let committed = try await reopened.commitDownloadedMail(parsed, job: job)
        XCTAssertTrue(try XCTUnwrap(committed).isRead); XCTAssertTrue(try XCTUnwrap(committed).isStarred)
        let rawAfter = try await reopened.rawData(try XCTUnwrap(committed)); XCTAssertEqual(rawAfter, raw)
        var changedAccount = account; changedAccount.imapHost = "other.example.invalid"
        let mismatched = try await reopened.mailSyncCursor(account: changedAccount, folder: "INBOX"); XCTAssertNil(mismatched)
    }
    func testFailedMetadataCommitKeepsPreviousCursorAndRawFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root)
        let raw = Data("From: fixture@example.invalid\r\nSubject: synthetic\r\n\r\nbody".utf8)
        let mail = try await store.upsert(MIMEParser.parse(raw, accountID: account.id, folder: "INBOX", uid: 1, validity: 42))
        let original = cursor([1]); try await store.save(original, kind: "mail-sync-cursor", id: original.id)
        var db: OpaquePointer?; XCTAssertEqual(sqlite3_open(root.appendingPathComponent("mail.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TRIGGER fail_sync_cursor BEFORE INSERT ON objects WHEN new.kind='mail-sync-cursor' BEGIN SELECT RAISE(ABORT,'synthetic failure'); END", nil, nil, nil), SQLITE_OK)
        let snapshot = MailSyncInventory(validity: 42, flags: [:], presentUIDs: [], highestModSequence: 11, uidNext: 4, incremental: true)
        do { _ = try await store.commitMailSyncInventory(snapshot, account: account, folder: "INBOX", updates: [], inventoryStarted: Date()); XCTFail("Synthetic transaction failure did not abort") } catch { }
        let saved = try await store.mailSyncCursor(account: account, folder: "INBOX"), retained = try await store.message(mail.id), retainedRaw = try await store.rawData(mail)
        XCTAssertEqual(saved?.highestModSequence, 10); XCTAssertNotNil(retained); XCTAssertEqual(retainedRaw, raw)
    }
    func testRemoteDeltaPreservesLocalEditMadeAfterInventoryStarted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root)
        var mail = MIMEParser.parse(Data("From: fixture@example.invalid\r\n\r\nbody".utf8), accountID: account.id, uid: 1, validity: 42)
        mail.isRead = true; mail.isStarred = true; mail.localFlagModifiedAt = Date(timeIntervalSince1970: 30); try await store.upsert(mail)
        let snapshot = MailSyncInventory(validity: 42, flags: [1: .init(read: false, starred: false)], presentUIDs: [1], highestModSequence: 11, uidNext: 2, incremental: true)
        _ = try await store.commitMailSyncInventory(snapshot, account: account, folder: "INBOX", updates: [.init(id: mail.id, read: false, starred: false)], inventoryStarted: Date(timeIntervalSince1970: 20))
        let latest = try await store.message(mail.id); XCTAssertTrue(try XCTUnwrap(latest).isRead); XCTAssertTrue(try XCTUnwrap(latest).isStarred)
    }
}
