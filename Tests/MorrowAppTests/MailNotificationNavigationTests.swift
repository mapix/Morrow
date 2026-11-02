import XCTest
import MorrowCore
@testable import MorrowApp

@MainActor final class MailNotificationNavigationTests: XCTestCase {
    private func fixture() async throws -> (AppModel, MailMessage) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notification-navigation-" + UUID().uuidString)
        let model = AppModel(root: root); model.settings.enabled = false; model.started = true; model.ready = true
        var account = MailAccount(); account.id = "fixture"; account.email = "owner@example.invalid"
        model.accounts = [account]; model.folders = [.init(accountID: account.id, path: "INBOX", role: "inbox"), .init(accountID: account.id, path: "Archive", role: "archive")]
        var mail = MailMessage(accountID: account.id, from: .init(email: "sender@example.invalid"), subject: "Notification route", text: "Complete original body")
        mail.id = "original"; mail.isRead = true; mail.uid = 7; mail.uidValidity = 42; mail.messageID = "<notification-route@example.invalid>"
        mail.raw = Data("Original raw fixture".utf8)
        let saved = try await model.store.upsert(mail)
        return (model, saved)
    }
    func testNotificationClickExitsSettingsDraftsAndOutboxAndLoadsMissingCache() async throws {
        let (model, mail) = try await fixture(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        for page in [Destination.settings, .drafts, .outbox] {
            model.navigate(page)
            let opened = await model.openArrivalNotificationMail(id: mail.id)
            XCTAssertTrue(opened); XCTAssertEqual(model.destination, .inbox); XCTAssertEqual(model.selectedID, mail.id)
            XCTAssertEqual(model.selectedAccount, mail.accountID); XCTAssertEqual(model.selectedFolder, mail.folder)
            XCTAssertNotNil(model.mailByID(mail.id))
        }
        let missing = await model.openArrivalNotificationMail(id: "missing")
        XCTAssertFalse(missing)
        model.stopBackgroundWork()
    }
    func testNotificationClickFollowsConfirmedMoveIdentity() async throws {
        let (model, mail) = try await fixture(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        await model.reload()
        model.performServerMailMove = { _, _, _ in MailMoveReceipt.parse("[COPYUID 99 7 9]") }
        await model.move(mail, folder: .init(accountID: mail.accountID, path: "Archive", role: "archive"))
        let movedID = model.resolvedMovedMailID(mail.id)
        XCTAssertNotEqual(movedID, mail.id)
        model.navigate(.settings)
        let opened = await model.openArrivalNotificationMail(id: mail.id)
        XCTAssertTrue(opened); XCTAssertEqual(model.selectedID, movedID); XCTAssertEqual(model.selectedFolder, "Archive")
        model.stopBackgroundWork()
    }
    func testSourceLinkExitsOtherPagesAndRestoresActualMailboxScope() async throws {
        let (model, mail) = try await fixture(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        await model.reload()
        for page in [Destination.settings, .drafts, .outbox] {
            model.navigate(page); model.searchMode = true; model.unreadOnly = true
            model.revealMail(mail)
            XCTAssertEqual(model.destination, .inbox); XCTAssertEqual(model.selectedID, mail.id)
            XCTAssertEqual(model.selectedAccount, mail.accountID); XCTAssertEqual(model.selectedFolder, mail.folder)
            XCTAssertFalse(model.searchMode); XCTAssertFalse(model.unreadOnly)
        }
        model.stopBackgroundWork()
    }
}
