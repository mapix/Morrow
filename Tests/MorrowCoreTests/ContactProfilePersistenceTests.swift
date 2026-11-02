import XCTest
@testable import MorrowCore

final class ContactProfilePersistenceTests: XCTestCase {
    private func fixture() -> ContactProfile { .init(email: "person@example.invalid", name: "Old name", aliases: [], mailIDs: ["one"], accountIDs: ["account"], received: 1, sent: 0, copied: 0, firstSeen: nil, lastSeen: nil, topics: ["Old topic"], fingerprint: "old") }
    func testMetadataAnalysisAndCorrectionWritersDoNotOverwriteEachOther() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("contact-writers-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root), original = fixture()
        try await store.save(original, kind: "contact-profile", id: original.id)
        var metadata = original; metadata.name = "New name"; metadata.topics = ["New topic"]; metadata.fingerprint = "new"
        _ = try await store.commitContactProfileCorrection("User correction", id: original.id)
        _ = try await store.commitContactProfileMetadata(metadata)
        var analysis = original; analysis.claims = [.init(text: "Claim", mailID: "one", quote: "Proof")]; analysis.analysisFingerprint = "completed-old-snapshot"
        _ = try await store.commitContactProfileAnalysis(analysis)
        _ = try await store.commitContactProfileCorrection("Latest correction", id: original.id)
        let current = try await store.object(ContactProfile.self, kind: "contact-profile", id: original.id)
        XCTAssertEqual(current?.name, "New name"); XCTAssertEqual(current?.topics, ["New topic"])
        XCTAssertEqual(current?.fingerprint, "new"); XCTAssertEqual(current?.correction, "Latest correction")
        XCTAssertEqual(current?.claims.first?.quote, "Proof")
    }
}
