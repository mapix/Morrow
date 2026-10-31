import XCTest
import MLX
@testable import MorrowCore

final class CoreTests: XCTestCase {
    func testLiveEmbeddingGemma2ChineseSemanticRetrieval() async throws {
        guard ProcessInfo.processInfo.environment["MORROW_LIVE_EMBEDDINGS"] == "1", let metalPath = ProcessInfo.processInfo.environment["MORROW_TEST_METALLIB"] else { throw XCTSkip("Live model gate is enabled explicitly after the Metal build.") }
        GPU.metallib = URL(fileURLWithPath: metalPath)
        let engine = EmbeddingIndex(); let path = ProcessInfo.processInfo.environment["MORROW_EMBEDDING_DIR"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Morrow/models/embeddinggemma-2").path
        try await engine.load(directory: path)
        let relevant = try await engine.embed("十月份的供应商账单，需要确认发票抬头和付款日期。")
        let unrelated = try await engine.embed("周末徒步的集合地点是公园，记得带水和帽子。")
        let query = try await engine.embed("找一下本月发票和账单", query: true)
        XCTAssertEqual(query.count, 768); XCTAssertEqual(relevant.count, query.count)
        let norm = relevant.reduce(Float(0)) { $0 + $1 * $1 }; XCTAssertEqual(norm, 1, accuracy: 0.01)
        let a = zip(query, relevant).reduce(Float(0)) { $0 + $1.0 * $1.1 }; let b = zip(query, unrelated).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        XCTAssertGreaterThan(a, b)
        print("EmbeddingGemma 2 live: dimension=\(query.count), relevant=\(a), unrelated=\(b)")
    }
    func testLivePartnerReadsAndBuildsDelegationPlan() async throws {
        guard ProcessInfo.processInfo.environment["MORROW_LIVE_AGENT"] == "1" else { throw XCTSkip("Live inference gate is enabled explicitly.") }
        var settings = AgentSettings(); settings.provider = "ollama"; settings.model = "qwen3.8:27b-mlx"
        let engine = PartnerEngine()
        let mail = MailMessage(accountID: "fixture", from: .init(name: "项目组", email: "team@example.com"), subject: "项目评审时间确认", text: "请确认下周二下午两点是否能参加项目评审，并在今天回复。")
        let analysis = try await engine.analyze(mail, settings: settings)
        XCTAssertTrue(analysis.needsReply); XCTAssertGreaterThan(analysis.priority, 0); XCTAssertNotNil(analysis.action); XCTAssertFalse(analysis.replySuggestion.isEmpty)
        let plan = try await engine.plan(instruction: "持续跟进项目评审，收到相关新邮件就准备草稿。匹配词是项目评审。", history: [], mails: [mail], accounts: [], delegations: [], settings: settings)
        XCTAssertTrue(plan.operations?.contains { $0.type == "delegate" } ?? false); XCTAssertFalse(plan.operations?.contains { $0.type == "send" } ?? true)
        print("Live partner analysis and delegation plan verified via \(analysis.source)")
    }
    func testMIMERoundTripUnicodeAttachmentsAndBcc() throws {
        var account = MailAccount(); account.name = "测试发件人"; account.email = "sender@example.com"
        var draft = ComposeDraft(); draft.to = "收件人 <to@example.com>"; draft.cc = "cc@example.com"; draft.bcc = "private@example.com"; draft.subject = String(repeating: "长主题与中文测试", count: 8); draft.body = "你好，\n这里是正文。\nEmoji: ☀️"; draft.attachments = [.init(name: "资料 中文.bin", mimeType: "application/octet-stream", data: Data([0, 13, 10, 255, 42]))]
        let data = try MIMEWriter.encode(draft, account: account)
        let raw = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(raw.contains("private@example.com")); XCTAssertFalse(raw.contains("Bcc:"))
        let mail = MIMEParser.parse(data, accountID: account.id)
        XCTAssertEqual(mail.subject, draft.subject); XCTAssertEqual(mail.from.name, account.name); XCTAssertEqual(mail.to.first?.email, "to@example.com"); XCTAssertEqual(mail.cc.first?.email, "cc@example.com")
        XCTAssertEqual(mail.text, draft.body); XCTAssertEqual(mail.attachments.first?.name, "资料 中文.bin"); XCTAssertEqual(mail.attachments.first?.data, draft.attachments.first?.data)
        XCTAssertFalse(mail.isRead)
    }
    func testRichTextAlternativeAndAttachmentRemainSeparate() throws {
        var account = MailAccount(); account.email = "sender@example.com"
        var draft = ComposeDraft(); draft.to = "to@example.com"; draft.subject = "Rich text"; draft.body = "项目评审"; draft.htmlBody = "<p><strong>项目评审</strong></p>"; draft.attachments = [.init(name: "notes.txt", mimeType: "text/plain", data: Data("attachment".utf8))]
        let mail = MIMEParser.parse(try MIMEWriter.encode(draft, account: account), accountID: account.id)
        XCTAssertEqual(mail.text, draft.body); XCTAssertEqual(mail.html, draft.htmlBody); XCTAssertEqual(mail.attachments.count, 1); XCTAssertEqual(mail.attachments[0].data, draft.attachments[0].data)
    }
    func testMultipartAlternativeHeaderFoldingAndQuotedPrintable() {
        let raw = """
        From: =?UTF-8?B?5rWL6K+V?= <test@example.com>
        Subject: =?UTF-8?B?5L2g5aW9?=
         =?UTF-8?B?5LiW55WM?=
        Date: Fri, 30 Oct 2026 10:00:00 +0800
        Content-Type: multipart/alternative; boundary="b"

        --b
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        =E4=BD=A0=E5=A5=BD=\n=E4=B8=96=E7=95=8C
        --b
        Content-Type: text/html; charset=utf-8

        <p>Hello &amp; world</p>
        --b--
        """
        let mail = MIMEParser.parse(Data(raw.utf8), accountID: "a")
        XCTAssertEqual(mail.subject, "你好世界"); XCTAssertEqual(mail.from.name, "测试"); XCTAssertEqual(mail.text, "你好世界"); XCTAssertTrue(mail.html.contains("Hello")); XCTAssertEqual(mail.date.ISO8601Format(), "2026-10-30T02:00:00Z")
    }
    func testRejectHeaderInjectionAndInvalidRecipient() {
        var d = ComposeDraft(); d.to = "victim@example.com\r\nBcc: injected@example.com"; d.subject = "test"
        XCTAssertThrowsError(try d.validate())
        d.to = "not-an-email"; XCTAssertThrowsError(try d.validate())
        XCTAssertThrowsError(try IMAPConnection.quote("INBOX\r\nDELETE INBOX"))
    }
    func testFolderFlagsAndUnreadFlagsParsing() {
        let list = "* LIST (\\HasNoChildren) \"/\" \"INBOX\"\r\n* LIST (\\Sent) \"/\" \"Sent Messages\"\r\n* LIST (\\Noselect) \"/\" \"Parent\"\r\n* LIST (\\Trash) \"/\" \"Trash\""
        let folders = MailTransport.parseFolders(list, accountID: "a")
        XCTAssertEqual(folders.count, 3); XCTAssertEqual(folders.first?.role, "inbox"); XCTAssertTrue(folders.contains { $0.role == "sent" })
        let flags = MailTransport.parseFlags("* 1 FETCH (UID 7 FLAGS ())\r\n* 2 FETCH (FLAGS (\\Seen \\Flagged) UID 9)\r\n")
        XCTAssertEqual(flags[7]?.read, false); XCTAssertEqual(flags[9]?.read, true); XCTAssertEqual(flags[9]?.starred, true)
    }
    func testStorageRestartAndVectorSurvivesAnnotationChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root)
        var m = MailMessage(accountID: "a", from: .init(email: "sender@example.com"), subject: "中文发票", text: "项目十月账单")
        m.raw = Data("raw mail".utf8); m.attachments = [.init(name: "data.csv", mimeType: "text/csv", data: Data("a,b\n1,2".utf8))]
        let persisted = try await store.upsert(m)
        XCTAssertTrue(persisted.raw.isEmpty); XCTAssertTrue(persisted.attachments[0].data.isEmpty)
        try await store.putVectors(messageID: m.id, chunks: [m.text], vectors: [[1, 0, 0]], model: "fixture", hash: "hash")
        var changed = persisted; changed.isRead = true; changed.note = "My note"; try await store.upsert(changed)
        let count = try await store.indexCount(); XCTAssertEqual(count, 1)
        let reopened = try MailStore(root: root)
        let hits = try await reopened.vectorSearch([1, 0, 0], model: "fixture"); XCTAssertEqual(hits.first?.id, m.id); XCTAssertEqual(hits.first?.snippet, m.text)
        let optionalMail = try await reopened.message(m.id)
        let loaded = try XCTUnwrap(optionalMail); XCTAssertTrue(loaded.isRead); XCTAssertEqual(loaded.note, "My note")
        let attachment = try await reopened.attachmentData(loaded.attachments[0]); XCTAssertEqual(attachment, m.attachments[0].data)
        let search = try await reopened.keywordSearch("发票"); XCTAssertEqual(search.first?.id, m.id)
        let raw = try await reopened.rawData(loaded); XCTAssertEqual(raw, m.raw)
        try await reopened.deleteMessage(m.id); let finalCount = try await reopened.indexCount(); XCTAssertEqual(finalCount, 0)
    }
    func testChunkCoverageAndOverlap() {
        let text = String(repeating: "邮件资料测试", count: 1000); let chunks = EmbeddingIndex.chunks(text)
        XCTAssertGreaterThan(chunks.count, 1); XCTAssertEqual(String(chunks[0].suffix(150)), String(chunks[1].prefix(150)))
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 1200 }); XCTAssertEqual(chunks.last?.suffix(40), text.suffix(40))
    }
    func testMailboxUnicodeAndOAuthPKCE() throws {
        XCTAssertEqual(MailboxCodec.decode(MailboxCodec.encode("项目/邮件 & 资料")), "项目/邮件 & 资料")
        XCTAssertEqual(MailboxCodec.encode("Inbox & archive"), "Inbox &- archive")
        XCTAssertEqual(OAuthProvider.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let verifier = try OAuthProvider.verifier(); XCTAssertEqual(verifier.count, 43); XCTAssertFalse(verifier.contains("="))
    }
    func testSearchFiltersDoNotTreatHeaderConstraintsAsBodyKeywords() {
        var mail = MailMessage(accountID: "a", from: .init(name: "项目组", email: "team@example.com"), subject: "评审", text: "内容")
        let query = MailQuery("from:team@example.com is:unread subject:\"评审\"")
        XCTAssertTrue(query.hasFilters); XCTAssertTrue(query.text.isEmpty); XCTAssertTrue(query.matches(mail))
        mail.isRead = true; XCTAssertFalse(query.matches(mail)); mail.isRead = false; mail.from.email = "other@example.com"; XCTAssertFalse(query.matches(mail))
    }
    func testDelegationSendGrantBoundToRecipientAndRealAccount() {
        var account = MailAccount(); account.email = "sender@example.com"
        var d = Delegation(); d.sendAuthorized = true; d.recipient = "allowed@example.com"
        var draft = ComposeDraft(); draft.accountID = account.id; draft.to = "allowed@example.com"
        XCTAssertTrue(DelegationPolicy.maySend(draft, delegation: d, accounts: [account]))
        draft.bcc = "third-party@example.com"; XCTAssertFalse(DelegationPolicy.maySend(draft, delegation: d, accounts: [account]))
        draft.bcc = ""; draft.to = "intruder@example.com"; XCTAssertFalse(DelegationPolicy.maySend(draft, delegation: d, accounts: [account]))
        draft.to = "allowed@example.com"; account.isDemo = true; XCTAssertFalse(DelegationPolicy.maySend(draft, delegation: d, accounts: [account]))
        account.isDemo = false; d.sendAuthorized = false; XCTAssertFalse(DelegationPolicy.maySend(draft, delegation: d, accounts: [account]))
    }
    func testMovingMailCannotCreateAnotherDelegationDelivery() {
        var mail = MailMessage(accountID: "account", from: .init(email: "sender@example.com"), subject: "Review", text: "Please review."); mail.messageID = "<stable@example.com>"; mail.id = "account:INBOX:42:7"
        let d = Delegation(); let first = DelegationPolicy.runID(delegation: d, evidence: [mail], now: Date())
        mail.id = "account:Archive:88:13"; mail.folder = "Archive"
        XCTAssertEqual(first, DelegationPolicy.runID(delegation: d, evidence: [mail], now: Date()))
        mail.accountID = "other-account"; XCTAssertNotEqual(first, DelegationPolicy.runID(delegation: d, evidence: [mail], now: Date()))
    }
    func testMeetingInvitationReplyPreservesIdentityAndParticipant() throws {
        let data = Data("BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nBEGIN:VEVENT\r\nUID:meeting@example.com\r\nSUMMARY:项目评审\r\nDTSTART;TZID=Asia/Shanghai:20261103T140000\r\nDTEND;TZID=Asia/Shanghai:20261103T150000\r\nORGANIZER:mailto:organizer@example.com\r\nATTENDEE:mailto:you@example.com\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n".utf8)
        let invitation = try XCTUnwrap(CalendarInvitation.parse(data).first)
        XCTAssertEqual(invitation.start.ISO8601Format(), "2026-11-03T06:00:00Z")
        let attachment = try invitation.reply(from: "you@example.com", accepted: true)
        let reply = String(decoding: attachment.data, as: UTF8.self)
        XCTAssertTrue(reply.contains("METHOD:REPLY")); XCTAssertTrue(reply.contains("UID:meeting@example.com")); XCTAssertTrue(reply.contains("PARTSTAT=ACCEPTED:mailto:you@example.com"))
        XCTAssertThrowsError(try invitation.reply(from: "unrelated@example.com", accepted: true))
    }
    func testDeadlineCannotInventWorkingHoursOrUnsupportedQuote() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 18))!
        XCTAssertNil(DeadlineEvidence.validated(date, quote: "周一前给出意见", original: "麻烦周一前给出意见。"))
        XCTAssertNil(DeadlineEvidence.validated(date, quote: "今天18:00前回复", original: "请今天下班前回复。"))
        XCTAssertEqual(DeadlineEvidence.validated(date, quote: "今天18:00前回复", original: "请今天18:00前回复。"), date)
        XCTAssertNil(DeadlineEvidence.validated(date.addingTimeInterval(3600), quote: "今天18:00前回复", original: "请今天18:00前回复。"))
    }
    func testReplySuggestionCannotInventAttendancePaymentOrApproval() {
        XCTAssertTrue(ReplySuggestionPolicy.containsUnverifiedConfirmation("我可以参加下周的会议。"))
        XCTAssertTrue(ReplySuggestionPolicy.containsUnverifiedConfirmation("I have paid the invoice."))
        let reply = ReplySuggestionPolicy.neutralReply(subject: "评审", original: "你是否能参加评审？")
        XCTAssertFalse(ReplySuggestionPolicy.containsUnverifiedConfirmation(reply)); XCTAssertTrue(reply.contains("核对"))
    }
    func testDelegationReceiptDraftAndEventCommitTogether() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root); var d = Delegation(); d.title = "Follow up"; d.processedMessageIDs = ["message-1"]
        var draft = ComposeDraft(); draft.id = "deterministic-run"; draft.state = "queued"; draft.body = "Prepared reply"
        let event = PartnerEvent(title: d.title, detail: draft.body, messageIDs: d.processedMessageIDs, delegationID: d.id, kind: "delegation-result")
        try await store.commitDelegation(d, draft: draft, event: event)
        let reopened = try MailStore(root: root); let delegations = try await reopened.load(Delegation.self, kind: "delegation"); let drafts = try await reopened.load(ComposeDraft.self, kind: "draft"); let events = try await reopened.load(PartnerEvent.self, kind: "event")
        XCTAssertEqual(delegations.first?.processedMessageIDs, ["message-1"]); XCTAssertEqual(drafts.first?.state, "queued"); XCTAssertEqual(events.first?.delegationID, d.id)
    }
    func testConcurrentOutboxWorkersCanOnlyClaimDeliveryOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let first = try MailStore(root: root); let second = try MailStore(root: root)
        var draft = ComposeDraft(); draft.state = "queued"; draft.scheduledAt = Date().addingTimeInterval(-10)
        try await first.save(draft, kind: "draft", id: draft.id)
        async let a = first.claimDraft(draft.id)
        async let b = second.claimDraft(draft.id)
        let values = try await [a, b]
        XCTAssertEqual(values.compactMap { $0 }.count, 1)
        let persisted = try await second.load(ComposeDraft.self, kind: "draft"); XCTAssertEqual(persisted.first?.state, "sending")
        let third = try await first.claimDraft(draft.id); XCTAssertNil(third)
    }
    func testMailboxCopiesShareVectorsAndProduceOneKeywordResult() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root)
        var first = MailMessage(accountID: "a", from: .init(email: "sender@example.com"), subject: "Invoice", text: "Invoice details"); first.id = "first"; first.messageID = "<same@example.com>"
        var copy = first; copy.id = "copy"; copy.folder = "Archive"
        try await store.upsert(first); try await store.upsert(copy)
        try await store.putVectors(messageID: first.id, chunks: [first.text], vectors: [[1, 0, 0]], model: "fixture", hash: "same-body")
        let reused = try await store.reuseVectors(canonical: first.canonicalID, targetID: copy.id, model: "fixture", hash: "same-body"); XCTAssertTrue(reused)
        let count = try await store.indexCount(); XCTAssertEqual(count, 1)
        let hits = try await store.keywordSearch("Invoice"); XCTAssertEqual(hits.count, 1); XCTAssertEqual(hits[0].message.folder, "INBOX")
        try await store.deleteMessage(first.id); let after = try await store.indexCount(); XCTAssertEqual(after, 1)
        let vectors = try await store.vectorSearch([1, 0, 0], model: "fixture"); XCTAssertEqual(vectors.first?.id, copy.id)
    }
    func testNativeIMAPLiteralReadPreservesUnreadAndMessageBytes() async throws {
        guard let port = ProcessInfo.processInfo.environment["MORROW_TEST_IMAP_PORT"].flatMap(Int.init) else { throw XCTSkip("Protocol fixture is started by scripts/test.sh") }
        let client = IMAPConnection(); try await client.connect(host: "127.0.0.1", port: port, email: "test@example.com", password: "fixture-password", tls: false)
        let folders = try await client.list(accountID: "test"); XCTAssertTrue(folders.contains { $0.path == "INBOX" })
        let (validity, flags) = try await client.inventory("INBOX"); XCTAssertEqual(validity, 42); XCTAssertEqual(flags[7]?.read, false)
        let raw = try await client.fetch(folder: "INBOX", uid: 7, expectedValidity: validity)
        let mail = MIMEParser.parse(raw, accountID: "test"); XCTAssertEqual(mail.subject, "Fixture mail"); XCTAssertEqual(mail.text, "Please confirm the review time.")
        let (_, after) = try await client.inventory("INBOX"); XCTAssertEqual(after[7]?.read, false)
        try await client.store(folder: "INBOX", uid: 7, flag: "\\Seen", enabled: true)
        let (_, marked) = try await client.inventory("INBOX"); XCTAssertEqual(marked[7]?.read, true)
        await client.close()
    }
    func testSMTPRealProtocolUploadAndBccEnvelope() async throws {
        guard let port = ProcessInfo.processInfo.environment["MORROW_TEST_SMTP_PORT"].flatMap(Int.init) else { throw XCTSkip("Protocol fixture is started by scripts/test.sh") }
        let transport = MailTransport(); var a = MailAccount(); a.name = "Fixture"; a.email = "sender@example.com"
        var d = ComposeDraft(); d.to = "to@example.com"; d.bcc = "hidden@example.com"; d.subject = "SMTP fixture"; d.body = "Real protocol upload"
        let raw = try MIMEWriter.encode(d, account: a)
        _ = try await transport.request(url: "smtp://127.0.0.1:\(port)", username: a.email, password: "fixture-password", upload: raw, from: a.email, recipients: ["to@example.com", "hidden@example.com"])
    }
}
