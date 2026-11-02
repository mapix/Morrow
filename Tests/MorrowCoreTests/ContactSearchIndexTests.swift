import XCTest
@testable import MorrowCore

final class ContactSearchIndexTests: XCTestCase {
    private func fixture() -> ContactProfile { .init(email: "test@example.invalid", name: "Test", aliases: [], mailIDs: [], accountIDs: [], received: 0, sent: 0, copied: 0, firstSeen: nil, lastSeen: nil, topics: [], fingerprint: "fixture") }
    func testAllTopicsRemainSearchableAndSameCountEditsInvalidateCache() async throws {
        let index = ContactSearchIndex()
        var profile = fixture()
        profile.topics = (0..<3000).map { "Topic \($0)" }; profile.topics[2999] = "采购发票审核"
        let first = try await index.matchingIDs(in: [profile], query: "发票")
        XCTAssertEqual(first, [profile.id])
        profile.topics[2999] = "合同评审"
        let changed = try await index.matchingIDs(in: [profile], query: "发票")
        XCTAssertTrue(changed.isEmpty)
        let latest = try await index.matchingIDs(in: [profile], query: "合同")
        XCTAssertEqual(latest, [profile.id])
    }
    func testMemoryBudgetDoesNotTruncateSearchAndRemovedProfilesAreReleased() async throws {
        let index = ContactSearchIndex(maximumBytes: 64)
        var profile = fixture(); profile.topics = [String(repeating: "Long topic ", count: 1000) + "needle"]
        let hits = try await index.matchingIDs(in: [profile], query: "needle")
        XCTAssertEqual(hits, [profile.id])
        let bytes = await index.retainedBytes(); XCTAssertLessThanOrEqual(bytes, 64)
        _ = try await index.matchingIDs(in: [], query: "needle")
        let empty = await index.retainedBytes(); XCTAssertEqual(empty, 0)
    }
}
