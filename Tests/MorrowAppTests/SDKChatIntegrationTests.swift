import XCTest
import MorrowCore
@testable import MorrowApp

final class SDKChatIntegrationTests: XCTestCase {
    @MainActor func testResponderReviewEndsToolLoopEvenWhenModelRepeatsSetup() async throws {
        let (model, _, _) = try await fixture(mode: "responder-repeat")
        defer { try? FileManager.default.removeItem(at: model.store.root) }
        await model.askPartner("为trusted@example.invalid创建响应器，先让我审阅策略", uiContext: model.currentContext)
        let reply = try XCTUnwrap(model.visibleChat.last)
        XCTAssertEqual(SDKChatHTTPFixture.count, 3)
        XCTAssertEqual(reply.executionTrace?.tools.filter { $0.tool == "setup_responder" }.count, 1)
        XCTAssertTrue(reply.text.contains("尚未保存或启用"))
        XCTAssertNil(reply.sdkResumeKind)
        XCTAssertEqual(model.openUIInteractions.last?.responderDraft?.senderAllowlist, ["trusted@example.invalid"])
        XCTAssertTrue(model.responders.isEmpty)
        let receipts = try await model.store.load(OpenUIJSON.self, kind: "agent-sdk-receipt")
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts.first?.object["saved"], .bool(false))
    }
    @MainActor func testReportHintDoesNotDisableOrdinaryChatAnswerBudget() async throws {
        let (model, _, _) = try await fixture(mode: "stage-budget")
        defer { try? FileManager.default.removeItem(at: model.store.root) }
        let report = AgentRun(title: "Unrelated domain report", instruction: "UNRELATED_WORK_INSTRUCTION")
        model.agentRuns = [report]
        var context = model.currentContext; context.runID = report.id
        await model.askPartner("查一下当前邮箱账户", runID: report.id, uiContext: context)
        XCTAssertEqual(SDKChatHTTPFixture.count, AgentAnswerBudget.modelTurns)
        XCTAssertEqual(model.visibleChat.last?.sdkResumeKind, "continuation")
        let messages = SDKChatHTTPFixture.lastBody?["messages"] as? [[String: Any]] ?? []
        XCTAssertFalse(messages.compactMap { $0["content"] as? String }.joined().contains("UNRELATED_WORK_INSTRUCTION"))
    }
    @MainActor func testSidebarWorkHintDoesNotAttachAnotherAcceptedAgreement() async throws {
        let (model, _, _) = try await fixture(mode: "stage-budget")
        defer { try? FileManager.default.removeItem(at: model.store.root) }
        var work = AgentRun(title: "Another work", instruction: "UNRELATED_WORK_INSTRUCTION")
        work.agreement = WorkAgreement(goal: "Another goal", doneWhen: "Done", scope: "Other scope", boundaries: [], steps: [])
        model.agentRuns = [work]
        var context = model.currentContext; context.runID = work.id
        await model.submitSidebarChat(ChatSubmission(sessionID: model.activeSessionID, instruction: "查一下当前邮箱账户", materials: [], context: context, newWork: false))
        XCTAssertEqual(SDKChatHTTPFixture.count, AgentAnswerBudget.modelTurns)
        let messages = SDKChatHTTPFixture.lastBody?["messages"] as? [[String: Any]] ?? []
        XCTAssertFalse(messages.compactMap { $0["content"] as? String }.joined().contains("UNRELATED_WORK_INSTRUCTION"))
    }
    @MainActor func testExplicitAcceptedWorkRetainsOngoingExecutionBudget() async throws {
        let (model, _, _) = try await fixture(mode: "stage-budget")
        defer { try? FileManager.default.removeItem(at: model.store.root) }
        var work = AgentRun(title: "Accepted work", instruction: "Continue accepted work")
        work.agreement = WorkAgreement(goal: "Accepted goal", doneWhen: "Done", scope: "Accepted scope", boundaries: [], steps: [])
        model.agentRuns = [work]
        await model.askPartner("继续已接受的工作", runID: work.id)
        XCTAssertEqual(SDKChatHTTPFixture.count, 25)
        XCTAssertEqual(model.visibleChat.last?.text, "SDK stage answer")
        XCTAssertNil(model.visibleChat.last?.sdkResumeKind)
    }
    @MainActor func testBudgetShorteningDoesNotForgetRecentDialogueAfterToolCalls() async throws {
        let (model, _, _) = try await fixture(mode: "history-after-tools")
        defer { try? FileManager.default.removeItem(at: model.store.root) }
        model.openWorkspace(.responders)
        let text = String(repeating: "历史内容仅供上下文压力测试。", count: 400)
        for (role, value) in [("user", text + " GOAL_KEEP：准备未启用的响应器。"),
                              ("partner", text + " 需要来源信息。"),
                              ("user", "USER_SENDER_KEEP scope-sender@example.invalid " + text),
                              ("partner", text + " 请继续。") ] {
            var item = PartnerChat(role: role, text: value); item.context = model.currentContext
            try await model.recordChat(item)
        }
        await model.askPartner("继续刚才的配置", uiContext: model.currentContext)
        XCTAssertEqual(model.visibleChat.last?.text, "Conversation facts retained")
        XCTAssertEqual(SDKChatHTTPFixture.count, 3)
    }
    @MainActor func testResponderFollowUpAcceptsSenderFromEarlierUserMessageForReviewOnly() async throws {
        let (model, _, _) = try await fixture(mode: "responder")
        defer { try? FileManager.default.removeItem(at: model.store.root) }
        model.openWorkspace(.responders)
        try await model.recordChat(PartnerChat(role: "user", text: "来源地址使用 trusted@example.invalid"))
        try await model.recordChat(PartnerChat(role: "partner", text: "已收到来源信息，请继续。"))
        await model.askPartner("按此前来源创建响应器，先让我审阅策略", uiContext: model.currentContext)
        XCTAssertEqual(model.openUIInteractions.last?.responderDraft?.senderAllowlist, ["trusted@example.invalid"])
        XCTAssertEqual(model.openUIInteractions.last?.responderDraft?.enabled, false)
    }
    @MainActor func testAssistantSuggestedAddressDoesNotGrantResponderSenderScope() async throws {
        let (model, _, _) = try await fixture(mode: "responder")
        defer { try? FileManager.default.removeItem(at: model.store.root) }
        try await model.recordChat(PartnerChat(role: "partner", text: "可试着使用 trusted@example.invalid"))
        await model.askPartner("创建响应器，先审阅策略", uiContext: model.currentContext)
        XCTAssertNil(model.responderEditor)
        XCTAssertTrue(model.responders.isEmpty)
    }
    @MainActor func testConversationFactsSurviveToolDiscoveryAndAnotherModelRound() async throws {
        let (model, _, _) = try await fixture(mode: "history-after-tools")
        defer { try? FileManager.default.removeItem(at: model.store.root) }
        model.openWorkspace(.responders)
        model.mails = (0..<60).map { index in
            var mail = MailMessage(accountID: "a", from: .init(name: "示例联系人\(index / 3)", email: "contact-\(index / 3)@example.invalid"), subject: "示例往来", text: "虚构资料")
            mail.id = "00000000-0000-0000-0000-000000000000:[Gmail]/All Mail:1234567890:\(index)"
            return mail
        }
        model.contactProfiles = ContactProfileBuilder.build(mails: model.mails, accounts: model.accounts, manual: [])
        for (role, text) in [("user", "GOAL_KEEP：创建收到指定字样后准备图片附件回复的响应器。"),
                             ("partner", "需要确认来源地址与绑定邮箱。"),
                             ("user", "USER_SENDER_KEEP：使用 scope-sender@example.invalid 作为来源地址。"),
                             ("partner", "已收到来源信息，请补充后继续。") ] {
            var item = PartnerChat(role: role, text: text); item.context = model.currentContext
            try await model.recordChat(item)
        }
        await model.askPartner("按刚才的要求继续配置，先保留为未启用状态", uiContext: model.currentContext)
        XCTAssertEqual(model.visibleChat.last?.text, "Conversation facts retained")
        XCTAssertEqual(SDKChatHTTPFixture.count, 3)
        let body = try XCTUnwrap(SDKChatHTTPFixture.lastBody), messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")
        XCTAssertTrue(content.contains("GOAL_KEEP")); XCTAssertTrue(content.contains("USER_SENDER_KEEP"))
        XCTAssertTrue(content.contains("scope-sender@example.invalid"))
        XCTAssertTrue(model.responders.isEmpty, "The model fixture only reads; it must not create a real responder")
    }
    @MainActor func testPinnedScopeKeepsItsDialogueAndExcludesDifferentScopeHistory() async throws {
        let (model, _, _) = try await fixture(mode: "directory-only")
        defer { try? FileManager.default.removeItem(at: model.store.root) }
        model.pinCurrentChatScope(); let scope = model.resolvedChatContext
        var other = scope; other.mailIDs = ["target"]
        var excluded = PartnerChat(role: "user", text: "DIFFERENT_SCOPE_PRIVATE_CONTENT"); excluded.context = other
        try await model.recordChat(excluded)
        var fact = PartnerChat(role: "user", text: "SCOPED_DIALOGUE_FACT_KEEP：上一轮确认的项目名称是橡树。"); fact.context = scope
        try await model.recordChat(fact)
        var reply = PartnerChat(role: "partner", text: "已收到，请继续。"); reply.context = scope
        try await model.recordChat(reply)
        await model.askPartner("上次项目名称是什么？", uiContext: scope)
        let body = try XCTUnwrap(SDKChatHTTPFixture.lastBody), messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let content = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")
        XCTAssertTrue(content.contains("SCOPED_DIALOGUE_FACT_KEEP"))
        XCTAssertFalse(content.contains("DIFFERENT_SCOPE_PRIVATE_CONTENT"))
    }
    @MainActor func testSDKCanReadVerifiedMovedMailByItsOriginalID() async throws {
        let (model, selected, original) = try await fixture(mode: "read-moved"); defer { try? FileManager.default.removeItem(at: model.store.root) }
        var target = original; target.uid = 77; target.uidValidity = 42; target.messageID = "<target@example.invalid>"; target.folder = "INBOX"
        model.accounts[1].isDemo = false
        try await model.store.upsert(target); model.mails = [selected, target]
        model.performServerMailMove = { _, _, _ in MailMoveReceipt.parse("[COPYUID 42 77 88]") }
        await model.move(target, folder: MailFolder(accountID: target.accountID, path: "Archive", role: "archive"))
        let current = try XCTUnwrap(model.mailByID(target.id))
        XCTAssertNotEqual(current.id, target.id)
        await model.askPartner("只读核验刚归档的邮件，使用已有来源ID", uiContext: model.currentContext)
        XCTAssertEqual(model.visibleChat.last?.text, "SDK moved evidence")
        XCTAssertTrue(model.visibleChat.last?.messageIDs.contains(current.id) == true)
    }
    @MainActor func testSimplifiedContactDirectoryIsAvailableInTheFirstModelRequest() async throws {
        let (model, _, target) = try await fixture(mode: "directory-only"); defer { try? FileManager.default.removeItem(at: model.store.root) }
        model.contactProfiles = ContactProfileBuilder.build(mails: model.mails, accounts: model.accounts, manual: [])
        await model.askPartner("我的联系人有哪些", uiContext: model.currentContext)
        let body = try XCTUnwrap(SDKChatHTTPFixture.lastBody), messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let prompt = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")
        XCTAssertTrue(prompt.contains("<contact-directory-data>")); XCTAssertTrue(prompt.contains(target.from.email))
        XCTAssertEqual(model.visibleChat.last?.executionTrace?.tools.count, 0); XCTAssertEqual(SDKChatHTTPFixture.count, 1)
    }
    @MainActor func testSDKBatchReadsMultipleMailsWithoutPerMailModelRounds() async throws {
        let (model, selected, target) = try await fixture(mode: "batch-read"); defer { try? FileManager.default.removeItem(at: model.store.root) }
        await model.askPartner("只读核验这两封邮件", uiContext: model.currentContext)
        XCTAssertEqual(model.visibleChat.last?.text, "SDK batch evidence"); XCTAssertEqual(SDKChatHTTPFixture.count, 2)
        XCTAssertTrue(model.visibleChat.last?.messageIDs.contains(target.id) == true)
        let stored = try await model.store.messages(ids: [selected.id, target.id]); XCTAssertTrue(stored.allSatisfy { !$0.isRead })
        XCTAssertEqual(model.visibleChat.last?.executionTrace?.tools.filter { $0.tool == "read_mails" }.count, 1)
    }
    @MainActor func testSDKCodingCanQueryMailItHasNotReadThroughTools() async throws {
        let (model, _, target) = try await fixture(mode: "coding"); defer { try? FileManager.default.removeItem(at: model.store.root) }
        await model.askPartner("用代码整体分析邮件数据，只读", uiContext: model.currentContext)
        XCTAssertEqual(model.visibleChat.last?.text, "SDK coding evidence")
        XCTAssertEqual(model.visibleChat.last?.executionTrace?.tools.map(\.tool), ["run_code"])
        XCTAssertTrue(model.visibleChat.last?.messageIDs.contains(target.id) == true)
        let body = try XCTUnwrap(SDKChatHTTPFixture.lastBody), messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let output = try XCTUnwrap(messages.last(where: { $0["role"] as? String == "tool" })?["content"] as? String)
        XCTAssertTrue(output.contains("SDK_TARGET_SOURCE"))
    }
    @MainActor func testSDKCodingMaintainsExplicitMailScope() async throws {
        let (model, _, _) = try await fixture(mode: "coding-scope"); defer { try? FileManager.default.removeItem(at: model.store.root) }
        model.pinCurrentChatScope()
        await model.askPartner("用代码只读分析当前明确限定邮件", uiContext: model.resolvedChatContext)
        XCTAssertEqual(model.visibleChat.last?.text, "SDK coding scoped")
        XCTAssertFalse(model.visibleChat.last?.messageIDs.contains("target") == true)
        let body = try XCTUnwrap(SDKChatHTTPFixture.lastBody), messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let output = try XCTUnwrap(messages.last(where: { $0["role"] as? String == "tool" })?["content"] as? String)
        XCTAssertTrue(output.contains("SCOPED_CODE_VERIFIED"))
    }
    @MainActor func testRepeatedQueryMistakeStillPausesForUserDecision() async throws {
        let (model, _, _) = try await fixture(mode: "scan-repeat"); defer { try? FileManager.default.removeItem(at: model.store.root) }
        await model.askPartner("只读查找游戏变现邮件", uiContext: model.currentContext)
        XCTAssertTrue(model.visibleChat.last?.text.contains("两次未能修正") == true)
        XCTAssertNotNil(model.visibleChat.last?.continuationPrompt)
    }
    @MainActor func testMetadataQueryMistakeCanBeCorrectedWithoutPausingOrChangingMail() async throws {
        let (model, _, target) = try await fixture(mode: "scan-correction"); defer { try? FileManager.default.removeItem(at: model.store.root) }
        await model.askPartner("只读查找游戏变现邮件", uiContext: model.currentContext)
        let reply = try XCTUnwrap(model.visibleChat.last)
        XCTAssertEqual(reply.text, "SDK corrected query"); XCTAssertNil(reply.continuationPrompt)
        XCTAssertTrue(reply.executionTrace?.tools.contains { $0.tool == "scan_mail" && $0.status == "failed" } == true)
        XCTAssertTrue(reply.executionTrace?.tools.contains { $0.tool == "search_mail" && $0.status == "completed" } == true)
        let stored = try await model.store.message(target.id); XCTAssertEqual(stored?.isRead, target.isRead)
    }
    @MainActor func testSDKBriefIsStructuredLinkedToChatAndPreservedAfterEditing() async throws {
        let (model, _, target) = try await fixture(mode: "report"); defer { try? FileManager.default.removeItem(at: model.store.root) }
        let origin = model.activeSessionID
        await model.askPartner("只读查找所有相关邮件，并保存结构化简报", uiContext: model.currentContext)
        let reply = try XCTUnwrap(model.visibleChat.last), id = try XCTUnwrap(reply.artifactIDs?.first)
        let artifact = try XCTUnwrap(model.agentArtifacts.first { $0.id == id })
        XCTAssertEqual(artifact.sessionID, origin); XCTAssertEqual(artifact.sourceChatID, model.visibleChat.first?.id)
        XCTAssertEqual(artifact.briefDocument?.status, .inProgress); XCTAssertTrue(artifact.sourceMailIDs.contains(target.id))
        let table = try XCTUnwrap(artifact.briefDocument?.tables.first)
        XCTAssertNoThrow(try OpenUILang.parse(table.openUISource).root())
        XCTAssertEqual(model.agentRuns.first { $0.id == artifact.runID }?.phase, .paused)
        XCTAssertEqual(model.agentRuns.first { $0.id == artifact.runID }?.sessionID, origin)
        XCTAssertTrue(artifact.runID.hasPrefix("sdk-chat:sdk-run:"))
        let other = await model.createChatSession(title: "Other"); model.chatInput = "Unsent other input"
        model.openBrief(artifact); XCTAssertEqual(model.activeSessionID, origin); XCTAssertEqual(model.workspacePage, .briefs)
        await model.openBriefSource(artifact); XCTAssertEqual(model.scrollChatID, artifact.sourceChatID)
        model.switchChatSession(other); XCTAssertEqual(model.chatInput, "Unsent other input")
        await model.saveReportEdit("User edited body", artifactID: id)
        let edited = try XCTUnwrap(model.agentArtifacts.first { $0.id == id })
        XCTAssertNil(edited.briefDocument); XCTAssertEqual(edited.sessionID, origin); XCTAssertEqual(edited.revisions?.last?.briefDocument?.status, .inProgress)
        var legacy = artifact; legacy.sessionID = nil; legacy.sourceChatID = nil; legacy.runID = "sdk-chat:" + other
        model.chat = model.chat.map { item in var copy = item; copy.artifactIDs = nil; return copy }; model.agentArtifacts = [legacy]
        XCTAssertEqual(model.briefs(in: origin).first?.id, legacy.id)
        var unlinked = legacy; unlinked.id = "unlinked-artifact"; unlinked.runID = "sdk-chat:sdk-run:unconfirmed"
        XCTAssertNil(model.briefSessionID(unlinked), "A runtime identifier must not be treated as a UI session")
        var oldStyle = unlinked; oldStyle.runID = "sdk-chat:" + origin
        XCTAssertEqual(model.briefSessionID(oldStyle), origin, "Known legacy UI session IDs remain supported")
    }
    @MainActor private func fixture(mode: String) async throws -> (AppModel, MailMessage, MailMessage) {
        let runtime = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Runtime/AgentRuntime")
        guard FileManager.default.fileExists(atPath: runtime.appendingPathComponent("node_modules/@openai/agents/package.json").path) else { throw XCTSkip("Install pinned SDK dependencies") }
        SDKChatHTTPFixture.reset(mode)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SDKChatHTTPFixture.self]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = AppModel(root: root, agentToolModel: AgentToolModel(configuration: config))
        model.workspacePreferences.memoryEnabled = false; model.settings.provider = "openai"; model.settings.openAIURL = "https://sdk-chat-fixture.invalid/v1"; model.settings.openAIModel = "fixture"
        var ranking = RetrievalDecisionSettings(); ranking.enabled = false; model.settings.retrievalDecision = ranking
        var a = MailAccount(); a.id = "a"; a.email = "a@example.invalid"; a.isDemo = true; var b = a; b.id = "b"; model.accounts = [a, b]
        await model.restoreChatSessions()
        var selected = MailMessage(accountID: "a", from: .init(email: "a@example.invalid"), subject: "Current unrelated message", text: "Selected hint"); selected.id = "selected"
        var target = MailMessage(accountID: "b", from: .init(email: "b@example.invalid"), subject: "game monetization SDK_TARGET_SOURCE", text: "game monetization SDK_TARGET_SOURCE"); target.id = "target"; target.folder = "Archive"
        try await model.store.upsert(selected); try await model.store.upsert(target); model.mails = [selected, target]
        model.workspacePage = .mail; model.selectedID = selected.id
        return (model, selected, target)
    }
    @MainActor func testRealSDKUsesSearchOutsideHintAndKeepsReadFlags() async throws {
        let (model, selected, target) = try await fixture(mode: "search"); defer { try? FileManager.default.removeItem(at: model.store.root) }
        await model.askPartner("查找所有游戏变现邮件，只查询，不修改邮件", uiContext: model.currentContext)
        let reply = try XCTUnwrap(model.visibleChat.last)
        XCTAssertEqual(reply.text, "SDK verified source result"); XCTAssertTrue(reply.messageIDs.contains(target.id))
        XCTAssertEqual(model.selectedID, selected.id); XCTAssertFalse(model.partnerBusy); XCTAssertNil(model.sidebarToolStatus)
        let stored = try await model.store.message(target.id); XCTAssertEqual(stored?.isRead, target.isRead)
        XCTAssertEqual(SDKChatHTTPFixture.count, 2)
    }
    @MainActor func testSDKCanContinueBeyondFourRoundsAndSaveVisibleReplyDraft() async throws {
        let (model, _, target) = try await fixture(mode: "long-draft"); defer { try? FileManager.default.removeItem(at: model.store.root) }
        model.selectedID = target.id
        await model.askPartner("读取这封邮件，写完整回复草稿", uiContext: model.currentContext)
        let reply = try XCTUnwrap(model.visibleChat.last), id = try XCTUnwrap(reply.draftIDs?.first)
        XCTAssertEqual(reply.text, "SDK draft saved")
        XCTAssertGreaterThan(SDKChatHTTPFixture.count, 4)
        let draft = try XCTUnwrap(model.drafts.first(where: { $0.id == id }))
        XCTAssertEqual(draft.to, "b@example.invalid"); XCTAssertEqual(draft.body, "Thank you.\n\nPlease share the schedule.")
        XCTAssertEqual(model.composer?.id, id); XCTAssertEqual(draft.state, "draft")
    }
    @MainActor func testSDKExplicitScopeStillRejectsOutsideMail() async throws {
        let (model, _, _) = try await fixture(mode: "restricted"); defer { try? FileManager.default.removeItem(at: model.store.root) }
        model.pinCurrentChatScope()
        await model.askPartner("只读分析当前明确限定的邮件", uiContext: model.resolvedChatContext)
        XCTAssertTrue(model.visibleChat.last?.text.contains("需要你决定下一步") == true)
        XCTAssertNotNil(model.visibleChat.last?.continuationPrompt)
        XCTAssertFalse(model.sidebarEvidenceMailIDs.contains("target")); XCTAssertTrue(model.drafts.isEmpty)
    }
    @MainActor func testSDKFormPausesThenResumesSameCheckpointWithoutDuplicatingUI() async throws {
        let (model, _, _) = try await fixture(mode: "form"); defer { try? FileManager.default.removeItem(at: model.store.root) }
        await model.askPartner("请先让我选择范围再继续", uiContext: model.currentContext)
        let first = try XCTUnwrap(model.visibleChat.last), uiID = try XCTUnwrap(first.openUIID)
        XCTAssertTrue(first.text.contains("选择")); XCTAssertFalse(model.partnerBusy)
        let sdkRunID = try XCTUnwrap(first.sdkRunID)
        await ChatTaskContext.$runIntent.withValue(.answer(sdkRunID: sdkRunID, sourceChatID: first.id, interactionID: uiID)) { await model.askPartner("选择 A，继续", uiContext: model.currentContext) }
        XCTAssertEqual(model.visibleChat.last?.text, "SDK choice resumed")
        XCTAssertEqual(model.openUIInteractions.filter { $0.id == uiID }.count, 1)
        let pending = try await model.store.object(OpenUIJSON.self, kind: "agent-sdk-waiting", id: sdkRunID)
        XCTAssertNil(pending)
    }
    @MainActor func testNewRequestDoesNotResumeAnotherTaskInTheSameConversation() async throws {
        let (model, _, _) = try await fixture(mode: "form"); defer { try? FileManager.default.removeItem(at: model.store.root) }
        await model.askPartner("第一项任务：先选择范围", uiContext: model.currentContext)
        let question = try XCTUnwrap(model.visibleChat.last), runA = try XCTUnwrap(question.sdkRunID)
        SDKChatHTTPFixture.reset("search")
        await model.askPartner("第二项任务：查找游戏变现邮件，只查询", uiContext: model.currentContext)
        let response = try XCTUnwrap(model.visibleChat.last), runB = try XCTUnwrap(response.sdkRunID)
        XCTAssertNotEqual(runA, runB); XCTAssertEqual(response.text, "SDK verified source result")
        let waitingA = try await model.store.object(OpenUIJSON.self, kind: "agent-sdk-waiting", id: runA)
        XCTAssertEqual(waitingA?.object["sourceChatID"]?.text, question.id)
        XCTAssertNil(model.openUIInteractions.first?.completedAt)
    }
    @MainActor func testMismatchedResumeIdentityNeverCallsTheModel() async throws {
        let (model, _, _) = try await fixture(mode: "form"); defer { try? FileManager.default.removeItem(at: model.store.root) }
        await model.askPartner("第一项任务：先选择范围", uiContext: model.currentContext)
        let question = try XCTUnwrap(model.visibleChat.last), run = try XCTUnwrap(question.sdkRunID)
        SDKChatHTTPFixture.reset("search")
        await ChatTaskContext.$runIntent.withValue(.resume(sdkRunID: run, sourceChatID: "another-message")) { await model.askPartner("继续", uiContext: model.currentContext) }
        XCTAssertEqual(SDKChatHTTPFixture.count, 0)
        XCTAssertTrue(model.visibleChat.last?.text.contains("不能恢复") == true)
    }
    @MainActor func testAnswerRetainsOriginalScopeAfterTheUserNavigatesElsewhere() async throws {
        let (model, selected, target) = try await fixture(mode: "form"); defer { try? FileManager.default.removeItem(at: model.store.root) }
        model.pinCurrentChatScope()
        await model.askPartner("在明确限定的这封邮件中先让我选择", uiContext: model.resolvedChatContext)
        let question = try XCTUnwrap(model.visibleChat.last), run = try XCTUnwrap(question.sdkRunID), ui = try XCTUnwrap(question.openUIID)
        model.selectedID = target.id; model.chatInput = "下一项还未提交的要求"
        try await model.answerAgentInteraction(interactionID: ui, response: "选择 A，继续")
        XCTAssertEqual(model.chatInput, "下一项还未提交的要求")
        await model.sidebarTask?.value
        XCTAssertEqual(model.visibleChat.last?.text, "SDK choice resumed")
        XCTAssertEqual(model.visibleChat.last?.context?.mailIDs, [selected.id])
        XCTAssertFalse(model.visibleChat.last?.messageIDs.contains(target.id) == true)
        XCTAssertNotNil(model.openUIInteractions.first(where: { $0.id == ui })?.completedAt)
    }
    @MainActor func testCompletedQuestionCannotBeSubmittedAgain() async throws {
        let (model, _, _) = try await fixture(mode: "form"); defer { try? FileManager.default.removeItem(at: model.store.root) }
        await model.askPartner("先选择范围", uiContext: model.currentContext)
        let question = try XCTUnwrap(model.visibleChat.last), run = try XCTUnwrap(question.sdkRunID), ui = try XCTUnwrap(question.openUIID)
        await ChatTaskContext.$runIntent.withValue(.answer(sdkRunID: run, sourceChatID: question.id, interactionID: ui)) { await model.askPartner("选择 A，继续", uiContext: model.currentContext) }
        SDKChatHTTPFixture.reset("search")
        await ChatTaskContext.$runIntent.withValue(.answer(sdkRunID: run, sourceChatID: question.id, interactionID: ui)) { await model.askPartner("再提交", uiContext: model.currentContext) }
        XCTAssertEqual(SDKChatHTTPFixture.count, 0)
    }
    @MainActor func testSDKResponderSetupUsesExplicitSenderAndStaysDisabled() async throws {
        let (model, _, _) = try await fixture(mode: "responder"); defer { try? FileManager.default.removeItem(at: model.store.root) }
        await model.askPartner("为trusted@example.invalid创建响应器，先让我审阅策略", uiContext: model.currentContext)
        XCTAssertEqual(model.visibleChat.last?.text, "SDK responder prepared")
        XCTAssertEqual(model.openUIInteractions.last?.responderDraft?.senderAllowlist, ["trusted@example.invalid"])
        XCTAssertEqual(model.openUIInteractions.last?.responderDraft?.enabled, false)
        XCTAssertEqual(model.workspacePage, .mail)
    }
    @MainActor func testSDKSmallRequestedPageDoesNotCauseTinyRepeatedReads() async throws {
        let (model, selected, original) = try await fixture(mode: "page-size"); defer { try? FileManager.default.removeItem(at: model.store.root) }
        var target = original; target.text = String(repeating: "Synthetic paragraph. ", count: 1000)
        try await model.store.upsert(target); model.mails = [selected, target]
        await model.askPartner("只读这封邮件的相关事实，不需要通读全文", uiContext: model.currentContext)
        let last = try XCTUnwrap(SDKChatHTTPFixture.lastBody)
        let messages = try XCTUnwrap(last["messages"] as? [[String: Any]])
        let output = try XCTUnwrap(messages.last(where: { $0["role"] as? String == "tool" })?["content"] as? String)
        let page = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        XCTAssertEqual((page["text"] as? String)?.count, 4000)
        XCTAssertEqual(page["nextOffset"] as? Int, 4000)
        XCTAssertEqual(SDKChatHTTPFixture.count, 2)
    }
    @MainActor func testSDKPlanAndActualToolsArePersistedSeparately() async throws {
        let (model, _, _) = try await fixture(mode: "plan"); defer { try? FileManager.default.removeItem(at: model.store.root) }
        await model.askPartner("制定计划，只读检索并整理结果", uiContext: model.currentContext)
        let trace = try XCTUnwrap(model.visibleChat.last?.executionTrace)
        XCTAssertEqual(trace.plan.first?.title, "查找相关邮件")
        XCTAssertEqual(trace.plan.first?.status, "completed")
        XCTAssertTrue(trace.tools.contains(where: { $0.tool == "search_mail" && $0.status == "completed" }))
        XCTAssertTrue(trace.models.allSatisfy { $0.seconds != nil })
    }
    @MainActor func testQuickModelSwitchPreservesBothEndpointsAndModels() async throws {
        let (model, _, _) = try await fixture(mode: "search"); defer { try? FileManager.default.removeItem(at: model.store.root) }
        model.settings.openAIModel = "gpt-6.1-terra"; model.settings.model = "qwen3.8:27b-mlx"
        try await model.selectModelPreset(local: true)
        XCTAssertEqual(model.settings.provider, "ollama")
        XCTAssertEqual(model.settings.openAIModel, "gpt-6.1-terra")
        try await model.selectModelPreset(local: false)
        XCTAssertEqual(model.settings.provider, "openai")
        XCTAssertEqual(model.settings.model, "qwen3.8:27b-mlx")
        XCTAssertEqual(model.settings.openAIURL, "https://sdk-chat-fixture.invalid/v1")
    }
}

