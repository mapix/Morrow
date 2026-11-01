import XCTest
@testable import MorrowCore

final class ResponderSandboxTests: XCTestCase {
    func testActualRuntimeAllowsStagedInputAndBlocksOutsideReadsWritesAndNetwork() async throws {
        #if os(macOS)
        let sandbox: ResponderSandboxRuntime
        do { sandbox = try ResponderSandboxRuntime() } catch { throw XCTSkip("Install the pinned runtime using npm ci --prefix Runtime/SandboxRuntime: \(error.localizedDescription)") }
        try sandbox.stageText("Synthetic source", name: "mail.txt")
        let policy = ResponderExecutionPolicy()
        let read = try await sandbox.run("cat input/mail.txt", policy: policy)
        XCTAssertEqual(read.exitCode, 0); XCTAssertEqual(read.stdout, "Synthetic source"); XCTAssertEqual(read.runtime, "anthropic-srt/0.0.81")
        let write = try await sandbox.run("printf allowed > output/result.txt", policy: policy); XCTAssertEqual(write.exitCode, 0)
        let overwrite = try await sandbox.run("printf forbidden > input/mail.txt", policy: policy); XCTAssertNotEqual(overwrite.exitCode, 0)
        let outside = try await sandbox.run("cat /etc/hosts", policy: policy); XCTAssertNotEqual(outside.exitCode, 0)
        let network = try await sandbox.run("curl -IsS --max-time 3 https://example.com", policy: policy)
        XCTAssertNotEqual(network.exitCode, 0); XCTAssertTrue(network.stdout.contains("blocked-by-allowlist"))
        let environment = try await sandbox.run("test -z \"$APPLE_ID\" && test -z \"$APPLE_APP_SPECIFIC_PASSWORD\" && test -z \"$OPENAI_API_KEY\"", policy: policy); XCTAssertEqual(environment.exitCode, 0)
        let quotes = try await sandbox.run("printf '%s' 'quotes ! $ backtick `'", policy: policy); XCTAssertEqual(quotes.stdout, "quotes ! $ backtick `")
        #else
        throw XCTSkip("Anthropic SRT responder execution is macOS only")
        #endif
    }
    func testActualRuntimeTimeoutAndOutputLimitStopChildren() async throws {
        #if os(macOS)
        let sandbox: ResponderSandboxRuntime
        do { sandbox = try ResponderSandboxRuntime() } catch { throw XCTSkip("Install the pinned sandbox runtime") }
        var policy = ResponderExecutionPolicy(); policy.commandSeconds = 1
        let timed = try await sandbox.run("sleep 10", policy: policy); XCTAssertTrue(timed.timedOut)
        let noisy = try await sandbox.run("yes bounded", policy: policy); XCTAssertTrue(noisy.truncated); XCTAssertLessThanOrEqual(noisy.stdout.utf8.count, 131072)
        #else
        throw XCTSkip("macOS only")
        #endif
    }
}
