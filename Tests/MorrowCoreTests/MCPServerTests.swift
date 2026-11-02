import XCTest
@testable import MorrowCore

final class MCPServerTests: XCTestCase {
    private func fixture() async throws -> MailStore {
        let store = try MailStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("mcp-" + UUID().uuidString))
        var account = MailAccount(); account.id = "fixture"; account.email = "reader@example.invalid"; account.oauthClientID = "PRIVATE_CLIENT_CONFIGURATION"
        try await store.save(account, kind: "account", id: account.id)
        var mail = MailMessage(accountID: account.id, from: .init(email: "sender@example.invalid"), subject: "MCP fixture invoice", text: String(repeating: "文", count: 21000) + "BODY_END")
        mail.id = "fixture-mail"; mail.raw = Data("PRIVATE_RAW_MIME".utf8)
        var attachment = MailAttachment(name: "invoice.pdf", mimeType: "application/pdf", data: Data("PRIVATE_ATTACHMENT".utf8)); attachment.storedPath = "/private/fixture/path"
        mail.attachments = [attachment]; try await store.upsert(mail)
        var brief = AgentArtifact(runID: "fixture-run", title: "Invoice brief", kind: .brief, content: "Saved findings", sourceMailIDs: [mail.id]); brief.id = "fixture-brief"
        try await store.save(brief, kind: "agent-artifact", id: brief.id)
        return store
    }
    private func body(_ method: String, _ params: OpenUIJSON = .object([:]), id: OpenUIJSON? = .number(1)) throws -> Data {
        var request: [String: OpenUIJSON] = ["jsonrpc": .string("2.0"), "method": .string(method), "params": params]
        request["id"] = id; return try JSONEncoder().encode(OpenUIJSON.object(request))
    }
    private func request(port: UInt16, token: String? = "fixture-token", method: String = "POST", path: String = "/mcp", body: Data, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!); request.httpMethod = method; request.httpBody = method == "POST" ? body : nil
        request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let configuration = URLSessionConfiguration.ephemeral; configuration.timeoutIntervalForRequest = 5; configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request); return (data, try XCTUnwrap(response as? HTTPURLResponse))
    }

    func testHTTPHandshakeToolsAndImmediateTokenRotation() async throws {
        let store = try await fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        let authorization = MCPAuthorization(token: "fixture-token")
        let server = try MCPHTTPServer(port: 0, allowLAN: false, authorization: authorization, store: store)
        let port = try await server.start()
        do {
            let initialize = try body("initialize", .object(["protocolVersion": .string("2025-11-25"), "capabilities": .object([:]), "clientInfo": .object(["name": .string("fixture"), "version": .string("1")])]))
            let (data, response) = try await request(port: port, body: initialize)
            XCTAssertEqual(response.statusCode, 200); XCTAssertEqual(response.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            let result = try JSONDecoder().decode(OpenUIJSON.self, from: data).object["result"]!.object
            XCTAssertEqual(result["protocolVersion"], .string("2025-11-25")); XCTAssertNotNil(result["capabilities"]?.object["tools"])
            let (_, notified) = try await request(port: port, body: body("notifications/initialized", id: nil)); XCTAssertEqual(notified.statusCode, 202)
            let (listed, listing) = try await request(port: port, body: body("tools/list")); XCTAssertEqual(listing.statusCode, 200)
            XCTAssertTrue(String(decoding: listed, as: UTF8.self).contains("search_mail"))
            let (_, missing) = try await request(port: port, token: nil, body: initialize); XCTAssertEqual(missing.statusCode, 401); XCTAssertNotNil(missing.value(forHTTPHeaderField: "WWW-Authenticate"))
            authorization.rotate(to: "replacement-token")
            let (_, revoked) = try await request(port: port, body: body("ping")); XCTAssertEqual(revoked.statusCode, 401)
            let (_, accepted) = try await request(port: port, token: "replacement-token", body: body("ping")); XCTAssertEqual(accepted.statusCode, 200)
        } catch { await server.stopAndWait(); throw error }
        await server.stopAndWait()
        let replacement = try MCPHTTPServer(port: port, allowLAN: false, authorization: authorization, store: store)
        let restartedPort = try await replacement.start(); XCTAssertEqual(restartedPort, port); await replacement.stopAndWait()
    }

    func testHTTPRejectsOriginsWrongHostsPathsMethodsMediaAndVersions() async throws {
        let store = try await fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        let server = try MCPHTTPServer(port: 0, allowLAN: false, authorization: MCPAuthorization(token: "fixture-token"), store: store), port = try await server.start()
        do {
            let ping = try body("ping")
            for (headers, status) in [(["Origin": "https://foreign.invalid"], 403), (["Host": "rebind.invalid:\(port)"], 403), (["Content-Type": "text/plain"], 415), (["Accept": "application/json"], 406), (["MCP-Protocol-Version": "unknown"], 400)] {
                let (_, response) = try await request(port: port, body: ping, headers: headers); XCTAssertEqual(response.statusCode, status)
            }
            let (_, get) = try await request(port: port, method: "GET", body: ping); XCTAssertEqual(get.statusCode, 405)
            let (_, path) = try await request(port: port, path: "/other", body: ping); XCTAssertEqual(path.statusCode, 404)
        } catch { await server.stopAndWait(); throw error }
        await server.stopAndWait()
    }

    func testReadToolsPaginateExcludePrivateFieldsAndNeverMarkMailRead() async throws {
        let store = try await fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        let tools = MCPMailTools(store: store)
        let accounts = try await tools.call(name: "list_accounts", arguments: .object([:]))
        XCTAssertFalse(accounts.text.contains("PRIVATE_CLIENT_CONFIGURATION"))
        let first = try await tools.call(name: "get_mail", arguments: .object(["id": .string("fixture-mail")]))
        let fields = first.object["structuredContent"]!.object
        XCTAssertEqual(fields["text"]?.text.count, 20000); XCTAssertEqual(fields["next_offset"], .number(20000)); XCTAssertEqual(fields["truncated"], .bool(true))
        for privateField in ["PRIVATE_RAW_MIME", "PRIVATE_ATTACHMENT", "/private/fixture/path"] { XCTAssertFalse(first.text.contains(privateField)) }
        let second = try await tools.call(name: "get_mail", arguments: .object(["id": .string("fixture-mail"), "offset": .number(20000)]))
        XCTAssertTrue(second.object["structuredContent"]!.object["text"]!.text.hasSuffix("BODY_END")); XCTAssertEqual(second.object["structuredContent"]!.object["truncated"], .bool(false))
        let found = try await tools.call(name: "search_mail", arguments: .object(["query": .string("subject:invoice")]))
        XCTAssertTrue(found.text.contains("fixture-mail"))
        let brief = try await tools.call(name: "get_brief", arguments: .object(["id": .string("fixture-brief")]))
        XCTAssertTrue(brief.text.contains("Saved findings")); XCTAssertTrue(brief.text.contains("fixture-mail"))
        let saved = try await store.message("fixture-mail"); XCTAssertEqual(saved?.isRead, false)
        for definition in MCPMailTools.definitions { XCTAssertEqual(definition.object["annotations"]?.object["readOnlyHint"], .bool(true)) }
    }

    func testRPCInvalidInputAndToolFailuresRemainDistinct() async throws {
        let store = try await fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        let rpc = MCPProtocol(store: store)
        let malformed = await rpc.handle(Data("{".utf8)); XCTAssertEqual(malformed?.object["error"]?.object["code"], .number(-32700))
        let batch = await rpc.handle(Data("[]".utf8)); XCTAssertEqual(batch?.object["error"]?.object["code"], .number(-32600))
        let unknown = await rpc.handle(try body("unknown")); XCTAssertEqual(unknown?.object["error"]?.object["code"], .number(-32601))
        for arguments: OpenUIJSON in [.object(["limit": .number(-1)]), .object(["limit": .number(1.5)]), .object(["limit": .string("5")]), .object(["unknown": .bool(true)])] {
            let invalid = await rpc.handle(try body("tools/call", .object(["name": .string("list_mail"), "arguments": arguments])))
            XCTAssertEqual(invalid?.object["error"]?.object["code"], .number(-32602))
        }
        let missing = await rpc.handle(try body("tools/call", .object(["name": .string("get_mail"), "arguments": .object(["id": .string("missing")])])))
        XCTAssertEqual(missing?.object["result"]?.object["isError"], .bool(true)); XCTAssertNil(missing?.object["error"])
    }

    func testHTTPFramingRejectsSmugglingAndOversizedRequests() throws {
        for header in ["Content-Length: 2\r\nContent-Length: 2", "Transfer-Encoding: chunked", "Content-Length: -1", "Content-Length: 1048577", "Content-Length: 0\r\n Authorization: hidden"] {
            XCTAssertThrowsError(try MCPHTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nHost: localhost\r\n\(header)\r\n\r\n{}".utf8)))
        }
        XCTAssertNil(try MCPHTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nHost: localhost\r\nContent-Length: 2\r\n\r\n{".utf8)))
        XCTAssertThrowsError(try MCPHTTPRequest.parse(Data(repeating: 65, count: 17000)))
    }

    func testGeneratedTokensHaveFullEntropyAndBearerSchemeIsCaseInsensitive() throws {
        let tokens = try (0..<50).map { _ in try MCPAuthorization.generateToken() }
        XCTAssertEqual(Set(tokens).count, 50)
        for token in tokens { XCTAssertEqual(token.count, 43); XCTAssertTrue(token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) }
        let authorization = MCPAuthorization(token: tokens[0]); XCTAssertTrue(authorization.accepts("bearer " + tokens[0])); XCTAssertFalse(authorization.accepts("Basic " + tokens[0])); XCTAssertFalse(authorization.accepts(nil))
    }

    func testOfficialTypeScriptClientConnectsOverActualHTTP() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("Runtime/AgentRuntime/node_modules/@modelcontextprotocol/client/dist/index.mjs").path) else { throw XCTSkip("Optional TypeScript MCP client is not installed") }
        let store = try await fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        let server = try MCPHTTPServer(port: 0, allowLAN: false, authorization: MCPAuthorization(token: "fixture-token"), store: store), port = try await server.start()
        do {
            let process = Process(), output = Pipe(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["node", root.appendingPathComponent("scripts/verify-mcp-client.mjs").path, "http://127.0.0.1:\(port)/mcp"]
            process.standardOutput = output; process.standardError = output; try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("8 tools verified"))
        } catch { await server.stopAndWait(); throw error }
        await server.stopAndWait()
    }
}
