import XCTest
import MorrowCore
@testable import MorrowApp

@MainActor final class MailArrivalNotificationDeliveryTests: XCTestCase {
    private func fixture(permission: MailNotificationPermission = .authorized) throws -> (AppModel, ArrivalNotificationFixture, MailMessage) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arrival-notice-" + UUID().uuidString)
        let notifications = ArrivalNotificationFixture(); notifications.status = permission
        let model = AppModel(root: root, notifications: notifications)
        var account = MailAccount(); account.id = "fixture"; account.email = "owner@example.invalid"
        model.accounts = [account]; model.folders = [.init(accountID: account.id, path: "INBOX", role: "inbox"), .init(accountID: account.id, path: "Archive", role: "archive")]
        model.settings.notifications = true; model.settings.enabled = false; model.settings.autoAnalyze = false
        var mail = MailMessage(accountID: account.id, from: .init(email: "sender@example.invalid"), subject: "Ordinary new email", text: "No AI result is needed")
        mail.uid = 101; mail.uidValidity = 7; mail.messageID = "<fresh@example.invalid>"
        return (model, notifications, mail)
    }
    func testOrdinaryArrivalNotifiesWithoutAIAndCanonicalReplayDoesNotRepeat() async throws {
        let (model, notifications, mail) = try fixture(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        _ = try await model.store.upsert(mail)
        await model.notifyNewArrival(mail, isNewArrival: false); XCTAssertTrue(notifications.delivered.isEmpty)
        await model.notifyNewArrival(mail, isNewArrival: true)
        XCTAssertEqual(notifications.delivered, [mail.id]); XCTAssertNil(model.analysisTask)
        await model.notifyNewArrival(mail, isNewArrival: true); XCTAssertEqual(notifications.delivered.count, 1)
    }
    func testArchiveAliasOwnMailAndDeniedPermissionDoNotAlert() async throws {
        let (model, notifications, mail) = try fixture(); defer { try? FileManager.default.removeItem(at: model.store.root) }
        var archive = mail; archive.id = "archive-alias"; archive.folder = "Archive"
        _ = try await model.store.upsert(archive); _ = try await model.store.upsert(mail)
        await model.notifyNewArrival(mail, isNewArrival: true); XCTAssertTrue(notifications.delivered.isEmpty)
        var own = mail; own.id = "own"; own.messageID = "<own@example.invalid>"; own.from.email = "owner@example.invalid"
        await model.notifyNewArrival(own, isNewArrival: true); XCTAssertTrue(notifications.delivered.isEmpty)
        let (denied, deniedNotifications, deniedMail) = try fixture(permission: .denied)
        defer { try? FileManager.default.removeItem(at: denied.store.root) }
        _ = try await denied.store.upsert(deniedMail); await denied.notifyNewArrival(deniedMail, isNewArrival: true)
        XCTAssertTrue(deniedNotifications.delivered.isEmpty); XCTAssertEqual(denied.notificationPermission, .denied)
    }
}
@MainActor private final class ArrivalNotificationFixture: MailNotificationManaging {
    var status: MailNotificationPermission = .authorized
    var delivered: [String] = []
    func removePending(_ ids: [String]) {}
    func requestAuthorization() async throws -> Bool { status.allowsDelivery }
    func permission() async -> MailNotificationPermission { status }
    func add(id: String, title: String, body: String, at date: Date?) async throws {}
    func addMail(id: String, title: String, body: String, mailID: String) async throws { delivered.append(mailID) }
}
