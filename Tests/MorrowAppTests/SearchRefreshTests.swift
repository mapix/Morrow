import XCTest
import MorrowCore
@testable import MorrowApp

final class SearchRefreshTests: XCTestCase {
    @MainActor func testContinuousMailRefreshDoesNotStarveRetrieval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-refresh-" + UUID().uuidString)
        let model = AppModel(root: root)
        defer { model.navigate(.inbox); try? FileManager.default.removeItem(at: root) }
        model.settings.enabled = false
        var account = MailAccount(); account.id = "synthetic"; account.isDemo = true
        model.accounts = [account]; model.destination = .inbox; model.searchStrategy = .keyword
        var mail = MailMessage(accountID: account.id, from: .init(email: "team@example.invalid"), subject: "contract review", text: "Please review the contract")
        try await model.store.upsert(mail); model.mails = [mail]
        model.searchText = "contract"; model.search()
        var returnedWhileUpdatesContinue = false
        for i in 0..<30 {
            mail.isRead = i.isMultiple(of: 2); model.mails = [mail]
            try await Task.sleep(for: .milliseconds(50))
            if !model.searchBusy && model.searchHits.map(\.id) == [mail.id] { returnedWhileUpdatesContinue = true }
        }
        XCTAssertTrue(returnedWhileUpdatesContinue, "Background updates must not reset the query's debounce indefinitely")
        XCTAssertFalse(model.searchBusy)
        XCTAssertEqual(model.searchHits.first?.message.isRead, mail.isRead)
        model.workspacePage = .mail
        model.search(preserveSelection: true)
        XCTAssertTrue(model.searchBusy)
        XCTAssertEqual(model.searchHits.map(\.id), [mail.id])
        XCTAssertEqual(model.currentContext.mailIDs, [mail.id], "Background updates retain the visible result scope for Chat")
    }

    @MainActor func testExplicitQueryReplacesOldHitsAndPendingRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-query-" + UUID().uuidString)
        let model = AppModel(root: root)
        defer { model.navigate(.inbox); try? FileManager.default.removeItem(at: root) }
        model.settings.enabled = false; model.destination = .inbox; model.searchStrategy = .keyword
        let first = MailMessage(accountID: "synthetic", from: .init(email: "team@example.invalid"), subject: "contract review", text: "contract")
        let second = MailMessage(accountID: "synthetic", from: .init(email: "team@example.invalid"), subject: "delivery review", text: "delivery")
        try await model.store.upsert(first); try await model.store.upsert(second); model.mails = [first, second]
        model.searchText = "contract"; model.search()
        for _ in 0..<50 { if !model.searchBusy { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.searchHits.map(\.id), [first.id])
        model.mails = [first, second]
        model.searchText = "delivery"; model.search()
        XCTAssertTrue(model.searchHits.isEmpty, "A new explicit query must not display previous-query hits")
        for _ in 0..<50 { if !model.searchBusy { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.searchHits.map(\.id), [second.id])
        XCTAssertEqual(model.searchStatus, "关键词搜索")
    }
}
