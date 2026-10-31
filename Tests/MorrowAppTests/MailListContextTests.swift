import XCTest
import MorrowCore
@testable import MorrowApp

final class MailListContextTests: XCTestCase {
    @MainActor private func model() -> AppModel {
        let model = AppModel(root: FileManager.default.temporaryDirectory.appendingPathComponent("mail-list-context-" + UUID().uuidString))
        model.settings.enabled = false; model.workspacePreferences.memoryEnabled = false
        var a = MailAccount(); a.id = "a"; a.email = "a@example.invalid"
        var b = a; b.id = "b"; b.email = "b@example.invalid"
        model.accounts = [a, b]
        model.folders = [.init(accountID: "a", path: "INBOX", role: "inbox"), .init(accountID: "a", path: "Archive", role: "archive"), .init(accountID: "b", path: "INBOX", role: "inbox")]
        model.workspacePage = .mail; model.destination = .inbox
        return model
    }
    private func mail(account: String, folder: String = "INBOX", read: Bool = false, category: MailCategory = .work) -> MailMessage {
        var mail = MailMessage(accountID: account, from: .init(email: "team@example.invalid"), subject: "Synthetic review", text: "Synthetic source body")
        mail.folder = folder; mail.isRead = read
        mail.analysis = MailAnalysis(summary: "Synthetic", category: category, priority: 1)
        return mail
    }
    @MainActor func testLargeInboxContextIsACompactBoundaryNotThousandsOfBodySelections() throws {
        let model = model(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        model.selectedAccount = "a"
        model.mails = (0..<12_000).map { index in var mail = mail(account: "a"); mail.id = "synthetic-\(index)"; return mail }
        let context = model.currentContext
        XCTAssertEqual(context.page, "mail-list")
        XCTAssertTrue(context.mailIDs.isEmpty)
        XCTAssertEqual(context.mailList?.accountIDs, ["a"])
        XCTAssertFalse(context.hasExplicitMailSelection)
        XCTAssertTrue(context.hasMailScope)
        XCTAssertFalse(context.label.contains("12000")); XCTAssertFalse(context.label.contains("12,000"))
        XCTAssertLessThan(try JSONEncoder().encode(context).count, 4096)
    }
    @MainActor func testCapturedAccountFolderAndFiltersIgnoreLaterUIChangesAndNewAccounts() throws {
        let model = model(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        let original = mail(account: "a"), read = mail(account: "a", read: true), other = mail(account: "b")
        var archive = original; archive.id = "archive-copy"; archive.folder = "Archive"
        var inbox = original; inbox.messageID = "<same-synthetic-mail>"; archive.messageID = inbox.messageID
        model.mails = [inbox, read, archive, other]
        model.selectedAccount = "a"; model.unreadOnly = true; model.category = .work
        let captured = model.currentContext
        var added = MailAccount(); added.id = "new"; added.email = "new@example.invalid"; model.accounts.append(added)
        model.mails.append(mail(account: "new"))
        model.selectedAccount = "b"; model.selectedFolder = "Archive"; model.destination = .trash; model.unreadOnly = false; model.category = .finance
        model.folders = [.init(accountID: "a", path: "INBOX", role: "archive")]
        XCTAssertEqual(model.submittedMailIDs(captured), [inbox.id])
        XCTAssertNoThrow(try model.validateChatOperation(.init(type: "star", messageID: inbox.id), context: captured))
        XCTAssertThrowsError(try model.validateChatOperation(.init(type: "star", messageID: archive.id), context: captured))
        XCTAssertThrowsError(try model.validateChatOperation(.init(type: "star", messageID: other.id), context: captured))
    }
    @MainActor func testUnifiedInboxDoesNotExpandIntoAnAccountAddedAfterCapture() throws {
        let model = model(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        let a = mail(account: "a"), b = mail(account: "b")
        model.mails = [a, b]
        let captured = model.currentContext
        var added = MailAccount(); added.id = "new"; model.accounts.append(added)
        let newest = mail(account: "new"); model.mails.append(newest)
        XCTAssertEqual(model.submittedMailIDs(captured), [a.id, b.id])
        XCTAssertThrowsError(try model.validateChatOperation(.init(type: "compose", accountID: "new"), context: captured))
    }
    @MainActor func testExplicitFolderAndLegacySavedSelectionsKeepTheirOwnSemantics() throws {
        let model = model(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        var inbox = mail(account: "a"); inbox.messageID = "<same-synthetic-mail>"
        var archive = inbox; archive.id = "archive"; archive.folder = "Archive"
        model.mails = [inbox, archive]; model.selectedAccount = "a"; model.selectedFolder = "Archive"
        let folder = model.currentContext
        XCTAssertEqual(model.submittedMailIDs(folder), [archive.id])
        let selected = WorkspaceContext(page: "mail", label: "Selected original", mailIDs: [archive.id])
        XCTAssertTrue(selected.hasExplicitMailSelection)
        XCTAssertFalse(WorkspaceContext(page: "people", label: "Contact profile", mailIDs: [archive.id], contactEmail: "team@example.invalid").hasExplicitMailSelection)
        XCTAssertFalse(WorkspaceContext(page: "settings", label: "Other page", mailIDs: [archive.id]).hasExplicitMailSelection)
        XCTAssertEqual(model.submittedMailIDs(selected), [inbox.id, archive.id])
        let legacy = WorkspaceContext(page: "mail-list", label: "Legacy list", mailIDs: [archive.id])
        let decoded = try JSONDecoder().decode(WorkspaceContext.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(decoded.mailList); XCTAssertFalse(decoded.hasExplicitMailSelection)
        XCTAssertEqual(model.submittedMailIDs(decoded), [inbox.id, archive.id])
        let empty = WorkspaceContext(page: "mail-list", label: "Legacy empty")
        XCTAssertTrue(model.submittedMailIDs(empty).isEmpty)
    }
    @MainActor func testSemanticRepresentativeStaysInsideInboxRowBoundary() async throws {
        let model = model(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        var inbox = mail(account: "a"); inbox.messageID = "<shared-canonical>"
        var archive = inbox; archive.id = "archive-vector"; archive.folder = "Archive"
        model.mails = [inbox, archive]; model.selectedAccount = "a"
        try await model.store.upsert(inbox); try await model.store.upsert(archive)
        try await model.store.putVectors(messageID: inbox.id, chunks: ["Inbox source"], vectors: [[1, 0]], model: "scope-fixture", hash: "inbox")
        try await model.store.putVectors(messageID: archive.id, chunks: ["Archive source"], vectors: [[1, 0]], model: "scope-fixture", hash: "archive")
        let captured = model.currentContext
        let hits = try await model.store.vectorSearch([1, 0], model: "scope-fixture", allowedIDs: model.submittedMailIDs(captured))
        XCTAssertEqual(hits.map(\.message.id), [inbox.id])
        XCTAssertNoThrow(try model.validateChatOperation(.init(type: "markRead", messageID: hits.first?.message.id), context: captured))
    }
    func testPortableDestinationCodesAndCapturedRolesWorkWithoutDesktopState() {
        let now = Date(timeIntervalSince1970: 1000)
        var source = mail(account: "a")
        let roles = [MailListContextDescriptor.folderKey(accountID: "a", path: "INBOX"): "inbox", MailListContextDescriptor.folderKey(accountID: "a", path: "Trash"): "trash"]
        let inbox = MailListContextDescriptor(accountIDs: ["a"], destination: "inbox", capturedAt: now, folderRoles: roles)
        XCTAssertTrue(inbox.matches(source))
        XCTAssertEqual(MailListContextDescriptor(accountIDs: ["a"], destination: "收件箱").destinationCode, "inbox")
        source.folder = "Trash"
        XCTAssertFalse(MailListContextDescriptor(accountIDs: ["a"], destination: "all", folderRoles: roles).matches(source))
        XCTAssertTrue(MailListContextDescriptor(accountIDs: ["a"], folderPath: "Trash", destination: "all", folderRoles: roles).matches(source))
        source.folder = "INBOX"; source.snoozedUntil = now.addingTimeInterval(100)
        XCTAssertTrue(MailListContextDescriptor(accountIDs: ["a"], destination: "snoozed", capturedAt: now, folderRoles: roles).matches(source))
        XCTAssertFalse(MailListContextDescriptor(accountIDs: ["a"], destination: "unknown", folderRoles: roles).matches(source))
    }
}
