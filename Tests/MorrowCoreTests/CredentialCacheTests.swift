import XCTest
import Security
@testable import MorrowCore

final class CredentialCacheTests: XCTestCase {
    func testRepeatedBackgroundReadsUseOneDecryptionAndExplicitReloadRefreshesIt() throws {
        let cache = SessionCredentialCache(); var reads = 0
        for _ in 0..<100 {
            let value = try cache.read("fixture-mail", allowInteraction: false) { allowed in
                XCTAssertFalse(allowed); reads += 1; return "fixture-token"
            }
            XCTAssertEqual(value, "fixture-token")
        }
        XCTAssertEqual(reads, 1)
        let renewed = try cache.read("fixture-mail", allowInteraction: true, force: true) { allowed in
            XCTAssertTrue(allowed); reads += 1; return "fixture-renewed"
        }
        XCTAssertEqual(renewed, "fixture-renewed"); XCTAssertEqual(reads, 2)
        let next = try cache.read("fixture-mail", allowInteraction: false) { _ in XCTFail("Cached credential was read again"); return nil }
        XCTAssertEqual(next, "fixture-renewed")
    }
    func testDeniedReadDoesNotRetryUntilExplicitAuthorization() throws {
        let cache = SessionCredentialCache(); var reads = 0
        for _ in 0..<50 {
            XCTAssertThrowsError(try cache.read("fixture-mail", allowInteraction: false) { allowed in
                XCTAssertFalse(allowed); reads += 1; throw CredentialStoreError(status: errSecInteractionNotAllowed)
            })
        }
        XCTAssertEqual(reads, 1)
        _ = try cache.read("fixture-mail", allowInteraction: true, force: true) { allowed in
            XCTAssertTrue(allowed); reads += 1; return "fixture-token"
        }
        XCTAssertEqual(reads, 2)
        _ = try cache.read("fixture-mail", allowInteraction: false) { _ in XCTFail("Authorization was not cached"); return nil }
    }
    func testCancelledAuthorizationDoesNotTriggerAnotherBackgroundPrompt() {
        let cache = SessionCredentialCache(); var reads = 0
        XCTAssertThrowsError(try cache.read("fixture-mail", allowInteraction: true, force: true) { allowed in
            XCTAssertTrue(allowed); reads += 1; throw CredentialStoreError(status: errSecUserCanceled)
        })
        for _ in 0..<20 { XCTAssertThrowsError(try cache.read("fixture-mail", allowInteraction: false) { _ in reads += 1; return "fixture-token" }) }
        XCTAssertEqual(reads, 1)
    }
    func testRotationPreservesCacheOnlyAfterSuccessfulPersistenceAndCanRetryAfterPermission() throws {
        let cache = SessionCredentialCache(); var writes = 0
        try cache.write("fixture-mail", value: "fixture-old", allowInteraction: true) { writes += 1 }
        XCTAssertThrowsError(try cache.write("fixture-mail", value: "fixture-new", allowInteraction: false) {
            writes += 1; throw CredentialStoreError(status: errSecInteractionNotAllowed)
        })
        XCTAssertThrowsError(try cache.write("fixture-mail", value: "fixture-new", allowInteraction: false) { writes += 1 })
        XCTAssertEqual(writes, 2)
        try cache.write("fixture-mail", value: "fixture-new", allowInteraction: true) { writes += 1 }
        let value = try cache.read("fixture-mail", allowInteraction: false) { _ in XCTFail("Saved rotation was not cached"); return nil }
        XCTAssertEqual(value, "fixture-new"); XCTAssertEqual(writes, 3)
        cache.invalidate("fixture-mail")
        let reloaded = try cache.read("fixture-mail", allowInteraction: false) { _ in "fixture-other" }
        XCTAssertEqual(reloaded, "fixture-other")
    }
    func testConcurrentBackgroundReadsAreCoalesced() {
        let cache = SessionCredentialCache(), counter = CredentialReadCounter()
        DispatchQueue.concurrentPerform(iterations: 30) { _ in
            do {
                let value = try cache.read("fixture-mail", allowInteraction: false) { allowed in
                    XCTAssertFalse(allowed); counter.increment(); Thread.sleep(forTimeInterval: 0.005); return "fixture-token"
                }
                XCTAssertEqual(value, "fixture-token")
            } catch { XCTFail(error.localizedDescription) }
        }
        XCTAssertEqual(counter.value, 1)
    }
}

private final class CredentialReadCounter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
