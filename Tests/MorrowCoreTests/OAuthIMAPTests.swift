import XCTest
@testable import MorrowCore

final class OAuthIMAPTests: XCTestCase {
    private let fixtureEmail = "fixture@example.com"
    private let fixtureToken = "dummy-token"

    private struct Fixture {
        let root: URL
        let port: Int
        let caseName: String
    }
    private struct Transcript: Decodable {
        var caseName: String
        var passed: Bool
        var completed: Bool
        var userMatches: Bool
        var decodedMatches: Bool
        var controlByteCount: Int
        var delimiterBytes: [Int]
        var singleLineBase64: Bool
        var responseLocation: String
        var continuationRequested: Bool
        var credentialResponses: Int
        var completionStatus: String?
        var challengeStatus: String?
        var challengeRequirementScope: String?
        var scopeSource: String?
        var emptyResponseBytes: [Int]?
        var failure: String?
    }

    private func fixture(_ caseName: String) throws -> Fixture {
        guard let path = ProcessInfo.processInfo.environment["MORROW_TEST_OAUTH_IMAP_FIXTURE"] else {
            throw XCTSkip("Start scripts/oauth-imap-fixture.py and set MORROW_TEST_OAUTH_IMAP_FIXTURE")
        }
        let root = URL(fileURLWithPath: path)
        let ports = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: root.appendingPathComponent("ports.json")))
        let port = try XCTUnwrap(ports[caseName])
        XCTAssertTrue((1...65535).contains(port))
        return Fixture(root: root, port: port, caseName: caseName)
    }
    private func transcript(_ fixture: Fixture) throws -> Transcript {
        let path = fixture.root.appendingPathComponent(fixture.caseName + "-transcript.json")
        let report = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: path))
        XCTAssertEqual(report.caseName, fixture.caseName)
        XCTAssertTrue(report.completed)
        XCTAssertTrue(report.passed, report.failure ?? "Fixture did not confirm the transcript")
        XCTAssertTrue(report.userMatches)
        XCTAssertTrue(report.decodedMatches)
        XCTAssertTrue(report.singleLineBase64)
        XCTAssertEqual(report.controlByteCount, 3)
        XCTAssertEqual(report.delimiterBytes, [1, 1])
        XCTAssertEqual(report.credentialResponses, 1)
        return report
    }

    func testSASLIRIncludesExactUserBearerAndControlBytesInInitialResponse() async throws {
        let fixture = try fixture("sasl-ir")
        let client = IMAPConnection()
        do {
            try await client.connect(host: "127.0.0.1", port: fixture.port, email: fixtureEmail, password: fixtureToken, tls: false, oauth: true)
            let report = try transcript(fixture)
            XCTAssertEqual(report.responseLocation, "initial")
            XCTAssertFalse(report.continuationRequested)
            XCTAssertEqual(report.completionStatus, "OK")
            await client.close()
        } catch { await client.close(); throw error }
    }

    func testWithoutSASLIRWaitsForContinuationThenSendsExactlyOneResponse() async throws {
        let fixture = try fixture("continuation")
        let client = IMAPConnection()
        do {
            try await client.connect(host: "127.0.0.1", port: fixture.port, email: fixtureEmail, password: fixtureToken, tls: false, oauth: true)
            let report = try transcript(fixture)
            XCTAssertEqual(report.responseLocation, "continuation")
            XCTAssertTrue(report.continuationRequested)
            XCTAssertEqual(report.completionStatus, "OK")
            await client.close()
        } catch { await client.close(); throw error }
    }

    func test401ChallengeReceivesEmptyResponseAndReturnsSafeNOFailure() async throws {
        let fixture = try fixture("challenge-401")
        let client = IMAPConnection()
        var failure: Error?
        do { try await client.connect(host: "127.0.0.1", port: fixture.port, email: fixtureEmail, password: fixtureToken, tls: false, oauth: true) }
        catch { failure = error }
        await client.close()
        let error = try XCTUnwrap(failure, "Server NO must not authenticate the session")
        XCTAssertTrue(error.localizedDescription.contains("401"))
        XCTAssertTrue(error.localizedDescription.contains("NO SASL authentication failed"))
        XCTAssertFalse(error.localizedDescription.contains(fixtureToken))
        let report = try transcript(fixture)
        XCTAssertEqual(report.responseLocation, "initial")
        XCTAssertEqual(report.challengeStatus, "401")
        XCTAssertEqual(report.emptyResponseBytes, [13, 10])
        XCTAssertEqual(report.completionStatus, "NO")
        XCTAssertEqual(report.challengeRequirementScope, "https://mail.google.com/")
        XCTAssertEqual(report.scopeSource, "serverRequirement")
        // The fixture only records the server requirement. It obtains no OAuth grant.
    }
}
