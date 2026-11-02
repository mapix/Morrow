import XCTest
@testable import MorrowCore

final class AgentSessionWorkspaceTests: XCTestCase {
    func testSessionIsolationPersistenceArchiveRevocationAndRestore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspaces = AgentSessionWorkspaces(owner: root, temporaryRoot: root)
        let a = try await workspaces.open("a"), b = try await workspaces.open("b")
        XCTAssertNotEqual(a.directory, b.directory)
        _ = try await workspaces.write(Data("retained".utf8), path: "output/report.txt", lease: a)
        let reopened = try await workspaces.open("a")
        XCTAssertEqual(a, reopened)
        let data = try await workspaces.read("output/report.txt", lease: reopened)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "retained")
        do { _ = try await workspaces.read("output/report.txt", lease: b); XCTFail("Other session cannot read output") } catch {}
        let scoped = try await workspaces.open("a", scope: "restricted")
        do { _ = try await workspaces.read("output/report.txt", lease: scoped); XCTFail("Scope cannot read parent output") } catch {}
        try await workspaces.archive("a")
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.directory.path))
        do { _ = try await workspaces.write(Data([1]), path: "media/late.png", lease: a); XCTFail("Late writes must be revoked") } catch {}
        do { _ = try await workspaces.open("a"); XCTFail("Archived session cannot open") } catch {}
        await workspaces.restore("a")
        let fresh = try await workspaces.open("a")
        XCTAssertNotEqual(fresh.generation, a.generation)
        do { try await workspaces.validate(a); XCTFail("Old lease remains invalid after restore") } catch {}
        try await workspaces.validate(b)
    }
    func testTraversalSymlinkAndForgedLeaseRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = AgentSessionWorkspaces(owner: root, temporaryRoot: root), lease = try await manager.open("session")
        for path in ["../outside", "/tmp/outside", "media/../../outside", ".workspace.json"] {
            do { _ = try await manager.write(Data([1]), path: path, lease: lease); XCTFail(path) } catch {}
        }
        let outside = root.appendingPathComponent("outside"); try Data([2]).write(to: outside)
        try FileManager.default.createSymbolicLink(at: lease.directory.appendingPathComponent("output/link"), withDestinationURL: outside)
        do { _ = try await manager.read("output/link", lease: lease); XCTFail("Symlink must not escape") } catch {}
        let forged = AgentWorkspaceLease(sessionID: "different", generation: lease.generation, directory: lease.directory)
        do { try await manager.validate(forged); XCTFail("Forged lease must be denied") } catch {}
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lease.directory.path)
        do { try await manager.validate(lease); XCTFail("Unsafe root must be rejected") } catch {}
    }
}
