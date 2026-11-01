import XCTest
@testable import MorrowCore

final class GmailSyncReuseTests: XCTestCase {
    private func account() -> MailAccount {
        var account = MailAccount(); account.id = "synthetic"; account.email = "owner@example.invalid"; account.imapHost = "imap.example.invalid"; return account
    }
    private func source(_ store: MailStore, uid: UInt64 = 1) async throws -> (MailMessage, Data) {
        var draft = ComposeDraft(); draft.to = "reader@example.invalid"; draft.subject = "Synthetic cached source"; draft.body = "Complete source body"
        draft.attachments = [.init(name: "proof.txt", mimeType: "text/plain", data: Data("Synthetic attachment".utf8))]
        let raw = try MIMEWriter.encode(draft, account: account())
        var mail = MIMEParser.parse(raw, accountID: account().id, folder: "INBOX", uid: uid, validity: 42)
        mail.isRead = true; mail.isStarred = true; mail.note = "Original note"
        return (try await store.upsert(mail), raw)
    }
    private func identity(_ mail: MailMessage, size: Int, folder: String? = nil, uid: UInt64? = nil, validity: UInt64? = nil, global: String = "18230923993923822931") -> GmailMessageIdentity {
        .init(accountID: mail.accountID, folder: folder ?? mail.folder, uid: uid ?? mail.uid, validity: validity ?? mail.uidValidity,
              globalID: global, messageID: mail.messageID, rawSize: UInt64(size))
    }
    func testRepeatedSyncReusesSavedAndDurableQueuedUIDsAndValidityResetDoesNot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root), (mail, raw) = try await source(store)
        let job = MailDownloadJob(accountID: account().id, folder: "INBOX", uid: 2, validity: 42, read: true, starred: false, byteCount: raw.count, inventoryStarted: Date())
        _ = try await store.queueMailDownload(raw, job: job)
        let inventory = MailSyncInventory(validity: 42, flags: [:], presentUIDs: [1, 2, 3], highestModSequence: 100, uidNext: 4, incremental: true)
        let first = try await store.mailSyncDownloadPlan(account: account(), folder: "INBOX", inventory: inventory)
        XCTAssertEqual(first.savedCount, 1); XCTAssertEqual(first.queuedCount, 1); XCTAssertEqual(first.remainingUIDs, [3])
        let reopened = try MailStore(root: root)
        let resumed = try await reopened.mailSyncDownloadPlan(account: account(), folder: "INBOX", inventory: inventory)
        XCTAssertEqual(resumed, first)
        var parsed = MIMEParser.parse(raw, accountID: account().id, folder: "INBOX", uid: 2, validity: 42); parsed.isRead = job.read
        _ = try await reopened.commitDownloadedMail(parsed, job: job)
        var third = mail; third.id = "synthetic:INBOX:42:3"; third.uid = 3; _ = try await reopened.upsert(third)
        let done = try await reopened.mailSyncDownloadPlan(account: account(), folder: "INBOX", inventory: inventory)
        XCTAssertEqual(done.reusedCount, 3); XCTAssertTrue(done.remainingUIDs.isEmpty)
        var reset = inventory; reset.validity = 43
        let fresh = try await reopened.mailSyncDownloadPlan(account: account(), folder: "INBOX", inventory: reset)
        XCTAssertEqual(fresh.reusedCount, 0); XCTAssertEqual(fresh.remainingUIDs, [3, 2, 1])
    }
    func testLostQueuedRawCacheMakesUIDEligibleAgainWithoutChangingCompletedMail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root), (mail, raw) = try await source(store)
        let job = MailDownloadJob(accountID: account().id, folder: "INBOX", uid: 2, validity: 42, read: true, starred: false, byteCount: raw.count, inventoryStarted: Date())
        _ = try await store.queueMailDownload(raw, job: job)
        let path = await store.rawURL(job.id); try FileManager.default.removeItem(at: path)
        let inventory = MailSyncInventory(validity: 42, flags: [:], presentUIDs: [1, 2], highestModSequence: 100, uidNext: 3, incremental: true)
        let plan = try await store.mailSyncDownloadPlan(account: account(), folder: "INBOX", inventory: inventory)
        XCTAssertEqual(plan.savedCount, 1); XCTAssertEqual(plan.queuedCount, 0); XCTAssertEqual(plan.remainingUIDs, [2])
        let queued = try await store.queuedMailDownloads(), saved = try await store.message(mail.id), savedRaw = try await store.rawData(mail)
        XCTAssertTrue(queued.isEmpty); XCTAssertEqual(saved?.isRead, true); XCTAssertEqual(savedRaw, raw)
    }
    func testGlobalIdentityReusesRawAndAttachmentsWithIndependentHardLinkPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root), (mail, raw) = try await source(store)
        let origin = identity(mail, size: raw.count), destination = identity(mail, size: raw.count, folder: "[Gmail]/All Mail", uid: 999, validity: 11)
        let result = try await store.reuseGmailBody(source: mail, sourceIdentity: origin, destination: destination,
                                                  flags: .init(read: false, starred: false), inventoryStarted: Date())
        let saved = try XCTUnwrap(result)
        XCTAssertEqual(saved.text, mail.text); XCTAssertEqual(saved.note, mail.note); XCTAssertFalse(saved.isRead)
        let sourceRaw = await store.rawURL(mail.id), targetRaw = await store.rawURL(saved.id)
        let manager = FileManager.default
        XCTAssertEqual(try manager.attributesOfItem(atPath: sourceRaw.path)[.systemFileNumber] as? NSNumber,
                       try manager.attributesOfItem(atPath: targetRaw.path)[.systemFileNumber] as? NSNumber)
        let originalAttachment = try XCTUnwrap(mail.attachments.first?.storedPath), targetAttachment = try XCTUnwrap(saved.attachments.first?.storedPath)
        XCTAssertNotEqual(originalAttachment, targetAttachment)
        XCTAssertEqual(try manager.attributesOfItem(atPath: originalAttachment)[.systemFileNumber] as? NSNumber,
                       try manager.attributesOfItem(atPath: targetAttachment)[.systemFileNumber] as? NSNumber)
        try await store.deleteMessage(saved.id)
        let stillRaw = try await store.rawData(mail), stillAttachment = try await store.attachmentData(mail.attachments[0])
        XCTAssertEqual(stillRaw, raw); XCTAssertEqual(stillAttachment, Data("Synthetic attachment".utf8))
    }
    func testRFCMessageIDCollisionWrongAccountAndSizeCannotAuthorizeReuse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root), (mail, raw) = try await source(store), origin = identity(mail, size: raw.count)
        var destination = identity(mail, size: raw.count, folder: "[Gmail]/All Mail", uid: 999, validity: 11, global: "123")
        let candidates = try await store.gmailBodyCandidates(account: mail.accountID, messageID: mail.messageID, destinationID: destination.mailID, rawSize: UInt64(raw.count))
        XCTAssertEqual(candidates.map(\.id), [mail.id])
        let wrongSizeCandidates = try await store.gmailBodyCandidates(account: mail.accountID, messageID: mail.messageID, destinationID: destination.mailID, rawSize: UInt64(raw.count + 1))
        XCTAssertTrue(wrongSizeCandidates.isEmpty)
        let collision = try await store.reuseGmailBody(source: mail, sourceIdentity: origin, destination: destination, flags: .init(read: false, starred: false), inventoryStarted: Date())
        XCTAssertNil(collision)
        destination.globalID = origin.globalID; destination.accountID = "other"
        let foreign = try await store.reuseGmailBody(source: mail, sourceIdentity: origin, destination: destination, flags: .init(read: false, starred: false), inventoryStarted: Date())
        XCTAssertNil(foreign)
        destination.accountID = mail.accountID; destination.rawSize += 1
        let mismatch = try await store.reuseGmailBody(source: mail, sourceIdentity: origin, destination: destination, flags: .init(read: false, starred: false), inventoryStarted: Date())
        XCTAssertNil(mismatch)
        try await store.cacheGmailIdentity(origin, account: account())
        let cached = try await store.cachedGmailIdentity(account: account(), message: mail); XCTAssertEqual(cached?.globalID, origin.globalID)
        var movedAccount = account(); movedAccount.imapHost = "different.example.invalid"
        let invalidated = try await store.cachedGmailIdentity(account: movedAccount, message: mail); XCTAssertNil(invalidated)
    }
    func testReuseKeepsReadChangesConfirmedAfterInventoryStarted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root), (mail, raw) = try await source(store)
        let inventoryStarted = Date(), confirmed = Date().addingTimeInterval(1)
        _ = try await store.setReadState(ids: [mail.id], read: false, modifiedAt: confirmed)
        _ = try await store.setStarState(ids: [mail.id], starred: false, modifiedAt: confirmed)
        let origin = identity(mail, size: raw.count), destination = identity(mail, size: raw.count, folder: "[Gmail]/All Mail", uid: 999, validity: 11)
        let saved = try await store.reuseGmailBody(source: mail, sourceIdentity: origin, destination: destination,
                                                 flags: .init(read: true, starred: true), inventoryStarted: inventoryStarted)
        XCTAssertEqual(saved?.isRead, false); XCTAssertEqual(saved?.isStarred, false); XCTAssertEqual(saved?.localFlagModifiedAt, confirmed)
    }
    func testReuseRejectsAttachmentPathsOutsideItsStoreAndCleansPartialLinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let store = try MailStore(root: root), (original, raw) = try await source(store)
        let privateFile = outside.appendingPathComponent("other-store-file")
        try Data("Synthetic attachment".utf8).write(to: privateFile)
        var changed = original; changed.attachments[0].storedPath = privateFile.path
        let source = try await store.upsert(changed), origin = identity(source, size: raw.count), destination = identity(source, size: raw.count, folder: "[Gmail]/All Mail", uid: 999, validity: 11)
        let reused = try await store.reuseGmailBody(source: source, sourceIdentity: origin, destination: destination,
                                                  flags: .init(read: false, starred: false), inventoryStarted: Date())
        XCTAssertNil(reused)
        let targetRaw = await store.rawURL(destination.mailID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetRaw.path))
        XCTAssertEqual(try Data(contentsOf: privateFile), Data("Synthetic attachment".utf8))
    }
    func testIdentityHeadersFollowReorderedUIDsAndKeep64BitGlobalIDsExact() throws {
        let header = Data("Message-ID: <fixture@example.invalid>\r\n\r\n".utf8)
        let rows = try IMAPConnection.gmailIdentities(lines: ["* 2 FETCH (X-GM-MSGID 18230923993923822931 RFC822.SIZE 300 BODY[HEADER.FIELDS (MESSAGE-ID)] {\(header.count)}", " UID 99)", "S1 OK complete"], literals: [header], allowed: [99], accountID: "synthetic", folder: "[Gmail]/All Mail", validity: 11)
        XCTAssertEqual(rows[99]?.globalID, "18230923993923822931"); XCTAssertEqual(rows[99]?.messageID, "<fixture@example.invalid>")
        XCTAssertThrowsError(try IMAPConnection.gmailIdentities(lines: ["* 1 FETCH (UID 100 X-GM-MSGID 123 RFC822.SIZE 300 BODY[HEADER.FIELDS (MESSAGE-ID)] {\(header.count)}", ")"], literals: [header], allowed: [99], accountID: "synthetic", folder: "INBOX", validity: 42))
    }
}
