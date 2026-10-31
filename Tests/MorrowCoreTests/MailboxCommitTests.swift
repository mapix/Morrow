import XCTest
@testable import MorrowCore

final class MailboxCommitTests: XCTestCase {
    func testConnectionCommitRejectsAnotherAccountsFoldersWithoutSavingAccount() async throws {
        let store = try MailStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var account = MailAccount(); account.id = "a"; account.email = "a@example.com"
        do { try await store.commitMailboxConnection(account, folders: [.init(accountID: "b", path: "INBOX")]); XCTFail("Foreign folders must not be committed") } catch {}
        let saved = try await store.object(MailAccount.self, kind: "account", id: "a")
        let folders = try await store.load(MailFolder.self, kind: "folder")
        XCTAssertNil(saved); XCTAssertTrue(folders.isEmpty)
    }
    func testConnectionCommitKeepsAccountAndItsFoldersTogether() async throws {
        let store = try MailStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var account = MailAccount(); account.id = "a"; account.email = "a@example.com"
        let expected = [MailFolder(accountID: "a", path: "INBOX", role: "inbox"), .init(accountID: "a", path: "Sent", role: "sent")]
        try await store.commitMailboxConnection(account, folders: expected)
        let saved = try await store.object(MailAccount.self, kind: "account", id: "a")
        let folders = try await store.load(MailFolder.self, kind: "folder")
        XCTAssertEqual(saved?.email, account.email); XCTAssertEqual(Set(folders), Set(expected))
    }
}
