import XCTest
@testable import MorrowCore

final class AgentReadPerformanceTests: XCTestCase {
    private func run(_ fields: [String: OpenUIJSON], fixture: ReadRuntimeFixture) async throws -> AgentSDKResult {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root), checkpoints = try AgentCheckpointStore(root: root), runtime = try AgentSDKRuntime(); _ = store
        var request: [String: OpenUIJSON] = ["type": .string("start"), "sessionID": .string("performance"), "instruction": .string("Find useful contacts"), "systemPrompt": .string("Use evidence"), "tools": .array([.object(["name": .string("read_mail"), "description": .string("Read mail"), "parameters": .object(["type": .string("object"), "properties": .object(["messageID": .object(["type": .string("string")]), "offset": .object(["type": .string("integer")])]), "required": .array([.string("messageID")])])])])]
        request.merge(fields) { _, next in next }
        return try await runtime.run(.object(request), maximumSeconds: 30, handle: { method, params, _ in
            if method.hasPrefix("state.") { return try await checkpoints.handle(method: method, params: params, sessionID: "performance") }
            return try await fixture.handle(method, params)
        }, event: { _ in })
    }
    func testParallelReadsShareOneModelTurnAndCoalesceDuplicateRequests() async throws {
        let fixture = ReadRuntimeFixture(parallel: true)
        let result = try await run([:], fixture: fixture)
        XCTAssertEqual(result.text, "Read evidence delivered"); XCTAssertEqual(result.modelCalls, 2)
        let calls = await fixture.calls, concurrent = await fixture.maximumActive, grouped = await fixture.groupedCalls
        XCTAssertEqual(calls, 7); XCTAssertGreaterThan(concurrent, 1); XCTAssertLessThanOrEqual(concurrent, 4)
        XCTAssertEqual(grouped, 8)
    }
    func testInteractiveBudgetRequestsAnAnswerInsteadOfAnotherReadLoop() async throws {
        let fixture = ReadRuntimeFixture(parallel: false)
        let result = try await run(["answerBudget": .object(["modelTurns": .number(3), "toolCalls": .number(48), "seconds": .number(90)])], fixture: fixture)
        XCTAssertEqual(result.text, "Read evidence delivered"); XCTAssertEqual(result.answerLimited, true)
        XCTAssertEqual(result.modelCalls, 3); XCTAssertEqual(result.toolCalls, 2)
        let calls = await fixture.calls, forced = await fixture.forcedAnswer
        XCTAssertEqual(calls, 1); XCTAssertTrue(forced); XCTAssertEqual(result.paused, false)
    }
    private func runContext(_ fields: [String: OpenUIJSON], fixture: ContextRuntimeFixture) async throws -> AgentSDKResult {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root), checkpoints = try AgentCheckpointStore(root: root), runtime = try AgentSDKRuntime(); _ = store
        var request: [String: OpenUIJSON] = ["type": .string("start"), "sessionID": .string("context-budget"), "instruction": .string("LATEST_USER_KEEP: read only"), "systemPrompt": .string("SYSTEM_AUTHORITY_KEEP: do not change permissions"), "contextWindow": .number(16384), "tools": .array([.object(["name": .string("read_mail"), "description": .string("Read mail"), "parameters": .object(["type": .string("object"), "properties": .object(["messageID": .object(["type": .string("string")])]), "required": .array([.string("messageID")])])])])]
        request.merge(fields) { _, next in next }
        if let history = request.removeValue(forKey: "nativeHistory") {
            _ = try await checkpoints.handle(method: "state.set", params: .object(["key": .string("history"), "value": history]), sessionID: "context-budget")
        }
        return try await runtime.run(.object(request), maximumSeconds: 30, handle: { method, params, _ in
            if method.hasPrefix("state.") {
                await fixture.observeState(method, params)
                return try await checkpoints.handle(method: method, params: params, sessionID: "context-budget")
            }
            return try await fixture.handle(method, params)
        }, event: { _ in })
    }
    func testLargeConcurrentEvidenceConvergesWithinContextWithoutChangingReceipts() async throws {
        let fixture = ContextRuntimeFixture(mode: .large)
        let result = try await runContext(["answerBudget": .object(["modelTurns": .number(20), "toolCalls": .number(48), "seconds": .number(90)])], fixture: fixture)
        XCTAssertEqual(result.text, "Context budget verified"); XCTAssertEqual(result.paused, false); XCTAssertEqual(result.answerLimited, true)
        let count = await fixture.modelCalls, bytes = await fixture.maximumBytes, messages = await fixture.maximumMessages
        XCTAssertEqual(count, 2); XCTAssertLessThanOrEqual(bytes, 196 * 1024); XCTAssertLessThanOrEqual(messages, 224)
        let preserved = await fixture.preservedReceiptFields, original = await fixture.fullOriginalHistory, short = await fixture.sawShortenedEvidence, authority = await fixture.preservedAuthority
        XCTAssertTrue(preserved); XCTAssertTrue(original); XCTAssertTrue(short); XCTAssertTrue(authority)
    }
    func testLargeOldHistoryIsBoundedWithoutPrematurelyEndingTheNewRequest() async throws {
        let fixture = ContextRuntimeFixture(mode: .history)
        let history = (0..<180).flatMap { index in [OpenUIJSON.object(["role": .string("user"), "text": .string("Historical request \(index) " + String(repeating: "h", count: 1000))]), .object(["role": .string("partner"), "text": .string("Historical reply \(index) " + String(repeating: "r", count: 1000))])] }
        let result = try await runContext(["history": .array(history), "answerBudget": .object(["modelTurns": .number(20), "toolCalls": .number(48), "seconds": .number(90)])], fixture: fixture)
        XCTAssertEqual(result.text, "Context budget verified"); XCTAssertEqual(result.paused, false); XCTAssertEqual(result.answerLimited, false)
        let messages = await fixture.maximumMessages, authority = await fixture.preservedAuthority, forced = await fixture.forcedAnswer
        XCTAssertLessThanOrEqual(messages, 224); XCTAssertTrue(authority); XCTAssertFalse(forced)
    }
    func testShorteningPreservesProviderReplayAndToolCallPairs() async throws {
        let fixture = ContextRuntimeFixture(mode: .replay)
        let result = try await runContext(["answerBudget": .object(["modelTurns": .number(20), "toolCalls": .number(48), "seconds": .number(90)])], fixture: fixture)
        XCTAssertEqual(result.text, "Context budget verified"); XCTAssertEqual(result.paused, false)
        let replay = await fixture.preservedReplay, balanced = await fixture.balancedCalls
        XCTAssertTrue(replay); XCTAssertTrue(balanced)
    }
    func testOngoingWorkShortensEvidenceWithoutForcingAStageAnswer() async throws {
        let fixture = ContextRuntimeFixture(mode: .large)
        let result = try await runContext([:], fixture: fixture)
        XCTAssertEqual(result.text, "Context budget verified"); XCTAssertEqual(result.answerLimited, false)
        let short = await fixture.sawShortenedEvidence, forced = await fixture.forcedAnswer
        XCTAssertTrue(short); XCTAssertFalse(forced)
    }
    func testOldToolExchangesAreRemovedAsPairsAndKeepReceiptMetadata() async throws {
        let fixture = ContextRuntimeFixture(mode: .toolHistory)
        var history: [OpenUIJSON] = [.object(["role": .string("user"), "content": .string("Historical synthetic task")])]
        for index in 0..<135 {
            let id = "historical-call-\(index)"
            history.append(.object(["type": .string("function_call"), "id": .string(id), "callId": .string(id), "name": .string("prepare_draft"), "arguments": .string("{}"), "status": .string("completed")]))
            let output = try JSONEncoder().encode(OpenUIJSON.object(["ok": .bool(true), "saved": .bool(true), "draftID": .string("historical-draft-\(index)"), "messageID": .string("historical-source-\(index)"), "text": .string(String(repeating: "history", count: 300))]))
            history.append(.object(["type": .string("function_call_result"), "callId": .string(id), "name": .string("prepare_draft"), "output": .string(String(decoding: output, as: UTF8.self))]))
        }
        let result = try await runContext(["nativeHistory": .array(history)], fixture: fixture)
        XCTAssertEqual(result.text, "Context budget verified"); XCTAssertEqual(result.paused, false)
        let balanced = await fixture.balancedCalls, summary = await fixture.sawReceiptSummary
        XCTAssertTrue(balanced); XCTAssertTrue(summary)
    }
}

