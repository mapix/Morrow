import Foundation
import MorrowCore

extension AppModel {
    func installAgentDemoScenarios() async {
        guard isDemo, agentRuns.isEmpty, let account = accounts.first(where: \.isDemo) else { return }
        do {
            let samples: [(String, String, String, String, String?)] = [
                ("示例供应商", "supplier@example.com", "账单核对：供应商发票", "示例发票金额为12000元，发票抬头为Example Company。请核对附件明细。这是演示资料，不是付款指令。", "item,amount\n服务费,12000\n"),
                ("示例财务", "finance@example.com", "账单核对：系统对账单", "系统对账金额为11800元，抬头为Example Company。请对比供应商发票并找出差异。这是演示资料。", "item,amount\n服务费,11800\n"),
                ("示例法务", "legal@example.com", "合同对比：旧版条款", "演示合同旧版：交付期限30天；验收期限5个工作日；违约金12000元。", nil),
                ("示例合作方", "partner@example.com", "合同对比：更新条款", "演示合同更新：交付期限45天；验收期限10个工作日；违约金12000元。请整理变化及待核实的问题，不签署、不付款。", nil)
            ]
            for (name, email, subject, text, csv) in samples {
                var mail = MailMessage(accountID: account.id, from: .init(name: name, email: email), subject: subject, text: text); mail.isRead = true; mail.messageID = "<" + mail.id + "@example.com>"; mail.analysis = PartnerEngine.baseline(mail)
                if let csv { mail.attachments = [.init(name: subject.contains("发票") ? "invoice.csv" : "statement.csv", mimeType: "text/csv", data: Data(csv.utf8))] }
                var draft = ComposeDraft(); draft.to = account.email; draft.subject = subject; draft.body = text
                var sender = account; sender.name = name; sender.email = email; mail.raw = try MIMEWriter.encode(draft, account: sender)
                try await store.upsert(mail)
            }
            var sent = MailMessage(accountID: account.id, from: .init(name: "你", email: account.email), subject: "客户报价：等待反馈", text: "已向演示客户发送12000元的报价方案，请对方确认交付安排。此邮件只存在于演示邮箱。")
            sent.to = [.init(name: "示例客户", email: "client@example.com")]; sent.folder = "Sent"; sent.isRead = true; sent.messageID = "<" + sent.id + "@example.com>"; sent.date = Date().addingTimeInterval(-48 * 3600)
            try await store.upsert(sent)
            await reload()
            let definitions: [(String, String, String, String, String, String)] = [
                ("备好项目评审回复", "读取评审邀请，准备确认收悉和询问材料的回复草稿。用户日程未知，不承诺参加。", "项目评审", "reply", "draft", "team@example.com"),
                ("核对两份账单", "核对供应商发票与系统对账单的金额，明确差异及下一步核实事项。引用邮件和CSV中的实际数值，不付款。", "账单核对", "briefing", "notify", ""),
                ("整理合同变化", "比较旧版和更新条款，列出交付期限、验收期限和违约金是否变化。只整理需核实的问题，不代表用户作同意或拒绝决定，不签署，不发送。", "合同对比", "briefing", "notify", ""),
                ("整理订阅阅读", "把周刊邮件整理到阅读资料中。", "本周产品", "organize", "notify", ""),
                ("关注客户报价反馈", "跟进客户报价。如果对方已回复，整理最新进展；没有回复时，说明还在等谁，并建议下一步。", "客户报价", "followUp", "notify", "")
            ]
            for (title, instruction, match, kind, action, recipient) in definitions {
                var delegation = Delegation(); delegation.title = title; delegation.instruction = instruction; delegation.match = match; delegation.kind = kind; delegation.action = action; delegation.recipient = recipient; delegation.includeExisting = true
                if kind == "briefing" { delegation.nextRun = Date() }
                if kind == "followUp" { delegation.nextRun = Date().addingTimeInterval(24 * 3600) }
                await saveDelegation(delegation)
                if kind == "followUp", let run = agentRuns.first(where: { $0.delegationID == delegation.id }) {
                    await addStep(run.id, title: "保留报价往来", tool: "邮件", detail: "演示邮箱中存在已发报价邮件，对方尚未回复。", sourceIDs: [sent.id]); await updateRun(run.id, phase: .waitingReply, summary: "报价已发出，等待示例客户确认。")
                }
            }
            selectedRunID = nil; workspacePage = .desk; process()
        } catch { self.error = error.localizedDescription }
    }
    func simulateIncoming(_ scenario: String) async {
        guard isDemo, let account = accounts.first(where: \.isDemo) else { return }
        let subject: String; let from: MailAddress; let text: String
        switch scenario {
        case "client": subject = "Re: 客户报价：等待反馈"; from = .init(name: "示例客户", email: "client@example.com"); text = "收到报价。演示客户确认金额12000元，请提供具体交付时间安排。此邮件是注入的演示消息。"
        case "invoice": subject = "账单核对：财务补充说明"; from = .init(name: "示例财务", email: "finance@example.com"); text = "差额200元是演示折扣尚未入账。请把这条说明与原发票、系统对账单一起核对，勿据此付款。"
        case "contract": subject = "合同对比：验收条款补充"; from = .init(name: "示例合作方", email: "partner@example.com"); text = "演示补充：交付期限维持45天；验收期限从更新稿的10个工作日改为7个工作日；违约金12000元不变。这是待核实的补充建议，尚未签署，也不代表用户同意。请更新比较和回复草稿。"
        default: subject = "Re: 请确认下周项目评审时间"; from = .init(name: "示例项目组", email: "team@example.com"); text = "评审材料清单已准备：项目方案、交付风险、待确认事项。请先审阅材料，再确认是否参加。这是演示新邮件。"
        }
        do {
            var mail = MailMessage(accountID: account.id, from: from, subject: subject, text: text); mail.to = [.init(email: account.email)]; mail.messageID = "<" + mail.id + "@example.com>"; mail.analysis = PartnerEngine.baseline(mail)
            try await store.upsert(mail); await reload(); await log("收到演示新邮件", detail: subject, messageIDs: [mail.id], kind: "demo-incoming")
            for var delegation in delegations where delegation.active && workMatches(mail, delegation: delegation) {
                if ["briefing", "followUp"].contains(delegation.kind) { delegation.nextRun = Date(); try await store.save(delegation, kind: "delegation", id: delegation.id); if let i = delegations.firstIndex(where: { $0.id == delegation.id }) { delegations[i] = delegation } }
                if let run = agentRuns.first(where: { $0.delegationID == delegation.id }) {
                    await addStep(run.id, title: "收到后续邮件", tool: "邮件", detail: subject, sourceIDs: [mail.id])
                    await updateRun(run.id, phase: .queued, summary: "收到“\(subject)”，正在核对这次变化。已有内容保留在下面。")
                }
            }; process(); await runDelegations()
        } catch { self.error = error.localizedDescription }
    }
}
