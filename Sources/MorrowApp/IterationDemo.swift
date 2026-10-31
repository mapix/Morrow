import Foundation
import MorrowCore

extension AppModel {
    func installIterationDemo() async {
        guard isDemo, let account = accounts.first(where: \.isDemo) else { return }
        let definitions: [(String, String, String, String)] = [
            ("<people-history-1@example.com>", "林舟", "项目材料与合同核对", "这是演示邮件。\n我是云帆科技的项目联系人林舟，负责整理项目材料和交付安排。\n请比较合同条款与费用清单，验收期限仍待双方确认。\n林舟\n项目联系人，云帆科技"),
            ("<people-history-2@example.com>", "Lynn Lin", "Re: 项目材料与合同核对", "这是演示邮件。\n我是林舟，新版建议验收期限为7个工作日，旧版是10个工作日。总费用11800元，没有改变。请先核对，不代表已经同意条款。"),
            ("<people-history-3@example.com>", "你", "Re: 项目材料与合同核对", "这是演示已发送副本。\n材料已收到，我们会核对验收期限和费用，不作新的签约或付款确认。")
        ]
        do {
            for (index, row) in definitions.enumerated() where !mails.contains(where: { $0.messageID == row.0 }) {
                var mail = MailMessage(accountID: account.id, from: .init(name: row.1, email: index == 2 ? account.email : "lin@example.com"), subject: row.2, text: row.3)
                mail.messageID = row.0; mail.to = [.init(name: index == 2 ? "林舟" : "你", email: index == 2 ? "lin@example.com" : account.email)]; mail.cc = [.init(name: "示例财务", email: "finance@example.com")]
                mail.date = Date().addingTimeInterval(-Double(6 - index) * 24 * 3600); mail.isRead = true; mail.analysis = PartnerEngine.baseline(mail)
                if index == 2 { mail.folder = "Sent" }
                if index == 0 { mail.attachments = [.init(name: "合同条款-旧版.md", mimeType: "text/markdown", data: Data("演示合同：验收期限10个工作日；费用11800元；待双方确认。".utf8)), .init(name: "费用清单.csv", mimeType: "text/csv", data: Data("项目,金额\n服务费,11800\n状态,待核对\n".utf8))] }
                if index == 1 { mail.attachments = [.init(name: "合同条款-更新.md", mimeType: "text/markdown", data: Data("演示更新建议：验收期限7个工作日；费用11800元不变；尚未签约。".utf8))] }
                try await store.upsert(mail)
            }
            await reload(); process()
        } catch { self.error = error.localizedDescription }
    }
}
