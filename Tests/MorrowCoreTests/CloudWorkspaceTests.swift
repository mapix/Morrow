import XCTest
@testable import MorrowCore

final class CloudWorkspaceTests: XCTestCase {
    private func makeStore() throws -> MailStore {
        try MailStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("morrow-cloud-tests-" + UUID().uuidString))
    }
    func testDisabledServiceHasNoCloudActivity() async throws {
        let service = CloudSyncService(store: try makeStore())
        let state = await service.status()
        XCTAssertFalse(state.enabled); XCTAssertFalse(state.busy); XCTAssertNil(state.lastSync)
    }
    func testJournalExcludesSecretsAndQueues() async throws {
        let store = try makeStore()
        try await store.save(["secret": "fixture"], kind: "account", id: "a")
        try await store.save(["state": "queued"], kind: "draft", id: "d")
        var memory = AgentMemory(content: "Use short replies")
        memory.id = "m"
        try await store.save(memory, kind: "agent-memory", id: memory.id)
        let changes = try await store.cloudChanges()
        XCTAssertEqual(changes.map(\.kind), ["agent-memory"])
    }
    func testOldUploadAcknowledgementCannotDropNewLocalEdit() async throws {
        let store = try makeStore(); var session = ChatSession(id: "session", title: "First")
        try await store.save(session, kind: "chat-session", id: session.id)
        let initialChanges = try await store.cloudChanges()
        let old = try XCTUnwrap(initialChanges.first)
        session.title = "Second"; try await store.save(session, kind: "chat-session", id: session.id)
        try await store.acknowledgeCloudChange(old)
        let remaining = try await store.cloudChanges()
        XCTAssertEqual(remaining.count, 1); XCTAssertGreaterThan(remaining[0].clock, old.clock)
    }
    func testRemoteImportHasNoEchoAndPreservesConflict() async throws {
        let store = try makeStore(); let local = ChatSession(id: "session", title: "Local")
        try await store.save(local, kind: "chat-session", id: local.id)
        let initialChanges = try await store.cloudChanges()
        let before = try XCTUnwrap(initialChanges.first)
        let remote = ChatSession(id: local.id, title: "Remote")
        let change = CloudWorkspaceChange(kind: "chat-session", objectID: local.id, payload: try JSONEncoder().encode(remote), clock: before.clock + 10, deviceID: "phone")
        let applied = try await store.importCloudChange(change); XCTAssertTrue(applied)
        let pending = try await store.cloudChanges(); XCTAssertTrue(pending.isEmpty)
        let saved = try await store.object(ChatSession.self, kind: "chat-session", id: local.id); XCTAssertEqual(saved?.title, "Remote")
        let conflicts = try await store.load(CloudWorkspaceConflict.self, kind: "cloud-conflict"); XCTAssertEqual(conflicts.count, 1)
        try await store.restoreCloudConflict(conflicts[0].id)
        let restored = try await store.object(ChatSession.self, kind: "chat-session", id: local.id); XCTAssertEqual(restored?.title, "Local")
        let outgoing = try await store.cloudChanges(); XCTAssertEqual(outgoing.count, 1); XCTAssertGreaterThan(outgoing[0].clock, change.clock)
    }
    func testTombstoneSurvivesRestartAndRejectsOlderResurrection() async throws {
        let store = try makeStore(); let session = ChatSession(id: "delete", title: "Deleted")
        try await store.save(session, kind: "chat-session", id: session.id)
        let initialChanges = try await store.cloudChanges()
        let prior = try XCTUnwrap(initialChanges.first)
        try await store.remove(kind: "chat-session", id: session.id)
        let removedChanges = try await store.cloudChanges()
        let tombstone = try XCTUnwrap(removedChanges.first); XCTAssertNil(tombstone.payload)
        let imported = try await store.importCloudChange(prior); XCTAssertFalse(imported)
        try await store.seedCloudJournal()
        let seeded = try await store.cloudChanges(); XCTAssertNil(seeded.first?.payload)
        let reopened = try MailStore(root: store.root)
        let durable = try await reopened.cloudChanges(); XCTAssertEqual(durable.first?.clock, tombstone.clock)
    }
    func testCloudMemoryOmitsVectorsAndArtifactCannotExecuteDraft() throws {
        var memory = AgentMemory(content: "Preference"); memory.embedding = [1, 2]; memory.embeddingModel = "fixture"
        let data = try CloudWorkspacePolicy.preparedPayload(JSONEncoder().encode(memory), kind: "agent-memory")
        let restored = try JSONDecoder().decode(AgentMemory.self, from: data)
        XCTAssertNil(restored.embedding); XCTAssertNil(restored.embeddingModel)
        let artifact = AgentArtifact(runID: "r", title: "Reply", kind: .draft, content: "text", linkedDraftID: "queued")
        let copied = try JSONDecoder().decode(AgentArtifact.self, from: CloudWorkspacePolicy.preparedPayload(JSONEncoder().encode(artifact), kind: "agent-artifact"))
        XCTAssertNil(copied.linkedDraftID)
        XCTAssertThrowsError(try CloudWorkspacePolicy.preparedPayload(Data(), kind: "responder"))
    }
}