private actor ContextRuntimeFixture {
    enum Mode { case large, history, replay, toolHistory }
    let mode: Mode
    var modelCalls = 0, maximumBytes = 0, maximumMessages = 0
    var preservedAuthority = false, forcedAnswer = false, preservedReceiptFields = false
    var fullOriginalHistory = false, sawShortenedEvidence = false, preservedReplay = false, balancedCalls = false
    var sawReceiptSummary = false
    private let encrypted = String(repeating: "encrypted-fixture-", count: 180)
    init(mode: Mode) { self.mode = mode }
    func observeState(_ method: String, _ params: OpenUIJSON) {
        if method == "state.set", params.object["key"]?.text == "history",
           let encoded = try? JSONEncoder().encode(params), String(decoding: encoded, as: UTF8.self).contains("ORIGINAL_END_KEEP") { fullOriginalHistory = true }
    }
    func handle(_ method: String, _ params: OpenUIJSON) throws -> OpenUIJSON {
        if method == "tool" {
            let id = params.object["args"]?.object["messageID"]?.text ?? ""
            return .object(["messageID": .string(id), "text": .string(String(repeating: "文", count: 40000) + "ORIGINAL_END_KEEP"), "offset": .number(37), "nextOffset": .number(8037), "coverage": .string("ACTUAL_SOURCE_COVERAGE_KEEP"), "ok": .bool(!id.hasSuffix("-1")), "errorCode": .string(id.hasSuffix("-1") ? "SOURCE_REVIEW_INCOMPLETE" : "")])
        }
        guard method == "model", case .array(let messages) = params.object["messages"] else { throw MailError.message("Unknown context fixture method") }
        modelCalls += 1
        let encoded = try JSONEncoder().encode(params); maximumBytes = max(maximumBytes, encoded.count); maximumMessages = max(maximumMessages, messages.count)
        guard encoded.count <= 196 * 1024, messages.count <= 224 else { throw MailError.message("Model context exceeded native budget") }
        let transcript = messages.compactMap { $0.object["content"]?.text }.joined(separator: "\n")
        preservedAuthority = transcript.contains("SYSTEM_AUTHORITY_KEEP") && transcript.contains("LATEST_USER_KEEP")
        forcedAnswer = params.object["toolChoice"]?.text == "none"
        if mode == .history { return .object(["content": .string("Context budget verified"), "toolCalls": .array([])]) }
        if modelCalls == 1 && mode != .toolHistory {
            let calls = (0..<(mode == .large ? 2 : 1)).map { index in OpenUIJSON.object(["id": .string("context-call-\(index)"), "name": .string("read_mail"), "args": .object(["messageID": .string("context-source-\(index)")])]) }
            var response: [String: OpenUIJSON] = ["content": .string(""), "toolCalls": .array(calls)]
            if mode == .replay { response["replay"] = .array([.object(["type": .string("reasoning"), "id": .string("reasoning-fixture"), "encrypted_content": .string(encrypted)]), .object(["type": .string("function_call"), "id": .string("context-call-0"), "call_id": .string("context-call-0"), "name": .string("read_mail"), "arguments": .string("{\"messageID\":\"context-source-0\"}")])]) }
            return .object(response)
        }
        var expected = Set<String>(), actual = Set<String>()
        for message in messages {
            if let content = message.object["content"]?.text, content.contains("earlierNativeReceipts") && content.contains("historical-draft-") && content.contains("callId") { sawReceiptSummary = true }
            if case .array(let calls) = message.object["tool_calls"] { expected.formUnion(calls.compactMap { $0.object["id"]?.text }) }
            if case .array(let replay) = message.object["providerItems"] {
                preservedReplay = replay.contains { $0.object["encrypted_content"]?.text == encrypted }
                expected.formUnion(replay.filter { $0.object["type"]?.text == "function_call" }.compactMap { $0.object["call_id"]?.text })
            }
            if message.object["role"]?.text == "tool", let id = message.object["tool_call_id"]?.text {
                actual.insert(id)
                let result = try JSONDecoder().decode(OpenUIJSON.self, from: Data((message.object["content"]?.text ?? "").utf8)).object
                let failed = result["messageID"]?.text.hasSuffix("-1") == true
                preservedReceiptFields = result["ok"] == .bool(!failed) && (!failed || result["errorCode"]?.text == "SOURCE_REVIEW_INCOMPLETE") && result["offset"] == .number(37) && result["nextOffset"] == .number(8037) && result["coverage"]?.text == "ACTUAL_SOURCE_COVERAGE_KEEP" && result["messageID"]?.text.hasPrefix("context-source-") == true
                sawShortenedEvidence = result["contextTruncated"] == .bool(true)
            }
        }
        balancedCalls = expected == actual && !actual.isEmpty
        return .object(["content": .string("Context budget verified"), "toolCalls": .array([])])
    }
}

