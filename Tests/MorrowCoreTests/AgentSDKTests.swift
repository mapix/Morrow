import XCTest
@testable import MorrowCore

final class AgentSDKTests: XCTestCase {
    private func json(_ value: String) throws -> OpenUIJSON { try JSONDecoder().decode(OpenUIJSON.self, from: Data(value.utf8)) }
    func testDiscoveredToolSurvivesResumeAndLegacyCheckpointWithoutCatalog() async throws {
        #if os(macOS)
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Runtime/AgentRuntime")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root), checkpoints = try AgentCheckpointStore(root: root), runtime = try AgentSDKRuntime(runtimeDirectory: directory), spy = SDKDiscoveryFixture(); _ = store
        var request = try json(#"{"type":"start","sessionID":"discovery","instruction":"List my materials","systemPrompt":"Discover tools then list materials","budget":{"modelTurns":1},"tools":[{"name":"list_materials","description":"List uploaded materials","parameters":{"type":"object","properties":{}}}]}"#).object
        let handle: @Sendable (String, OpenUIJSON, @escaping @Sendable (String) async throws -> Void) async throws -> OpenUIJSON = { method, params, _ in
            if method.hasPrefix("state.") { return try await checkpoints.handle(method: method, params: params, sessionID: "discovery") }
            return try await spy.handle(method, params)
        }
        let first = try await runtime.run(.object(request), maximumSeconds: 30, handle: handle, event: { _ in }); XCTAssertEqual(first.paused, true)
        request["resume"] = .string("Continue")
        let second = try await runtime.run(.object(request), maximumSeconds: 30, handle: handle, event: { _ in }); XCTAssertEqual(second.paused, true)
        _ = try await checkpoints.handle(method: "state.remove", params: .object(["key": .string("enabled_tools")]), sessionID: "discovery")
        let third = try await runtime.run(.object(request), maximumSeconds: 30, handle: handle, event: { _ in })
        XCTAssertEqual(third.text, "Materials verified"); XCTAssertEqual(third.paused, false)
        let calls = await spy.calls; XCTAssertEqual(calls, 1)
        #else
        throw XCTSkip("SDK process test requires macOS")
        #endif
    }
    func testToolBudgetStopsBeforeExecutingExcessToolsAndRetainsState() async throws {
        #if os(macOS)
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Runtime/AgentRuntime")
        let runtime = try AgentSDKRuntime(runtimeDirectory: directory), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let mail = try MailStore(root: root), checkpoints = try AgentCheckpointStore(root: root), spy = SDKBudgetFixture(); _ = mail
        let request = try json(#"{"type":"start","sessionID":"tool-budget","instruction":"Find mail","systemPrompt":"Search mail","budget":{"toolCalls":1},"tools":[{"name":"search_mail","description":"Search mail","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}]}"#)
        let result = try await runtime.run(request, maximumSeconds: 30, handle: { method, params, _ in
            if method.hasPrefix("state.") { return try await checkpoints.handle(method: method, params: params, sessionID: "tool-budget") }
            return try await spy.handle(method, params)
        }, event: { _ in })
        XCTAssertEqual(result.paused, true); XCTAssertEqual(result.toolCalls, 1)
        let calls = await spy.calls; XCTAssertEqual(calls, 1)
        let state = try await checkpoints.handle(method: "state.get", params: .object(["key": .string("run")]), sessionID: "tool-budget")
        XCTAssertFalse(state.text.isEmpty)
        #else
        throw XCTSkip("SDK process test requires macOS")
        #endif
    }
    func testTurnBudgetPausesAndResumesSDKWithoutRepeatingCompletedTool() async throws {
        #if os(macOS)
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Runtime/AgentRuntime")
        let runtime = try AgentSDKRuntime(runtimeDirectory: directory), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let mail = try MailStore(root: root), checkpoints = try AgentCheckpointStore(root: root), spy = SDKFixture(); _ = mail
        var request = try json(#"{"type":"start","sessionID":"budget-test","instruction":"Find mail","systemPrompt":"Use search_mail first","budget":{"modelTurns":1},"tools":[{"name":"search_mail","description":"Search mail","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}]}"#).object
        let handle: @Sendable (String, OpenUIJSON, @escaping @Sendable (String) async throws -> Void) async throws -> OpenUIJSON = { method, params, _ in
            if method.hasPrefix("state.") { return try await checkpoints.handle(method: method, params: params, sessionID: "budget-test") }
            return try await spy.handle(method, params)
        }
        let paused = try await runtime.run(.object(request), maximumSeconds: 30, handle: handle, event: { _ in })
        XCTAssertEqual(paused.paused, true); XCTAssertEqual(paused.pauseReason, "turn_budget")
        request["resume"] = .string("继续当前任务")
        let resumed = try await runtime.run(.object(request), maximumSeconds: 30, handle: handle, event: { _ in })
        XCTAssertEqual(resumed.text, "Verified SDK evidence"); XCTAssertEqual(resumed.paused, false)
        let calls = await spy.calls; XCTAssertEqual(calls, 1)
        #else
        throw XCTSkip("SDK process test requires macOS")
        #endif
    }
    func testLiveLocalModelCompletesSDKToolLoopWithSyntheticMail() async throws {
        guard ProcessInfo.processInfo.environment["MORROW_LIVE_SDK"] == "1" else { throw XCTSkip("Opt-in local model validation; synthetic mail only") }
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Runtime/AgentRuntime")
        let runtime = try AgentSDKRuntime(runtimeDirectory: directory), root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root), checkpoints = try AgentCheckpointStore(root: root), model = AgentToolModel()
        _ = store
        var settings = AgentSettings(); settings.provider = "ollama"; settings.model = "qwen3.8:27b-mlx"
        let lockedSettings = settings
        let request = try json(#"{"type":"start","sessionID":"live-sdk-synthetic","instruction":"请用search_mail查询今年的游戏变现邮件，再根据工具中的真实合成资料简短回答；这是测试数据，不发送或修改邮件。","systemPrompt":"你在验收本机SDK。必须先调用search_mail，query包含game monetization。回答使用工具实际结果，不需要文件、分任务或保存报告。不要访问其他资料。","tools":[{"name":"search_mail","description":"Search synthetic mail; no user mailbox access","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}]}"#)
        let result = try await runtime.run(request, maximumSeconds: 180, handle: { method, params, delta in
            if method.hasPrefix("checkpoint.") || method.hasPrefix("state.") { return try await checkpoints.handle(method: method, params: params, sessionID: "live-sdk-synthetic") }
            if method == "model" { return try await model.respond(params, settings: lockedSettings, delta: delta).json() }
            guard method == "tool", params.object["name"]?.text == "search_mail" else { throw MailError.message("Unknown synthetic tool") }
            return try self.json(#"{"rows":[{"messageID":"synthetic-only","subject":"SDK_GAME_REVENUE_TEST","date":"2026-10-20","text":"A game team reports in-app purchase revenue grew 12 percent. Synthetic fixture only."}],"coverage":"one synthetic mail, not the real mailbox"}"#)
        }, event: { _ in })
        XCTAssertGreaterThan(result.toolCalls, 0); XCTAssertFalse(result.text.isEmpty)
        print("LIVE_SDK: runtime=\(result.runtime); model_calls=\(result.modelCalls); tool_calls=\(result.toolCalls); result=\(String(result.text.prefix(240)))")
    }
    func testOllamaToolsAndMessagesKeepTypedArgumentsAndSourceCallIdentity() throws {
        var stream = AgentModelStream(compatible: false)
        _ = try stream.feed(#"{"message":{"content":"","tool_calls":[{"function":{"name":"search_mail","arguments":{"query":"game monetization"}}}]},"done":true,"done_reason":"stop"}"#)
        let result = try stream.result(model: "fixture")
        XCTAssertEqual(result.toolCalls.first?.name, "search_mail")
        XCTAssertEqual(result.toolCalls.first?.args.object["query"]?.text, "game monetization")
        let transformed = try AgentToolModel.ollamaMessages([try json(#"{"role":"assistant","tool_calls":[{"id":"call-1","function":{"name":"search_mail","arguments":"{\"query\":\"game\"}"}}]}"#), try json(#"{"role":"tool","tool_call_id":"call-1","content":"evidence"}"#)])
        XCTAssertEqual(transformed.last?.object["tool_name"]?.text, "search_mail")
        let blocks = try AgentToolModel.ollamaMessages([try json(#"{"role":"system","content":[{"type":"text","text":"one"},{"type":"text","text":"two"}]}"#)])
        XCTAssertEqual(blocks.first?.object["content"]?.text, "one\ntwo")
    }
    func testCompatibleStreamReassemblesNativeToolCallsAndRejectsTruncation() throws {
        var stream = AgentModelStream(compatible: true)
        _ = try stream.feed(#"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call-1","function":{"name":"search_mail","arguments":"{\"query\":"}}]}}]}"#)
        _ = try stream.feed(#"data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"game\"}"}}]},"finish_reason":"tool_calls"}]}"#)
        let result = try stream.result(model: "fixture"); XCTAssertEqual(result.toolCalls.first?.id, "call-1"); XCTAssertEqual(result.toolCalls.first?.args.object["query"]?.text, "game")
        var truncated = AgentModelStream(compatible: false)
        _ = try truncated.feed(#"{"message":{"content":"Partial answer"},"done":true,"done_reason":"length"}"#)
        XCTAssertThrowsError(try truncated.result(model: "fixture"))
    }
    func testGPTToolReplayRetainsEncryptedReasoningAndUsesStatelessRequests() throws {
        let response = try json(#"{"status":"completed","output":[{"type":"reasoning","id":"reason-1","encrypted_content":"synthetic-encrypted"},{"type":"function_call","id":"item-1","call_id":"call-1","name":"search_mail","arguments":"{\"query\":\"game\"}"}]}"#)
        let result = try AgentToolModel.responsesResult(response, model: "fixture")
        XCTAssertEqual(result.toolCalls.first?.id, "call-1"); XCTAssertEqual(result.replay?.count, 2)
        let value: OpenUIJSON = .object(["role": .string("assistant"), "providerItems": .array(result.replay ?? [])])
        let payload = try JSONDecoder().decode(OpenUIJSON.self, from: AgentToolModel.responsesPayload(messages: [value], tools: [], model: "fixture"))
        XCTAssertEqual(payload.object["store"], .bool(false))
        XCTAssertEqual(payload.object["input"], .array(result.replay ?? []))
    }
    func testActualSDKToolsRunAndCheckpointsResumeAcrossProcessesWithoutAnotherDatabase() async throws {
        #if os(macOS)
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Runtime/AgentRuntime")
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("node_modules/@openai/agents/package.json").path) else { throw XCTSkip("Install the pinned AgentRuntime dependencies to run SDK tests") }
        let runtime = try AgentSDKRuntime(runtimeDirectory: directory)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let mail = try MailStore(root: root), checkpoints = try AgentCheckpointStore(root: root), spy = SDKFixture()
        let request = try json(#"{"type":"start","sessionID":"sdk-fixture","instruction":"Find game monetization mail","systemPrompt":"Search before answering. Cite only tool evidence.","tools":[{"name":"search_mail","description":"Search mail","parameters":{"type":"object","properties":{"query":{"type":"string"}},"required":["query"]}}]}"#)
        let handle: @Sendable (String, OpenUIJSON, @escaping @Sendable (String) async throws -> Void) async throws -> OpenUIJSON = { method, params, delta in
            if method.hasPrefix("checkpoint.") || method.hasPrefix("state.") { return try await checkpoints.handle(method: method, params: params, sessionID: "sdk-fixture") }
            return try await spy.handle(method, params)
        }
        let first = try await runtime.run(request, maximumSeconds: 30, handle: handle, event: { _ in })
        XCTAssertEqual(first.text, "Verified SDK evidence"); XCTAssertEqual(first.toolCalls, 1)
        let second = try await runtime.run(request, maximumSeconds: 30, handle: handle, event: { _ in })
        XCTAssertEqual(second.text, "Verified SDK evidence")
        let called = await spy.calls; XCTAssertEqual(called, 1)
        let size = try await checkpoints.usageBytes(); XCTAssertGreaterThan(size, 0); XCTAssertLessThan(size, 1024 * 1024)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".sqlite") }; XCTAssertEqual(names, ["mail.sqlite"])
        let unchanged = try await mail.messageSummaries(); XCTAssertTrue(unchanged.isEmpty)
        do { _ = try await checkpoints.handle(method: "checkpoint.get", params: json(#"{"config":{"thread_id":"other"}}"#), sessionID: "sdk-fixture"); XCTFail("Cross-session checkpoint access was accepted") } catch {}
        #else
        throw XCTSkip("SDK subprocess runs on macOS")
        #endif
    }
}

private actor SDKDiscoveryFixture {
    var turns = 0
    var calls = 0
    func handle(_ method: String, _ params: OpenUIJSON) throws -> OpenUIJSON {
        if method == "tool" { calls += 1; return .array([]) }
        guard method == "model" else { throw MailError.message("Unknown fixture method") }
        turns += 1
        if turns == 3 { return .object(["content": .string("Materials verified"), "toolCalls": .array([])]) }
        let name = turns == 1 ? "find_tools" : "list_materials"
        let args: OpenUIJSON = turns == 1 ? .object(["query": .string("material")]) : .object([:])
        return .object(["content": .string(""), "toolCalls": .array([.object(["id": .string("discovery-\(turns)"), "name": .string(name), "args": args])])])
    }
}

private actor SDKBudgetFixture {
    var calls = 0
    var turns = 0
    func handle(_ method: String, _ params: OpenUIJSON) throws -> OpenUIJSON {
        if method == "tool" { calls += 1; return .object(["evidence": .string("one completed tool")]) }
        guard method == "model" else { throw MailError.message("Unknown fixture method") }
        turns += 1
        return .object(["content": .string(""), "model": .string("fixture"), "toolCalls": .array([.object(["id": .string("call-\(turns)"), "name": .string("search_mail"), "args": .object(["query": .string("page-\(turns)")])])])])
    }
}

private actor SDKFixture {
    var calls = 0
    func handle(_ method: String, _ params: OpenUIJSON) throws -> OpenUIJSON {
        if method == "tool" { calls += 1; return .object(["evidence": .string("SDK_REAL_TOOL_EVIDENCE")]) }
        guard method == "model" else { throw MailError.message("Unknown fixture method") }
        let data = try JSONEncoder().encode(params), found = String(decoding: data, as: UTF8.self).contains("SDK_REAL_TOOL_EVIDENCE")
        return .object(["content": .string(found ? "Verified SDK evidence" : ""), "model": .string("fixture"), "finishReason": .string(found ? "stop" : "tool_calls"),
            "toolCalls": .array(found ? [] : [.object(["id": .string(UUID().uuidString), "name": .string("search_mail"), "args": .object(["query": .string("game monetization")]), "type": .string("tool_call")])])])
    }
}
