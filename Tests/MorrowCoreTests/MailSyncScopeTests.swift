import XCTest
@testable import MorrowCore

final class MailSyncScopeTests: XCTestCase {
    func testActiveScopeIncludesOnlyInboxSentAndDraftsWithLegacyGmailNames() {
        let expected = ["INBOX": true, "[Gmail]/Sent Mail": true, "[Gmail]/Drafts": true,
                        "[Gmail]/All Mail": false, "[Gmail]/Trash": false, "[Gmail]/Spam": false, "Project": false]
        for (path, included) in expected {
            XCTAssertEqual(MailSyncScope.active.includes(.init(accountID: "fixture", path: path)), included, path)
        }
        XCTAssertTrue(MailSyncScope.withArchive.includes(.init(accountID: "fixture", path: "[Gmail]/All Mail")))
        XCTAssertFalse(MailSyncScope.withArchive.includes(.init(accountID: "fixture", path: "[Gmail]/Trash")))
        XCTAssertFalse(MailSyncScope.withArchive.includes(.init(accountID: "fixture", path: "[Gmail]/Spam")))
        XCTAssertFalse(MailSyncScope.inbox.includes(.init(accountID: "fixture", path: "Sent", role: "sent")))
        XCTAssertTrue(MailSyncScope.all.includes(.init(accountID: "fixture", path: "Trash", role: "trash")))
        XCTAssertEqual(MailFolder.inferredRole(path: "垃圾箱"), "junk")
        XCTAssertEqual(MailFolder.inferredRole(path: "[Gmail]/已删除邮件"), "trash")
    }
    func testMissingSpecialUseFlagsResolvePrefixedFoldersWithoutPrefixFlagMatches() {
        let text = #"* LIST (\HasNoChildren) "/" "[Gmail]/Sent Mail""# + "\r\n"
            + #"* LIST (\HasNoChildren) "/" "[Gmail]/Trash""# + "\r\n"
            + #"* LIST (\HasNoChildren) "/" "[Gmail]/Spam""# + "\r\n"
            + #"* LIST (\HasNoChildren \Alligator) "/" "Project""#
        let folders = MailTransport.parseFolders(text, accountID: "fixture")
        XCTAssertEqual(folders.first { $0.path.hasSuffix("Sent Mail") }?.role, "sent")
        XCTAssertEqual(folders.first { $0.path.hasSuffix("Trash") }?.role, "trash")
        XCTAssertEqual(folders.first { $0.path.hasSuffix("Spam") }?.role, "junk")
        XCTAssertEqual(folders.first { $0.path == "Project" }?.role, "custom")
    }
    func testOldSettingsAndFlagsDecodeWithSafeDefaults() throws {
        let settings = try JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(AgentSettings()))
        XCTAssertEqual(settings.effectiveMailSyncScope, .active)
        let flags = try JSONDecoder().decode(MailSyncFlags.self, from: Data(#"{"read":true,"starred":false}"#.utf8))
        XCTAssertFalse(flags.deleted); XCTAssertTrue(flags.read)
    }
}
