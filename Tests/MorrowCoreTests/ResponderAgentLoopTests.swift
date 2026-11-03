import XCTest
@testable import MorrowCore

final class ResponderAgentLoopTests: XCTestCase {
    private func mail() -> MailMessage { var m = MailMessage(accountID: "bound", from: .init(email: "team@example.com"), subject: "Review", text: "Please review the attached plan."); m.messageID = "<source@example.com>"; m.uid = 1; m.uidValidity = 7; return m }
    private func rule() -> MailResponder { var r = MailResponder(); r.accountID = "bound"; r.sender = "team@example.com"; r.title = "Review"; r.response = "Read and reply"; r.trustedAuthService = "mx.google.com"; r.enabled = true; return r }
    func testSourcesAreRequiredAndLookalikeDomainsDoNotMatch() throws {
        var r = rule(); try r.validate(); XCTAssertTrue(r.matches(mail()))
        r.accountID = ""; XCTAssertThrowsError(try r.validate()); XCTAssertFalse(r.matches(mail()))
        r = rule(); r.sender = ""; XCTAssertThrowsError(try r.validate()); XCTAssertFalse(r.matches(mail()))
        r = rule(); r.sender = "team@example.com, partner@example.com"
        var partner = mail(); partner.from.email = "partner@example.com"; XCTAssertTrue(r.matches(partner))
        for address in ["team@badexample.invalid", "team@sub.example.invalid", "team@example.com.invalid"] { var m = mail(); m.from.email = address; XCTAssertFalse(r.matches(m)) }
        var m = mail(); m.accountID = "other"; XCTAssertFalse(r.matches(m)); m = mail(); m.folder = "Archive"; XCTAssertFalse(r.matches(m))
        XCTAssertFalse(MailResponder.validSender("@example..com"))
        r.sender = "@example.com"; XCTAssertThrowsError(try r.validate())
        r.sender = "*@example.com"; XCTAssertThrowsError(try r.validate())
    }
    func testReceivingServiceMustConfirmAlignedDMARCAndFirstFailureWins() {
        let prefix = "From: team@example.com\r\nMessage-ID: <source@example.com>\r\n"
        func raw(_ ar: String) -> Data { Data((prefix + ar + "\r\n\r\nBody").utf8) }
        XCTAssertTrue(ResponderPolicy.authenticated(mail(), raw: raw("Authentication-Results: mx.google.com; dmarc=pass header.from=example.com"), service: "mx.google.com"))
        XCTAssertFalse(ResponderPolicy.authenticated(mail(), raw: raw("Authentication-Results: attacker.example; dmarc=pass header.from=example.com"), service: "mx.google.com"))
        XCTAssertFalse(ResponderPolicy.authenticated(mail(), raw: raw("Authentication-Results: mx.google.com; spf=pass; dkim=pass header.d=other.com"), service: "mx.google.com"))
        XCTAssertFalse(ResponderPolicy.authenticated(mail(), raw: raw("Authentication-Results: mx.google.com; dmarc=pass header.from=other.com"), service: "mx.google.com"))
        XCTAssertFalse(ResponderPolicy.authenticated(mail(), raw: raw("Authentication-Results: mx.google.com; dmarc=fail header.from=example.com\r\nAuthentication-Results: mx.google.com; dmarc=pass header.from=example.com"), service: "mx.google.com"))
        XCTAssertFalse(ResponderPolicy.authenticated(mail(), raw: raw("From: other@example.com\r\nAuthentication-Results: mx.google.com; dmarc=pass header.from=example.com"), service: "mx.google.com"))
    }
    func testDefaultSourceMatchingDoesNotRequireAuthenticationHeaders() {
        let raw = Data("From: team@example.com\r\nMessage-ID: <source@example.com>\r\nAuthentication-Results: mx.google.com; spf=pass smtp.mailfrom=team@example.com\r\n\r\nBody".utf8)
        var r = rule()
        XCTAssertEqual(r.requireAuthentication, false)
        XCTAssertNil(ResponderPolicy.sourceFailure(r, mail: mail(), raw: raw))
        r.requireAuthentication = true
        XCTAssertNotNil(ResponderPolicy.sourceFailure(r, mail: mail(), raw: raw))
        r.requireAuthentication = nil
        XCTAssertNil(ResponderPolicy.sourceFailure(r, mail: mail(), raw: raw))
    }
    func testUIDWatermarkRejectsHistoricalImportAndValidityChanges() {
        var r = rule(); r.activatedAt = Date(); r.afterUID = 90; r.activationUIDValidity = 7
        var m = mail(); m.uid = 89; m.uidValidity = 7; XCTAssertFalse(r.isNew(m))
        m.uid = 91; XCTAssertTrue(r.isNew(m)); m.uidValidity = 8; XCTAssertFalse(r.isNew(m))
    }
    func testImportedMessageCannotTriggerAnAutomaticReplyEvenWithForgedAuthentication() {
        var m = mail(); m.id = "import:forged"; m.uid = 0; m.uidValidity = 0
        let raw = Data("From: team@example.com\r\nAuthentication-Results: mx.google.com; dmarc=pass header.from=example.com\r\n\r\nBody".utf8)
        XCTAssertNotNil(ResponderPolicy.sourceFailure(rule(), mail: m, raw: raw))
    }
    func testTimeoutCancelsSlowModelInsteadOfDeliveringLateResponse() async {
        let m = mail(); var p = ResponderExecutionPolicy(); p.maximumSeconds = 1; p.commandSeconds = 1
        let began = Date()
        do { _ = try await ResponderAgentLoop.run(mail: m, attachmentIDs: [], policy: p, plan: { _ in try await Task.sleep(for: .seconds(10)); return .init(answer: "", operations: [.init(type: "draft", text: "Late")]) }, tool: { _ in "Actual evidence" }, verify: { _, _ in .init(approved: true) }, checkpoint: {}); XCTFail("Late reply accepted") } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(began), 3)
    }
    func testPolicyCannotAuthorizeOtherToolsOrWildcardNetworks() throws {
        var p = ResponderExecutionPolicy(); p.allowedTools.append("send"); XCTAssertThrowsError(try p.validate())
        p = .init(); p.networkDomains = ["*.example.com"]; XCTAssertThrowsError(try p.validate())
        p.networkDomains = ["127.0.0.1"]; XCTAssertThrowsError(try p.validate())
        p = .init(); p.allowedTools.removeAll { $0 == "read" }; XCTAssertThrowsError(try p.validate())
    }
    func testLoopReadsToolsThenReplansAndVerifiesBeforeReturningReply() async throws {
        let m = mail(); var calls = 0; var observations: [String] = []; var verified = false
        let result = try await ResponderAgentLoop.run(mail: m, attachmentIDs: ["owned"], plan: { history in
            calls += 1
            if calls == 1 { return PartnerPlan(answer: "Need file", messageIDs: [m.id], operations: [.init(type: "readAttachment", messageID: m.id, text: "owned")]) }
            XCTAssertEqual(history.count, 2)
            return PartnerPlan(answer: "Read and checked", messageIDs: [m.id], operations: [.init(type: "draft", messageID: m.id, text: "Please provide the schedule.")])
        }, tool: { op in observations.append(op.type); return "Actual source evidence" }, verify: { _, _ in verified = true; return .init(approved: true) }, checkpoint: {})
        XCTAssertEqual(result.turns, 2); XCTAssertEqual(observations, ["read", "readAttachment"]); XCTAssertTrue(verified)
    }
    func testLoopRejectsCrossSourceToolAndRecipientWithoutCallingThem() async {
        for operation in [PartnerOperation(type: "read", messageID: "outside"), .init(type: "readAttachment", text: "private-file"), .init(type: "draft", text: "reply", recipient: "other@example.com"), .init(type: "archive", messageID: mail().id)] {
            var tools = 0
            do { _ = try await ResponderAgentLoop.run(mail: mail(), attachmentIDs: [], plan: { _ in .init(answer: "", operations: [operation]) }, tool: { _ in tools += 1; return "read" }, verify: { _, _ in .init(approved: true) }, checkpoint: {}); XCTFail("Escaping operation accepted") } catch {}
            XCTAssertEqual(tools, 1)
        }
    }
    func testVerificationFailureIsFedBackAndCannotBecomeAutomaticSend() async throws {
        let m = mail(); var plans = 0; var checks = 0
        let result = try await ResponderAgentLoop.run(mail: m, attachmentIDs: [], plan: { history in
            plans += 1
            if plans > 1 { XCTAssertTrue(history.last?.text.contains("核对未通过") == true) }
            return .init(answer: "", operations: [.init(type: "draft", text: plans == 1 ? "Unverified promise" : "Please provide details.")])
        }, tool: { _ in "Actual evidence" }, verify: { _, _ in checks += 1; return .init(approved: checks > 1, issues: ["Unverified promise"]) }, checkpoint: {})
        XCTAssertEqual(result.turns, 2); XCTAssertEqual(checks, 2)
    }
    func testNonConvergingLoopStopsAtBudgetInsteadOfDeliveringPlanText() async {
        var plans = 0
        do { _ = try await ResponderAgentLoop.run(mail: mail(), attachmentIDs: [], plan: { _ in plans += 1; return .init(answer: "I already sent it", operations: []) }, tool: { _ in "Actual evidence" }, verify: { _, _ in .init(approved: true) }, checkpoint: {}); XCTFail("Plan text must not be delivered") } catch {}
        XCTAssertEqual(plans, ResponderAgentLoop.maximumTurns)
    }
    func testQueuedReplyIsRevalidatedAfterRuleOrContentChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = try MailStore(root: root); var r = rule(); r.requireAuthentication = false
        var account = MailAccount(); account.id = "bound"; account.email = "you@example.com"; try await store.save(account, kind: "account", id: account.id); r.boundAccountFingerprint = ResponderPolicy.accountFingerprint(account)
        var source = mail(); source.raw = Data("From: team@example.com\r\nMessage-ID: <source@example.com>\r\n\r\nActual source".utf8)
        let m = try await store.upsert(source); try await store.save(r, kind: "responder", id: r.id)
        var receipt = ResponderReceipt(responderID: r.id, mail: m); receipt.ruleFingerprint = r.configurationFingerprint; receipt.sourceBodyVersion = m.bodyVersion
        receipt.agentVerified = true; receipt.sandboxRuntime = "anthropic-srt/0.0.81"
        var d = ComposeDraft(); d.id = receipt.id; d.accountID = m.accountID; d.to = m.from.email; d.inReplyTo = m.messageID; d.body = "Please provide details."; d.automaticResponse = true; d.responderID = r.id; d.responderSourceMailID = m.id; d.state = "queued"; d.scheduledAt = Date.distantPast
        receipt.draftID = d.id; receipt.draftFingerprint = ResponderPolicy.draftFingerprint(d); receipt.state = "queued"
        try await store.save(receipt, kind: "responder-receipt", id: receipt.id); try await store.save(d, kind: "draft", id: d.id)
        try await store.validateResponderDelivery(d)
        var edited = d; edited.to = "other@example.com"; try await store.save(edited, kind: "draft", id: d.id)
        do { _ = try await store.claimDraft(d.id); XCTFail("Recipient edit must block claim") } catch {}
        try await store.save(d, kind: "draft", id: d.id)
        r.enabled = false; try await store.save(r, kind: "responder", id: r.id)
        do { _ = try await store.claimDraft(d.id); XCTFail("Paused responder must block claim") } catch {}
        r.enabled = true; r.response = "Changed instruction"; try await store.save(r, kind: "responder", id: r.id)
        do { _ = try await store.claimDraft(d.id); XCTFail("Changed rule must block claim") } catch {}
    }
}
