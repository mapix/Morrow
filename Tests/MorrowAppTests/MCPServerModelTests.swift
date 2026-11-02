import XCTest
import MorrowCore
@testable import MorrowApp

final class MCPServerModelTests: XCTestCase {
    @MainActor func testTokenAutomaticallyPersistsRotatesAndFailedSaveKeepsPreviousToken() async throws {
        let store = try MailStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("mcp-model-" + UUID().uuidString)); defer { try? FileManager.default.removeItem(at: store.root) }
        let vault = MCPMemoryTokenStorage(), model = MCPServerModel(store: store, tokenStorage: vault)
        await model.restore(); let first = model.token
        XCTAssertEqual(first.count, 43); XCTAssertFalse(model.settings.enabled); XCTAssertFalse(model.running)
        let reopened = MCPServerModel(store: store, tokenStorage: vault); await reopened.restore(); XCTAssertEqual(reopened.token, first)
        model.resetToken(); XCTAssertNotEqual(model.token, first); let replacement = model.token
        vault.failWrites = true; model.resetToken(); XCTAssertEqual(model.token, replacement); XCTAssertNotNil(model.error)
        let configuration = try JSONDecoder().decode(OpenUIJSON.self, from: Data(model.clientConfiguration.utf8))
        XCTAssertEqual(configuration.object["mcpServers"]?.object["morrow"]?.object["headers"]?.object["Authorization"], .string("Bearer " + replacement))
        let persisted = try await store.load(MCPServerSettings.self, kind: "mcp-server-settings")
        XCTAssertFalse(String(describing: persisted).contains(replacement))
    }
    @MainActor func testSettingsPersistAndInvalidPortDoesNotOverwriteSavedValue() async throws {
        let store = try MailStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("mcp-settings-" + UUID().uuidString)); defer { try? FileManager.default.removeItem(at: store.root) }
        let vault = MCPMemoryTokenStorage(), model = MCPServerModel(store: store, tokenStorage: vault); await model.restore()
        var settings = model.settings; settings.port = 18765; settings.allowLAN = true; await model.update(settings)
        XCTAssertNil(model.error)
        settings.port = 65536; await model.update(settings); XCTAssertNotNil(model.error); XCTAssertEqual(model.settings.port, 18765)
        let reopened = MCPServerModel(store: store, tokenStorage: vault); await reopened.restore()
        XCTAssertEqual(reopened.settings.port, 18765); XCTAssertTrue(reopened.settings.allowLAN); XCTAssertEqual(reopened.token, model.token)
    }
    @MainActor func testQualityPreviewDoesNotReadOrCreateCredentialsOrStartServer() async throws {
        let store = try MailStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("mcp-preview-" + UUID().uuidString)); defer { try? FileManager.default.removeItem(at: store.root) }
        let vault = MCPMemoryTokenStorage(), model = MCPServerModel(store: store, tokenStorage: vault, preview: true)
        await model.restore(); model.resetToken(); var settings = MCPServerSettings(); settings.enabled = true; await model.update(settings)
        XCTAssertNil(vault.value); XCTAssertEqual(model.token, ""); XCTAssertFalse(model.running)
    }
    @MainActor func testOccupiedPortReportsFailureThenRetryStartsAndDisableClosesListener() async throws {
        let store = try MailStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("mcp-lifecycle-" + UUID().uuidString)); defer { try? FileManager.default.removeItem(at: store.root) }
        let occupied = try MCPHTTPServer(port: 0, allowLAN: false, authorization: MCPAuthorization(token: "synthetic"), store: store)
        let port = try await occupied.start()
        let model = MCPServerModel(store: store, tokenStorage: MCPMemoryTokenStorage()); await model.restore()
        var settings = model.settings; settings.enabled = true; settings.port = Int(port)
        await model.update(settings); XCTAssertFalse(model.running); XCTAssertNotNil(model.error)
        await occupied.stopAndWait(); await model.retry()
        XCTAssertTrue(model.running); XCTAssertNil(model.error)
        settings.allowLAN = true; await model.update(settings); XCTAssertTrue(model.running); XCTAssertNil(model.error)
        settings.enabled = false; await model.update(settings); XCTAssertFalse(model.running)
        let replacement = try MCPHTTPServer(port: port, allowLAN: false, authorization: MCPAuthorization(token: "synthetic"), store: store)
        _ = try await replacement.start(); await replacement.stopAndWait()
    }
    @MainActor func testForegroundResetRecoversCredentialFailureWithoutStartingSecondListener() async throws {
        let store = try MailStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("mcp-recovery-" + UUID().uuidString)); defer { try? FileManager.default.removeItem(at: store.root) }
        let reserved = try MCPHTTPServer(port: 0, allowLAN: false, authorization: MCPAuthorization(token: "synthetic"), store: store)
        let port = try await reserved.start(); await reserved.stopAndWait()
        let vault = MCPMemoryTokenStorage(); vault.failReads = true
        let model = MCPServerModel(store: store, tokenStorage: vault); await model.restore(); XCTAssertNotNil(model.error)
        model.resetToken(); XCTAssertEqual(model.token.count, 43)
        var settings = model.settings; settings.enabled = true; settings.port = Int(port); await model.update(settings)
        XCTAssertTrue(model.running); XCTAssertNil(model.error)
        await model.restore(); XCTAssertTrue(model.running); XCTAssertNil(model.error)
        settings.enabled = false; await model.update(settings)
    }
}
private final class MCPMemoryTokenStorage: MCPTokenStorage, @unchecked Sendable {
    var value: String?
    var failWrites = false
    var failReads = false
    func read() throws -> String? { if failReads { throw MailError.message("Synthetic read failure") }; return value }
    func write(_ token: String) throws { if failWrites { throw MailError.message("Synthetic storage failure") }; value = token }
}