private final class SDKChatHTTPFixture: URLProtocol {
    private static let lock = NSLock()
    private static var calls = 0
    private static var mode = "search"
    private static var body: [String: Any]?
    static var count: Int { lock.withLock { calls } }
    static var lastBody: [String: Any]? { lock.withLock { body } }
    static func reset(_ value: String) { lock.withLock { calls = 0; mode = value; body = nil } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "sdk-chat-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var block = [UInt8](repeating: 0, count: 4096)
            while true { let n = stream.read(&block, maxLength: block.count); if n <= 0 { break }; bytes.append(contentsOf: block.prefix(n)) }
        }
        if let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] { Self.lock.withLock { Self.body = value } }
        let (call, mode) = Self.lock.withLock { Self.calls += 1; return (Self.calls, Self.mode) }
        let operation: (String, [String: Any])?
        let answer: String
        if mode == "history-after-tools" {
            operation = call == 1 ? ("find_tools", ["query": "响应器"]) : call == 2 ? ("list_accounts", [:]) : nil
            let messages = Self.lastBody?["messages"] as? [[String: Any]] ?? []
            let content = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")
            answer = content.contains("GOAL_KEEP") && content.contains("USER_SENDER_KEEP") ? "Conversation facts retained" : "Conversation facts missing"
        }
        else if mode == "read-moved" { operation = call == 1 ? ("read_mail", ["messageID": "target"]) : nil; answer = "SDK moved evidence" }
        else if mode == "directory-only" { operation = nil; answer = "SDK direct contacts" }
        else if mode == "batch-read" { operation = call == 1 ? ("read_mails", ["messageIDs": ["selected", "target"]]) : nil; answer = "SDK batch evidence" }
        else if mode == "coding" {
            operation = call == 1 ? ("run_code", ["python": "import maildata,json\nprint(json.dumps(maildata.query(\"SELECT id,text FROM mail WHERE id='target'\")['rows']))"]) : nil
            answer = "SDK coding evidence"
        } else if mode == "coding-scope" {
            operation = call == 1 ? ("run_code", ["python": "import maildata\nassert maildata.query('SELECT count(*) AS n FROM mail_index')['rows'][0]['n']==1\nassert maildata.query(\"SELECT id FROM mail WHERE id='target'\")['rows']==[]\nprint('SCOPED_CODE_VERIFIED')"]) : nil
            answer = "SDK coding scoped"
        } else if mode == "scan-repeat" {
            operation = ("scan_mail", ["query": "game monetization"])
            answer = "Never complete invalid query"
        } else if mode == "scan-correction" {
            operation = call == 1 ? ("scan_mail", ["query": "after:2026-01-01 game monetization"]) : call == 2 ? ("search_mail", ["query": "after:2026-01-01 game monetization"]) : nil
            answer = "SDK corrected query"
        } else if mode == "report" {
            operation = call == 1 ? ("find_tools", ["query": "report"]) : call == 2 ? ("search_mail", ["query": "game monetization"]) : call == 3 ? ("save_report", ["title": "Synthetic brief", "document": ["summary": "Relevant mail found", "status": "in_progress", "coverage": "One bounded search", "findings": ["SDK_TARGET_SOURCE"], "actions": ["Continue checking"], "uncertainties": ["Incomplete coverage"], "tables": [["title": "Sources", "columns": ["Subject", "State"], "rows": [["Synthetic mail", "Read"]]]]]]) : nil
            answer = "SDK brief saved"
        } else if mode == "plan" {
            operation = call == 1 ? ("write_plan", ["steps": [["id": "search", "title": "查找相关邮件", "status": "in_progress"]]]) : call == 2 ? ("search_mail", ["query": "game monetization"]) : call == 3 ? ("write_plan", ["steps": [["id": "search", "title": "查找相关邮件", "status": "completed"]]]) : nil
            answer = "SDK plan completed"
        } else if mode == "page-size" {
            operation = call == 1 ? ("read_mail", ["messageID": "target", "limit": 256]) : nil
            answer = "SDK efficient page"
        } else if mode == "stage-budget" {
            let tools = Self.lastBody?["tools"] as? [[String: Any]] ?? []
            operation = !tools.isEmpty && call <= 24 ? ("list_accounts", [:]) : nil
            answer = "SDK stage answer"
        } else if mode == "responder" || mode == "responder-repeat" {
            operation = call == 1 ? ("find_tools", ["query": "responder"]) : call == 2 ? ("setup_responder", ["instruction": "只响应trusted@example.invalid", "title": "Synthetic rule", "accountID": "a", "senderAllowlist": ["trusted@example.invalid"]]) : nil
            answer = "SDK responder prepared"
        } else if mode == "form" {
            operation = call == 1 ? ("render_ui", ["source": "root = Form(\"choice\", [TextArea(\"response\", \"你的选择\", \"\"), Button(\"继续\", @ToAssistant(\"选择 A\"))])"]) : nil
            answer = "SDK choice resumed"
        } else if mode == "long-draft" {
            operation = call <= 5 ? ("read_mail", ["messageID": "target"]) : call == 6 ? ("prepare_draft", ["messageID": "target", "text": "Thank you.\n\nPlease share the schedule."]) : nil
            answer = "SDK draft saved"
        } else if mode == "restricted" { operation = call == 1 ? ("read_mail", ["messageID": "target"]) : nil; answer = "SDK outside source refused" }
        else { operation = call == 1 ? ("search_mail", ["query": "game monetization"]) : nil; answer = "SDK verified source result" }
        let repeatedSetup: (String, [String: Any])? = mode == "responder-repeat" && (3...5).contains(call) ? ("setup_responder", ["instruction": "只响应trusted@example.invalid", "accountID": "a", "senderAllowlist": ["trusted@example.invalid"]]) : operation
        var delta: [String: Any] = ["content": repeatedSetup == nil ? answer : ""]
        if let operation = repeatedSetup {
            let arguments = String(decoding: try! JSONSerialization.data(withJSONObject: operation.1), as: UTF8.self)
            delta["tool_calls"] = [["index": 0, "id": "fixture-call-\(call)", "type": "function", "function": ["name": operation.0, "arguments": arguments]]]
        }
        let record = try! JSONSerialization.data(withJSONObject: ["choices": [["delta": delta, "finish_reason": operation == nil ? "stop" : "tool_calls"]]])
        let data = Data(("data: " + String(decoding: record, as: UTF8.self) + "\n\ndata: [DONE]\n\n").utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
