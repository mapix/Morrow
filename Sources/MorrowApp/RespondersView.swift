import SwiftUI
import MorrowCore

struct RespondersView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    private var rules: [MailResponder] { model.responders.filter { !$0.archived }.sorted { $0.createdAt > $1.createdAt } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack { Text(L10n.t("这些来信，我会接住。")).font(Theme.title); Spacer(); Button(L10n.t("设定响应器")) { model.responderEditor = MailResponder() }.buttonStyle(PrimaryButtonStyle()) }
                Text(L10n.t("设定邮件条件和回复方式。新邮件到来后，我会准备草稿或按你的设置自动回复，每次响应都留有记录。")).font(Theme.reader).foregroundStyle(Theme.secondary)
                if rules.isEmpty { EmptyRegion(icon: "arrowshape.turn.up.left", title: L10n.t("从一种明确的来信开始"), detail: L10n.t("例如：项目组发来材料时，自动回复已收到；客户询问排期时，先准备回复草稿。"), action: L10n.t("创建第一个响应器"), perform: { model.responderEditor = MailResponder() }) }
                ForEach(rules) { rule in
                    VStack(alignment: .leading, spacing: 16) {
                        HStack { Text(rule.title).font(Theme.heading); Spacer(); Text(rule.enabled ? L10n.t("正在响应") : L10n.t("已暂停")).font(Theme.label).foregroundStyle(Theme.secondary) }
                        Text(condition(rule)).font(Theme.body)
                        Text(rule.delivery == "send" ? L10n.format("自动回复；新邮件生效，每天最多{0}封", "\(rule.dailyLimit)") : L10n.t("自动准备回复草稿；新邮件生效")).font(Theme.label).foregroundStyle(Theme.secondary)
                        Text(rule.status).font(Theme.label).foregroundStyle(Theme.muted)
                        HStack {
                            Button(L10n.t("调整与试跑")) { model.responderEditor = rule }.buttonStyle(QuietButtonStyle())
                            Button(rule.enabled ? L10n.t("暂停响应") : L10n.t("启用响应")) { Task { await model.setResponderEnabled(rule, !rule.enabled) } }.buttonStyle(QuietButtonStyle())
                            Spacer()
                        }
                        let receipts = model.responderReceipts.filter { $0.responderID == rule.id }.sorted { $0.createdAt > $1.createdAt }
                        if !receipts.isEmpty {
                            DisclosureGroup(L10n.format("响应记录（{0}）", "\(receipts.count)")) {
                                ForEach(receipts) { receipt in
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 6) { Text(model.mails.first { $0.id == receipt.mailID }?.subject ?? L10n.t("来源邮件")); Text(receipt.detail).font(Theme.label).foregroundStyle(receipt.state == "failed" ? Theme.error : Theme.secondary) }
                                        Spacer()
                                        if let id = receipt.draftID, let draft = model.drafts.first(where: { $0.id == id }) { Button(draft.state == "sent" ? L10n.t("查看回复") : L10n.t("打开草稿")) { model.composer = draft }.buttonStyle(QuietButtonStyle()) }
                                    }.padding(.vertical, 12)
                                }
                            }.font(Theme.label)
                        }
                    }.padding(.vertical, 20).overlay(alignment: .top) { Rectangle().fill(Theme.rule).frame(height: 1) }
                }
            }.padding(32).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
        }.background(Theme.paper)
    }
    private func condition(_ rule: MailResponder) -> String {
        [rule.sender.isEmpty ? nil : L10n.t("来自：") + rule.sender, rule.subjectContains.isEmpty ? nil : L10n.t("主题包含：") + rule.subjectContains, rule.bodyContains.isEmpty ? nil : L10n.t("正文包含：") + rule.bodyContains].compactMap { $0 }.joined(separator: "\n")
    }
}

