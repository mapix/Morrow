import XCTest
import MorrowCore
@testable import MorrowApp

final class MailSyncFailureTests: XCTestCase {
    @MainActor func testBackgroundFailureRemainsVisibleWithoutGlobalModalAndRecoveryClearsIt() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(root: root)
        model.publishMailSyncFailures(["Gmail: synthetic timeout"], userInitiated: false)
        XCTAssertNil(model.error); XCTAssertNotNil(model.mailSyncIssue); XCTAssertFalse(model.mailSyncNeedsAuthorization)
        model.publishMailSyncFailures([], userInitiated: false)
        XCTAssertNil(model.mailSyncIssue); XCTAssertNil(model.error)
    }
    @MainActor func testExplicitRetryReportsFailureAndCredentialAuthorizationIsSeparate() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(root: root)
        model.publishMailSyncFailures(["Gmail: synthetic timeout"], userInitiated: true)
        XCTAssertNotNil(model.error)
        model.error = nil
        model.publishMailSyncFailures(["Gmail: credential permission required"], keychainFailures: 1, userInitiated: true)
        XCTAssertNil(model.error); XCTAssertTrue(model.mailSyncNeedsAuthorization)
    }
}