private actor ReadRuntimeFixture {
    let parallel: Bool
    var turns = 0, calls = 0, active = 0, maximumActive = 0, groupedCalls = 0
    var forcedAnswer = false
    init(parallel: Bool) { self.parallel = parallel }
    func handle(_ method: String, _ params: OpenUIJSON) async throws -> OpenUIJSON {
        if method == "tool" {
            calls += 1; active += 1; maximumActive = max(maximumActive, active)
            try await Task.sleep(for: .milliseconds(80)); active -= 1
            return .object(["messageID": params.object["args"]?.object["messageID"] ?? .null, "text": .string("Known evidence")])
        }
        guard method == "model" else { throw MailError.message("Unknown fixture method") }
        turns += 1
        if turns > 1, case .array(let messages) = params.object["messages"] {
            groupedCalls = messages.reduce(0) { count, message in
                if case .array(let values) = message.object["tool_calls"] { return max(count, values.count) }; return count
            }
        }
        if params.object["toolChoice"]?.text == "none" { forcedAnswer = true }
        if (parallel && turns == 2) || forcedAnswer { return .object(["content": .string("Read evidence delivered"), "toolCalls": .array([])]) }
        let count = parallel ? 8 : 1
        return .object(["content": .string(""), "toolCalls": .array((0..<count).map { index in
            .object(["id": .string("call-\(turns)-\(index)"), "name": .string("read_mail"), "args": .object(["messageID": .string("source-\(index == 1 ? 0 : index)"), "offset": .number(0)])])
        })])
    }
}
