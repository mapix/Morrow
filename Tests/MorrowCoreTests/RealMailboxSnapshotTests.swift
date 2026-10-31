import XCTest
import MLX
@testable import MorrowCore

/// Explicitly opt-in; runs against a private SQLite backup, never the live DB.
final class RealMailboxSnapshotTests: XCTestCase {
    func testOfflineRealMailboxRetrievalAndContactCoverage() async throws {
        guard let path = ProcessInfo.processInfo.environment["MORROW_REAL_SNAPSHOT"],
              let shader = ProcessInfo.processInfo.environment["MORROW_TEST_METALLIB"] else {
            throw XCTSkip("Requires an explicit private mailbox snapshot and actual Metal library.")
        }
        let root = URL(fileURLWithPath: path)
        XCTAssertTrue(root.lastPathComponent.hasPrefix("real-snapshot-"))
        GPU.metallib = URL(fileURLWithPath: shader)
        let store = try MailStore(root: root)
        let accounts = try await store.load(MailAccount.self, kind: "account")
        let mails = try await store.messages()
        XCTAssertFalse(accounts.isEmpty)
        XCTAssertTrue(accounts.allSatisfy { !$0.isDemo })
        XCTAssertTrue(mails.allSatisfy { mail in accounts.contains { $0.id == mail.accountID && !$0.isDemo } })
        let index = EmbeddingIndex()
        try await index.load(directory: "/Applications/Morrow.app/Contents/Resources/embeddinggemma-2")
        let coverage = try await index.searchCoverage(store: store)
        XCTAssertGreaterThan(coverage.indexedCount, 0)
        let hits = try await index.search("需要核对账单或付款信息的往来", store: store, strategy: .semantic, limit: 5)
        XCTAssertFalse(hits.isEmpty)
        XCTAssertTrue(hits.allSatisfy { $0.method == "语义（EmbeddingGemma 2）" && $0.score.isFinite })
        let profiles = ContactProfileBuilder.build(mails: mails, accounts: accounts, manual: [], previous: [])
        let ids = Set(mails.map(\.id))
        XCTAssertFalse(profiles.isEmpty)
        XCTAssertTrue(profiles.allSatisfy { Set($0.mailIDs).isSubset(of: ids) })
        let attachments = MailAttachmentRecord.index(mails)
        XCTAssertTrue(attachments.allSatisfy { ids.contains($0.mail.id) })
        let drafts = try await store.load(ComposeDraft.self, kind: "draft")
        XCTAssertFalse(drafts.contains { ["queued", "sending"].contains($0.state) })
        print("REAL_SNAPSHOT_READONLY mails=\(coverage.eligibleCount) indexed=\(coverage.indexedCount) semanticHits=\(hits.count) profiles=\(profiles.count) attachments=\(attachments.count) queuedSends=0 remoteWrites=0")
    }
}
