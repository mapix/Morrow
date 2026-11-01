import XCTest
@testable import MorrowCore

final class BatchBodyFetchTests: XCTestCase {
    func testBodiesFollowUIDEvenWhenServerReordersAndUIDComesAfterLiteral() throws {
        let first = Data("first body".utf8), second = Data("second body".utf8)
        let mapped = try IMAPConnection.fetchedBodies(lines: ["* 2 FETCH (BODY[] {11}", " UID 102)", "* 1 FETCH (UID 101 BODY[] {10}", ")", "S1 OK done"], literals: [second, first], allowed: [101, 102])
        XCTAssertEqual(mapped[101], first); XCTAssertEqual(mapped[102], second)
    }
    func testUnexpectedOrDuplicateUIDCannotOverwriteAnotherMessage() {
        let data = Data("body".utf8)
        XCTAssertThrowsError(try IMAPConnection.fetchedBodies(lines: ["* 1 FETCH (UID 999 BODY[] {4}", ")"], literals: [data], allowed: [101]))
        XCTAssertThrowsError(try IMAPConnection.fetchedBodies(lines: ["* 1 FETCH (UID 101 BODY[] {4}", ")", "* 2 FETCH (UID 101 BODY[] {4}", ")"], literals: [data, data], allowed: [101]))
        XCTAssertThrowsError(try IMAPConnection.fetchedBodies(lines: ["* 1 FETCH (BODY[] {4}", "* OK UID 101", ")"], literals: [data], allowed: [101]))
    }
}