struct ResponderEditor: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    let initial: MailResponder
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var rule: MailResponder
    @State private var preview: ComposeDraft?
    @State private var source: MailMessage?
    @State private var busy = false
    @State private var message: String?
    init(initial: MailResponder) { self.initial = initial; _rule = State(initialValue: initial) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text(L10n.t("设定一个响应器")).font(Theme.title); Spacer(); Button(L10n.t("关闭")) { dismiss() }.buttonStyle(QuietButtonStyle()) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field(L10n.t("名称"), text: $rule.title, placeholder: L10n.t("收到项目材料后确认收悉"))
                    Picker(L10n.t("适用邮箱"), selection: $rule.accountID) { Text(L10n.t("所有已连接邮箱")).tag(""); ForEach(model.accounts) { Text($0.name).tag($0.id) } }
                    Text(L10n.t("以下条件同时满足时响应")).font(Theme.heading)
                    field(L10n.t("发件人"), text: $rule.sender, placeholder: L10n.t("team@example.com 或 @example.com；可不填"))
                    field(L10n.t("主题包含"), text: $rule.subjectContains, placeholder: L10n.t("项目评审"))
                    field(L10n.t("正文包含"), text: $rule.bodyContains, placeholder: L10n.t("可不填"))
                    Picker(L10n.t("回复内容"), selection: $rule.useAI) { Text(L10n.t("固定正文")).tag(false); Text(L10n.t("让 AI 按要求起草")).tag(true) }.pickerStyle(.segmented)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(rule.useAI ? L10n.t("AI 回复要求") : L10n.t("回复正文")).font(Theme.label)
                        TextEditor(text: $rule.response).font(Theme.body).scrollContentBackground(.hidden).padding(12).frame(height: 140).background(Theme.sheet).overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.fieldEdge)).accessibilityLabel(rule.useAI ? L10n.t("AI 回复要求") : L10n.t("回复正文"))
                        if !rule.useAI { Text(L10n.t("可用变量：{{senderName}}、{{subject}}、{{myName}}")).font(Theme.label).foregroundStyle(Theme.secondary) }
                    }
                    Picker(L10n.t("响应方式"), selection: $rule.delivery) { Text(L10n.t("先准备草稿")).tag("draft"); Text(L10n.t("自动发送回复")).tag("send") }.pickerStyle(.segmented)
                    if rule.delivery == "send" { Text(model.isDemo ? L10n.t("演示邮箱只模拟自动投递。正式邮箱会自动回复给匹配邮件的发件人，发送前有10秒撤回窗口。") : L10n.t("匹配的新邮件会自动回复给匹配邮件的发件人，发送前有10秒撤回窗口。")).font(Theme.label).foregroundStyle(Theme.secondary) }
                    Stepper(L10n.format("每天最多响应{0}封", "\(rule.dailyLimit)"), value: $rule.dailyLimit, in: 1...100)
                    Toggle(L10n.t("保存后启用，只处理之后到来的新邮件"), isOn: $rule.enabled)
                    HStack {
                        Button(busy ? L10n.t("正在试跑") : L10n.t("用现有邮件试跑")) { test() }.buttonStyle(QuietButtonStyle()).disabled(busy)
                        Spacer()
                        Button(L10n.t("保存响应器")) { Task { do { try await model.saveResponder(rule); dismiss() } catch { message = error.localizedDescription } } }.buttonStyle(PrimaryButtonStyle()).disabled(busy)
                    }
                    if let message { Text(message).font(Theme.body).foregroundStyle(Theme.secondary) }
                    if let preview, let source {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L10n.t("试跑结果")).font(Theme.heading); Text(L10n.t("匹配邮件：") + source.subject).font(Theme.label)
                            Text(L10n.t("收件人：") + preview.to).font(Theme.label); Text(preview.body).font(Theme.reader).textSelection(.enabled)
                            Text(L10n.t("试跑没有发送邮件，也没有启用响应器。")).font(Theme.label).foregroundStyle(Theme.secondary)
                        }.padding(20).background(Theme.sheet)
                    }
                }
            }
        }.padding(28).frame(width: 660, height: 760).background(Theme.paper).foregroundStyle(Theme.ink)
    }
    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(Theme.label).foregroundStyle(Theme.secondary); TextField(placeholder, text: text).textFieldStyle(PaperFieldStyle()).accessibilityLabel(title) } }
    private func test() {
        busy = true; message = nil; preview = nil
        Task {
            defer { busy = false }
            do { try rule.validate(); guard let mail = model.primaryMails.first(where: { rule.matches($0) && !model.isOutbound($0) }) else { message = L10n.t("当前邮件里没有匹配项，调整条件后可以再试。"); return }; source = mail; preview = try await model.responderDraft(rule, mail: mail) }
            catch { message = error.localizedDescription }
        }
    }
}
