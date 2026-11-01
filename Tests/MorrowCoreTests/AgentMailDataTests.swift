import XCTest
@testable import MorrowCore

final class AgentMailDataTests: XCTestCase {
    private func fixture() async throws -> (MailStore, [MailMessage], [MailAccount], [ContactTriage]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try MailStore(root: root)
        var account = MailAccount(); account.id = "a"; account.email = "me@example.invalid"
        var incoming = MailMessage(accountID: "a", from: .init(name: "Alice", email: "alice@example.invalid"), subject: "Project", text: String(repeating: "Prefix ", count: 100) + "BODY_BEYOND_PREVIEW")
        incoming.id = "incoming"; incoming.to = [.init(email: account.email)]
        var sent = MailMessage(accountID: "a", from: .init(email: account.email), subject: "Re: Project", text: "Approved project")
        sent.id = "sent"; sent.to = [incoming.from]
        var outside = incoming; outside.id = "outside"; outside.accountID = "b"; outside.text = "OUTSIDE_SCOPE_SECRET"
        for mail in [incoming, sent, outside] { try await store.upsert(mail) }
        let mails = [incoming, sent], accounts = [account]
        let profiles = ContactProfileBuilder.build(mails: mails, accounts: accounts, manual: [])
        let contacts = ContactTriage.build(profiles: profiles, mails: mails, accounts: accounts, includeUnmailed: true)
        return (store, mails, accounts, contacts)
    }
    private func rows(_ value: OpenUIJSON) -> [OpenUIJSON] { if case .array(let rows) = value.object["rows"] { return rows }; return [] }

    func testSQLJoinsAggregationAndFullBodiesUseOnlyScopedData() async throws {
        let (store, mails, accounts, contacts) = try await fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        let data = try AgentMailData(root: store.root, mails: mails, contacts: contacts, accounts: accounts)
        let result = try data.query("WITH totals AS (SELECT account_id, count(*) AS n FROM mail_index GROUP BY account_id) SELECT a.email,t.n FROM totals t JOIN accounts a ON a.id=t.account_id")
        XCTAssertEqual(rows(result).first?.object["n"], .number(2))
        XCTAssertEqual(rows(try data.query("SELECT email,direct_sent,direct_received FROM contacts")).first?.object["direct_sent"], .number(1))
        let body = try data.query("SELECT id,text FROM mail WHERE id='incoming'")
        XCTAssertTrue(rows(body).first?.object["text"]?.text.contains("BODY_BEYOND_PREVIEW") == true)
        XCTAssertEqual(rows(try data.query("SELECT mail_text('outside') AS secret")).first?.object["secret"], .null)
        XCTAssertTrue(rows(try data.query("SELECT id FROM mail_index WHERE id='outside'")).isEmpty)
        XCTAssertEqual(data.observedIDs, ["incoming"])
    }
    func testSQLRejectsWritesPrivateTablesAttachmentsAndMultiStatements() async throws {
        let (store, mails, accounts, contacts) = try await fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        let data = try AgentMailData(root: store.root, mails: mails, contacts: contacts, accounts: accounts)
        for sql in ["DELETE FROM mail_index", "UPDATE contacts SET name='changed'", "DROP TABLE accounts", "SELECT json FROM objects", "SELECT json FROM main.messages", "ATTACH DATABASE ':memory:' AS other", "PRAGMA writable_schema=ON", "SELECT load_extension('/tmp/plugin')", "SELECT count(*) FROM mail_index; DELETE FROM mail_index", "WITH mail AS (SELECT json FROM main.messages) SELECT * FROM mail"] {
            XCTAssertThrowsError(try data.query(sql), sql)
        }
        XCTAssertEqual(rows(try data.query("SELECT count(*) AS n FROM mail_index")).first?.object["n"], .number(2))
        let incoming = try await store.message("incoming"), outside = try await store.message("outside")
        XCTAssertEqual(incoming?.isRead, false)
        XCTAssertEqual(outside?.text, "OUTSIDE_SCOPE_SECRET")
    }
    func testReturnedRowsAndTextAreBoundedAndMarkedTruncated() async throws {
        let (store, original, accounts, contacts) = try await fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        var mails = original; mails[0].text = String(repeating: "文", count: 40000); try await store.upsert(mails[0])
        let data = try AgentMailData(root: store.root, mails: mails, contacts: contacts, accounts: accounts)
        let result = try data.query("SELECT id,text FROM mail WHERE id='incoming'")
        XCTAssertEqual(result.object["truncated"], .bool(true))
        XCTAssertLessThanOrEqual(rows(result).first?.object["text"]?.text.utf8.count ?? Int.max, 65539)
        let limited = try data.query("SELECT id FROM mail_index ORDER BY id", maximumRows: 1)
        XCTAssertEqual(rows(limited).count, 1); XCTAssertEqual(limited.object["truncated"], .bool(true))
    }
    func testRealSandboxPythonCanAnalyzeAllScopedDataAndCannotReadDatabaseFile() async throws {
        #if os(macOS)
        let (store, mails, accounts, contacts) = try await fixture(); defer { try? FileManager.default.removeItem(at: store.root) }
        let sandbox = try ResponderSandboxRuntime()
        try sandbox.enableMailData(root: store.root, mails: mails, contacts: contacts, accounts: accounts)
        let code = """
        import maildata, json
        total = maildata.query('SELECT count(*) AS n FROM mail_index')['rows'][0]['n']
        body = maildata.query("SELECT id,text FROM mail WHERE id='incoming'")['rows'][0]
        assert total == 2 and 'BODY_BEYOND_PREVIEW' in body['text']
        assert maildata.query("SELECT mail_text('outside') AS text")['rows'][0]['text'] is None
        try:
            maildata.query('DELETE FROM mail_index')
            raise AssertionError('write accepted')
        except ValueError:
            pass
        print(json.dumps({'count': total, 'source': body['id']}))
        """
        let result = try await sandbox.runPython(code, policy: ResponderExecutionPolicy())
        XCTAssertEqual(result.exitCode, 0, result.stderr); XCTAssertTrue(result.stdout.contains("incoming"))
        XCTAssertTrue(sandbox.observedMailDataIDs.contains("incoming"))
        let privateRead = try await sandbox.run("cat '" + store.root.appendingPathComponent("mail.sqlite").path + "'", policy: ResponderExecutionPolicy())
        XCTAssertNotEqual(privateRead.exitCode, 0)
        let incoming = try await store.message("incoming"); XCTAssertEqual(incoming?.isRead, false)
        #else
        throw XCTSkip("Sandbox coding runs on macOS")
        #endif
    }
}
