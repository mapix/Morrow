import XCTest
import MorrowCore
@testable import MorrowApp

final class SettingsSaveFeedbackTests: XCTestCase {
    @MainActor func testSaveStaysBusyUntilWriteAcknowledgedAndRejectsDuplicateTap() async {
        let state = SettingsSaveFeedback()
        var continuation: CheckedContinuation<Void, Never>?
        var writes = 0
        let first = Task { await state.perform(scope: .model) { writes += 1; await withCheckedContinuation { continuation = $0 } } }
        while continuation == nil { await Task.yield() }
        XCTAssertEqual(state.phase, .saving)
        XCTAssertTrue(state.isSaving)
        let duplicate = await state.perform { writes += 1 }
        XCTAssertFalse(duplicate)
        XCTAssertEqual(writes, 1)
        continuation?.resume()
        let completed = await first.value
        XCTAssertTrue(completed)
        XCTAssertEqual(state.phase, .saved)
        XCTAssertFalse(state.isSaving)
        XCTAssertEqual(state.scope, .model)
    }

    @MainActor func testFailureShowsReasonAndDoesNotClaimSaved() async {
        let state = SettingsSaveFeedback()
        let saved = await state.perform { throw MailError.message("synthetic database write failed") }
        XCTAssertFalse(saved)
        XCTAssertEqual(state.phase, .failed("synthetic database write failed"))
        XCTAssertTrue(state.failed)
        state.edited()
        XCTAssertEqual(state.phase, .idle)
    }

    @MainActor func testGeneralSavePersistsModelDraftWithoutChangingOtherSettings() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("settings-save-" + UUID().uuidString)
        let model = AppModel(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        model.settings.enabled = false; model.settings.autoAnalyze = false
        model.settings.syncInterval = 300; model.settings.indexAttachments = false
        var draft = model.settings
        draft.provider = "ollama"; draft.ollamaURL = "http://127.0.0.1:11434"; draft.model = "synthetic-model"
        let state = SettingsSaveFeedback()
        let saved = await state.perform { try await model.saveModelConfiguration(draft) }
        let stored = try await model.store.load(AgentSettings.self, kind: "settings").first
        XCTAssertTrue(saved)
        XCTAssertEqual(state.phase, .saved)
        XCTAssertEqual(stored?.model, "synthetic-model")
        XCTAssertEqual(stored?.provider, "ollama")
        XCTAssertEqual(stored?.syncInterval, 300)
        XCTAssertEqual(stored?.enabled, false)
        XCTAssertEqual(stored?.indexAttachments, false)
    }
    @MainActor func testDecisionConfigurationPersistsSeparatelyFromThinkingModel() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("decision-settings-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        let model=AppModel(root:root);model.settings.enabled=false;model.settings.provider="ollama";model.settings.model="fixture-thinker"
        var draft=model.settings;var decision=RetrievalDecisionSettings();decision.model="fixture-decision";decision.baseURL="http://127.0.0.1:11435";decision.filterIrrelevant=false;draft.retrievalDecision=decision
        try await model.saveModelConfiguration(draft)
        let saved=try await model.store.load(AgentSettings.self,kind:"settings").first
        XCTAssertEqual(saved?.model,"fixture-thinker");XCTAssertEqual(saved?.provider,"ollama");XCTAssertEqual(saved?.retrievalDecision,decision)
        XCTAssertEqual(saved?.enabled,false)
    }
}
