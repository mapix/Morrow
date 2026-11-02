import XCTest
import MorrowCore
@testable import MorrowApp

final class QualityPreviewRequestTests: XCTestCase {
    func testPreviewCannotFallBackToRememberedProductionWorkspace() throws {
        XCTAssertNil(try QualityPreviewRequest.parse(arguments: ["Morrow", "--data-dir", "/tmp/fixture"]))
        for args in [["Morrow", "--quality-preview"], ["Morrow", "--quality-preview", "--data-dir", "/tmp/fixture"], ["Morrow", "--quality-preview", "--transient-workspace", "--data-dir", "relative"]] {
            XCTAssertThrowsError(try QualityPreviewRequest.parse(arguments: args))
        }
        let request = try XCTUnwrap(try QualityPreviewRequest.parse(arguments: ["Morrow", "--quality-preview", "--transient-workspace", "--data-dir", "/tmp/fixture"]))
        XCTAssertEqual(request.directory.path, "/tmp/fixture")
    }
    @MainActor func testPreviewReloadAndIndependentRefreshEntrypointsNeverStartBackgroundServices() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("quality-entrypoints-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let notifications = QualityNotifications()
        let model = AppModel(root: root, notifications: notifications, qualityPreview: .init(directory: root))
        var settings = AgentSettings(); settings.enabled = true; settings.autoAnalyze = true; settings.notifications = true
        settings.embeddingDirectory = root.appendingPathComponent("missing-model").path
        try await model.store.save(settings, kind: "settings", id: "main")
        var account = MailAccount(); account.id = "fixture"; account.email = "owner@example.invalid"
        try await model.store.save(account, kind: "account", id: account.id)
        let mail = MailMessage(accountID: account.id, from: .init(email: "contact@example.invalid"), subject: "Quality fixture", text: "No inference is allowed")
        _ = try await model.store.upsert(mail)
        let profiles = ContactProfileBuilder.build(mails: [mail], accounts: [account], manual: [])
        for profile in profiles { try await model.store.save(profile, kind: "contact-profile", id: profile.id) }
        await model.start(); XCTAssertTrue(model.ready); XCTAssertTrue(model.isQualityPreview)
        await model.reload(); await model.refreshContactProfiles()
        model.scheduleContactRefresh(); model.scheduleProfileAnalysis(force: profiles.first?.email)
        model.process(); model.runBackgroundTick(now: Date().addingTimeInterval(3600))
        await model.refreshModels(); await model.sync(); await model.runResponders(); await model.runDelegations(); await model.sendPending()
        await model.askPartner("No model request may run")
        var synchronizationCalled = false
        await model.runMailSynchronization { synchronizationCalled = true }
        await Task.yield()
        XCTAssertFalse(synchronizationCalled); XCTAssertNil(model.profileTask); XCTAssertNil(model.contactRefreshTask)
        XCTAssertNil(model.analysisTask); XCTAssertNil(model.mailDownloadProcessingTask); XCTAssertNil(model.scheduledDeliveryTask)
        XCTAssertEqual(notifications.calls, 0); XCTAssertNil(model.error)
    }
}
@MainActor private final class QualityNotifications: MailNotificationManaging {
    var calls = 0
    func removePending(_ ids: [String]) { calls += 1 }
    func requestAuthorization() async throws -> Bool { calls += 1; return false }
    func permission() async -> MailNotificationPermission { calls += 1; return .unknown }
    func add(id: String, title: String, body: String, at date: Date?) async throws { calls += 1 }
}
