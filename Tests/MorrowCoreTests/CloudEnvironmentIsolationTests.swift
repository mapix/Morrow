import XCTest
@testable import MorrowCore

final class CloudEnvironmentIsolationTests: XCTestCase {
    func testEnvironmentContainerAndZoneHaveSeparatePersistenceNamespaces() {
        let development = CloudSyncPersistenceScope(container: "iCloud.example.workspace", environment: .development, zone: "workspace")
        let production = CloudSyncPersistenceScope(container: development.container, environment: .production, zone: development.zone)
        XCTAssertNotEqual(development.identifier, production.identifier)
        XCTAssertNotEqual(development.objectKind("cloud-record-state"), production.objectKind("cloud-record-state"))
        XCTAssertNotEqual(development.objectKind("cloud-incoming-failure"), production.objectKind("cloud-incoming-failure"))
        XCTAssertNotEqual(development.identifier, CloudSyncPersistenceScope(container: "iCloud.other.workspace", environment: .development, zone: development.zone).identifier)
        XCTAssertNotEqual(development.identifier, CloudSyncPersistenceScope(container: development.container, environment: .development, zone: "other").identifier)
        XCTAssertNil(CloudSyncEnvironment(rawValue: "")); XCTAssertNil(CloudSyncEnvironment(rawValue: "unknown"))
    }
    func testGlobalAcknowledgementDoesNotMarkNewEnvironmentSynchronized() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("morrow-environment-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root)
        let session = ChatSession(id: "synthetic-session", title: "Synthetic cloud environment fixture")
        try await store.save(session, kind: "chat-session", id: session.id)
        let created = try await store.cloudChanges()
        let version = try XCTUnwrap(created.first)
        try await store.acknowledgeCloudChange(version)
        let globallyPending = try await store.cloudChanges(); XCTAssertTrue(globallyPending.isEmpty)
        try await store.seedCloudJournal()
        let versions = try await store.cloudChanges(dirtyOnly: false)
        let developmentACK = CloudEnvironmentAcknowledgement(id: version.id, clock: version.clock, device: version.deviceID)
        XCTAssertTrue(CloudEnvironmentAcknowledgement.pending(versions, acknowledged: [developmentACK]).isEmpty)
        // A different environment has no ACK even though global dirty is zero.
        let productionPending = CloudEnvironmentAcknowledgement.pending(versions, acknowledged: [])
        XCTAssertEqual(productionPending.map(\.id), [version.id])
        try await store.remove(kind: "chat-session", id: session.id)
        let deleted = try await store.cloudChanges(dirtyOnly: false)
        let pendingDeletion = CloudEnvironmentAcknowledgement.pending(deleted, acknowledged: [developmentACK])
        XCTAssertEqual(pendingDeletion.count, 1); XCTAssertNil(pendingDeletion.first?.payload)
    }
    func testLegacyFilesAndMetadataArePreservedAndNotUsedByNewScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("morrow-cloud-legacy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root)
        let legacyState = Data("synthetic legacy engine token".utf8)
        let legacyURL = root.appendingPathComponent("icloud-engine-state.json")
        try legacyState.write(to: legacyURL)
        try await store.save(legacyState, kind: "cloud-record-state", id: "synthetic-record")
        let production = CloudSyncPersistenceScope(container: "iCloud.example.workspace", environment: .production, zone: "workspace")
        XCTAssertNotEqual(production.directory(in: root).appendingPathComponent("engine-state.json"), legacyURL)
        let scopedFields = try await store.object(Data.self, kind: production.objectKind("cloud-record-state"), id: "synthetic-record")
        XCTAssertNil(scopedFields)
        XCTAssertEqual(try Data(contentsOf: legacyURL), legacyState)
        let preserved = try await store.object(Data.self, kind: "cloud-record-state", id: "synthetic-record")
        XCTAssertEqual(preserved, legacyState)
    }
}
