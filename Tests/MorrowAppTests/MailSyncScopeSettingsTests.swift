import XCTest
import MorrowCore
@testable import MorrowApp

final class MailSyncScopeSettingsTests: XCTestCase {
    @MainActor func testScopeChangePreservesCachedArchiveAndModelConfigurationAndCancelsSync() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(root: root)
        model.settings.enabled = false; model.settings.autoAnalyze = false
        model.settings.provider = "openai"; model.settings.openAIModel = "fixture-model"
        model.settings.mailAnalysis = .init(ollamaURL: "http://127.0.0.1:11434", model: "fixture-local")
        model.settings.mailSyncScope = .all
        var mail = MailMessage(accountID: "fixture", from: .init(email: "source@example.invalid"), subject: "Cached archive", text: "Synthetic cached body")
        mail.folder = "[Gmail]/All Mail"; mail.raw = Data("synthetic cached raw".utf8)
        let saved = try await model.store.upsert(mail)
        XCTAssertTrue(model.isInAutomaticMailScope(mail))
        var started = false, cancelled = false
        let running = Task { @MainActor in
            await model.runMailSynchronization {
                model.syncBusy = true; defer { model.syncBusy = false }
                started = true
                do { try await Task.sleep(for: .seconds(20)) } catch { cancelled = true }
            }
        }
        while !started { await Task.yield() }
        try await model.saveMailSyncScope(.active); await running.value
        XCTAssertTrue(cancelled); XCTAssertFalse(model.syncBusy); XCTAssertFalse(model.isInAutomaticMailScope(mail))
        let settings = try await model.store.object(AgentSettings.self, kind: "settings", id: "main")
        XCTAssertEqual(settings?.effectiveMailSyncScope, .active)
        XCTAssertEqual(settings?.provider, "openai"); XCTAssertEqual(settings?.openAIModel, "fixture-model")
        XCTAssertEqual(settings?.mailAnalysis?.model, "fixture-local")
        let retained = try await model.store.message(saved.id), raw = try await model.store.rawData(saved)
        XCTAssertNotNil(retained); XCTAssertEqual(raw, Data("synthetic cached raw".utf8))
    }
    func testProgressIdentifiesIncrementalCheckWithoutBodyDownloads() {
        let plan = MailSyncDownloadPlan(presentUIDs: [1, 2], savedUIDs: [1, 2], queuedUIDs: [])
        let progress = MailSyncProgress(plan: plan, checkMode: "增量检查")
        XCTAssertEqual(progress.total, 0); XCTAssertEqual(progress.downloaded, 0); XCTAssertEqual(progress.reused, 2)
        XCTAssertTrue(progress.summary.contains(" · "))
    }
}
