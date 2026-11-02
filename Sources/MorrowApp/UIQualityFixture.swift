import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MorrowCore

/// Explicit, local-only UI material. Never used by the regular workspace.
@MainActor enum UIQualityFixture {
    static func install(in model: AppModel) async throws {
        guard model.isQualityPreview else { return }
        var account = MailAccount(); account.id = "quality-account"; account.name = "示例工作邮箱"; account.email = "you@example.com"; account.imapHost = "imap.example.com"; account.smtpHost = "smtp.example.com"
        model.accounts = [account]
        model.folders = [MailFolder(accountID: account.id, path: "INBOX", role: "inbox"), MailFolder(accountID: account.id, path: "Sent", role: "sent"), MailFolder(accountID: account.id, path: "Drafts", role: "drafts"), MailFolder(accountID: account.id, path: "Trash", role: "trash")]
        for folder in model.folders { try await model.store.save(folder, kind: "folder", id: folder.id) }
        try await model.store.save(account, kind: "account", id: account.id)
        var savedSettings = model.settings; savedSettings.enabled = false; savedSettings.autoAnalyze = false
        try await model.store.save(savedSettings, kind: "settings", id: "main")
        model.settings = savedSettings
        let subjects = ["[示例] 项目评审材料与日程确认", "[示例] 合同修订：交付范围与验收期限", "[示例] 设计文件已更新，请核对附件", "[示例] 下周会议安排", "[示例] 对账单与发票", "[示例] 本月产品更新"]
        for (index, subject) in subjects.enumerated() {
            var sender = account; sender.email = ["sara@example.com", "legal@example.com", "design@example.com", "team@example.com", "finance@example.com", "news@example.com"][index]
            sender.name = ["宋晓", "法务团队", "设计团队", "项目组", "财务", "产品周刊"][index]
            var draft = ComposeDraft(); draft.id = "quality-source-\(index)"; draft.accountID = account.id; draft.to = account.email; draft.subject = subject
            draft.body = "你好，\n\n这是 Morrow 界面验收的示例邮件。请先核对所附材料，再确认需要补充的内容。\n\n本次重点是信息层级、原件阅读和清楚的下一步。所有姓名、地址和内容均为演示资料。\n\n谢谢。"
            if index == 0 {
                draft.htmlBody = "<p>你好，</p><p>评审材料已整理，请核对附件中的方案与日程。</p><h3>待确认</h3><ul><li>交付范围与验收期限</li><li>参会人员与补充材料</li></ul><p>这是界面验收的示例内容。</p>"
                draft.attachments = [.init(name: "方案预览.png", mimeType: "image/png", data: try image()), .init(name: "评审资料.pdf", mimeType: "application/pdf", data: try pdf())]
            }
            let date = Date().addingTimeInterval(Double(-index) * 3600)
            let raw = try MIMEWriter.encode(draft, account: sender, date: date)
            var mail = MIMEParser.parse(raw, accountID: account.id, folder: "INBOX"); mail.id = draft.id; mail.isRead = index > 1
            mail.analysis = MailAnalysis(summary: "示例邮件摘要：材料已到达，需要核对内容。", category: index == 4 ? .finance : .work, needsReply: index < 3, action: index == 0 ? "核对评审材料，备好回复。" : nil, source: "示例")
            _ = try await model.store.upsert(mail)
        }
        var draft = ComposeDraft(); draft.id = "quality-draft"; draft.accountID = account.id; draft.to = "sara@example.com"; draft.subject = "[示例] Re: 项目评审材料与日程确认"; draft.body = "收到材料。\n\n我会先核对交付范围与验收期限，再补充需要确认的问题。请提供最终议程。\n\n谢谢。"
        try await model.store.save(draft, kind: "draft", id: draft.id)
        var queued = draft; queued.id = "quality-queued"; queued.state = "queued"; queued.subject = "[示例] 等待投递的回复"; queued.scheduledAt = Date().addingTimeInterval(3600)
        try await model.store.save(queued, kind: "draft", id: queued.id)
        var uncertain = draft; uncertain.id = "quality-uncertain"; uncertain.state = "uncertain"; uncertain.subject = "[示例] 需要核对发送结果"; uncertain.error = "发送结果尚未确认，请核对已发送。"
        try await model.store.save(uncertain, kind: "draft", id: uncertain.id)
        var delivered = draft; delivered.id = "quality-sent"; delivered.state = "sent"; delivered.subject = "[示例] 已发送的项目回复"
        try await model.store.save(delivered, kind: "draft", id: delivered.id)
        var sent = MIMEParser.parse(try MIMEWriter.encode(delivered, account: account), accountID: account.id, folder: "Sent")
        sent.id = "sent:" + delivered.id; sent.isRead = true; _ = try await model.store.upsert(sent)
        model.drafts = [draft, queued, uncertain, delivered]
        var run = AgentRun(title: "核对项目材料并准备回复", instruction: "核对材料，保留来源，备好可审阅的回复。", phase: .waitingUser, summary: "回复草稿已准备，等待审阅。", sourceMailIDs: ["quality-source-0"], isDemo: true)
        run.agreement = WorkAgreement(goal: "核对材料并准备回复", doneWhen: "来源可核对，草稿可审阅", scope: "这次项目评审的示例邮件", boundaries: ["不发送邮件", "保留原始来源"], steps: ["核对材料", "整理待确认问题", "准备回复草稿"], kind: "reply")
        let report = AgentRun(title: "整理合同中的变化", instruction: "整理变化与待核实事项。", phase: .completed, summary: "比较结果已保存。", sourceMailIDs: ["quality-source-1"], isDemo: true)
        model.agentRuns = [run, report]
        for item in model.agentRuns { try await model.store.save(item, kind: "agent-run", id: item.id) }
        var draftArtifact = AgentArtifact(runID: run.id, title: draft.subject, kind: .draft, content: draft.body, sourceMailIDs: ["quality-source-0"], linkedDraftID: draft.id)
        draftArtifact.sessionID = "quality-session"
        var brief = AgentArtifact(runID: report.id, title: "[示例] 合同条款核对", kind: .brief, content: "## 核对结果\n\n交付范围已明确，验收期限仍需确认。\n\n| 项目 | 现状 | 下一步 |\n| --- | --- | --- |\n| 交付范围 | 已核对 | 保留材料 |\n| 验收期限 | 待确认 | 询问对方 |\n\n## 来源\n\n这是用于界面验收的示例简报。", sourceMailIDs: ["quality-source-1"])
        brief.sessionID = "quality-session"
        model.agentArtifacts = [draftArtifact, brief]
        for item in model.agentArtifacts { try await model.store.save(item, kind: "agent-artifact", id: item.id) }
        model.agentDecisions = [AgentDecision(runID: run.id, title: "审阅回复草稿", detail: "核对收件人和正文后再发送。", artifactID: draftArtifact.id)]
        var session = ChatSession(id: "quality-session", title: "项目材料与回复"); session.input = ""
        model.chatSessions = [session]; try await model.store.save(session, kind: "chat-session", id: session.id)
        model.activeSessionID = session.id
        var human = PartnerChat(role: "user", text: "核对这封邮件的材料，备好回复并引用实际来源。"); human.sessionID = session.id
        var reply = PartnerChat(role: "partner", text: "材料已经核对，回复草稿已保存。验收期限仍需对方确认，建议在邮件中明确询问。"); reply.sessionID = session.id; reply.draftIDs = [draft.id]; reply.artifactIDs = [brief.id]; reply.messageIDs = ["quality-source-0", "quality-source-1"]
        model.chat = [human, reply]
        for item in model.chat { try await model.store.save(item, kind: "chat", id: item.id) }
        var memory = AgentMemory(content: "示例偏好：回复简洁，保留明确的下一步。", kind: .preference); memory.confirmed = true
        var rule = MailResponder(); rule.id = "quality-rule"; rule.title = "[示例] 项目来信整理"; rule.accountID = account.id; rule.folderPath = "INBOX"; rule.senderAllowlist = ["sara@example.com"]; rule.trustedAuthService = "mx.example.com"; rule.response = "整理要点并准备草稿，不发送邮件。"; rule.delivery = "draft"; rule.status = "已保存，等待启用"
        model.responders = [rule]; try await model.store.save(rule, kind: "responder", id: rule.id)
        model.memories = [memory]; try await model.store.save(memory, kind: "agent-memory", id: memory.id)
        await model.reload()
        model.contactProfiles = ContactProfileBuilder.build(mails: model.mails, accounts: model.accounts, manual: [])
        model.isDemo = true
    }
    static func image() throws -> Data {
        guard let context = CGContext(data: nil, width: 960, height: 640, bitsPerComponent: 8, bytesPerRow: 960 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw MailError.message("Preview image unavailable") }
        context.setFillColor(CGColor(gray: 0.97, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 960, height: 640))
        context.setFillColor(CGColor(red: 0.17, green: 0.38, blue: 0.69, alpha: 1)); context.fill(CGRect(x: 80, y: 100, width: 800, height: 80))
        for index in 0..<3 { context.setFillColor(CGColor(gray: 0.7 + CGFloat(index) * 0.05, alpha: 1)); context.fill(CGRect(x: 80, y: 240 + index * 100, width: 650 - index * 80, height: 28)) }
        guard let image = context.makeImage() else { throw MailError.message("Preview image unavailable") }
        let data = NSMutableData(); guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { throw MailError.message("Preview image unavailable") }
        CGImageDestinationAddImage(destination, image, nil); guard CGImageDestinationFinalize(destination) else { throw MailError.message("Preview image unavailable") }; return data as Data
    }
    static func pdf() throws -> Data {
        let data = NSMutableData(); guard let consumer = CGDataConsumer(data: data as CFMutableData) else { throw MailError.message("Preview PDF unavailable") }
        var rect = CGRect(x: 0, y: 0, width: 600, height: 800)
        guard let context = CGContext(consumer: consumer, mediaBox: &rect, nil) else { throw MailError.message("Preview PDF unavailable") }
        context.beginPDFPage(nil); context.setFillColor(CGColor(red: 0.17, green: 0.38, blue: 0.69, alpha: 1)); context.fill(CGRect(x: 50, y: 690, width: 500, height: 50))
        context.setFillColor(CGColor(gray: 0.75, alpha: 1)); for index in 0..<8 { context.fill(CGRect(x: 50, y: 600 - index * 50, width: 430 - index * 10, height: 12)) }
        context.endPDFPage(); context.closePDF(); return data as Data
    }
}
