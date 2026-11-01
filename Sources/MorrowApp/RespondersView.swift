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
                Text(L10n.t("锁定来信来源，交代处理要求。伙伴会读取资料、调用工具、核对结果，再回复原发件人；每次执行都能查看过程。")).font(Theme.reader).foregroundStyle(Theme.secondary)
                if rules.isEmpty { EmptyRegion(icon: "arrowshape.turn.up.left", title: L10n.t("从一种明确的来信开始"), detail: L10n.t("例如：项目组发来材料时，自动回复已收到；客户询问排期时，先准备回复草稿。"), action: L10n.t("创建第一个响应器"), perform: { model.responderEditor = MailResponder() }) }
                ForEach(rules) { rule in
                    VStack(alignment: .leading, spacing: 16) {
                        HStack { Text(rule.title).font(Theme.heading); Spacer(); if model.activeResponderID == rule.id { ProgressView().controlSize(.small); Text(model.responderStage).font(Theme.label) } else { Text(rule.enabled ? L10n.t("等待匹配来信") : L10n.t("已暂停")).font(Theme.label).foregroundStyle(Theme.secondary) } }
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
                                        if ["failed", "cancelled"].contains(receipt.state), (receipt.attempts ?? 1) < 3 { Button(L10n.t("重新处理")) { Task { await model.runResponders(retryReceiptID: receipt.id) } }.buttonStyle(QuietButtonStyle()).disabled(model.responderBusy || !rule.enabled) }
                                        if let id = receipt.runID, let run = model.agentRuns.first(where: { $0.id == id }) { Button(L10n.t("查看执行过程")) { model.selectRun(run) }.buttonStyle(QuietButtonStyle()) }
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
        [L10n.t("收信邮箱：") + (model.accounts.first(where: { $0.id == rule.accountID })?.email ?? L10n.t("尚未绑定")), L10n.t("文件夹：") + (rule.folderPath ?? L10n.t("尚未绑定")), L10n.t("发件邮箱白名单：") + rule.allowedSenders.joined(separator: ", "), rule.requireAuthentication != false ? L10n.t("发件身份：服务商 DMARC 验证") : L10n.t("发件身份：地址白名单"), rule.subjectContains.isEmpty ? nil : L10n.t("主题包含：") + rule.subjectContains, rule.bodyContains.isEmpty ? nil : L10n.t("正文包含：") + rule.bodyContains].compactMap { $0 }.joined(separator: "\n")
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
    @State private var saving = false
    @State private var message: String?
    init(initial: MailResponder) { self.initial = initial; var value = initial; if value.senderAllowlist != nil { value.sender = value.allowedSenders.joined(separator: ", ") }; _rule = State(initialValue: value) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text(L10n.t("设定一个响应器")).font(Theme.title); Spacer(); Button(L10n.t("关闭")) { dismiss() }.buttonStyle(QuietButtonStyle()) }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field(L10n.t("名称"), text: $rule.title, placeholder: L10n.t("收到项目材料后确认收悉"))
                    Picker(L10n.t("来源邮箱（必选）"), selection: $rule.accountID) { Text(L10n.t("请选择一个邮箱")).tag(""); ForEach(model.accounts.filter(\.enabled)) { Text($0.email).tag($0.id) } }.accessibilityIdentifier("responder.source-account")
                        .onChange(of: rule.accountID) { _, id in
                            let available = model.folders.filter { $0.accountID == id && !["sent", "trash", "junk"].contains($0.role) }
                            rule.folderPath = available.first(where: { $0.role == "inbox" })?.path ?? available.first?.path ?? "INBOX"
                            rule.trustedAuthService = model.accounts.first(where: { $0.id == id })?.imapHost == "imap.gmail.com" ? "mx.google.com" : nil
                        }
                    Picker(L10n.t("来源文件夹"), selection: Binding(get: { rule.folderPath ?? "" }, set: { rule.folderPath = $0 })) {
                        Text(L10n.t("请选择来源文件夹")).tag("")
                        ForEach(model.folders.filter { $0.accountID == rule.accountID && !["sent", "trash", "junk"].contains($0.role) }) { Text($0.name).tag($0.path) }
                    }.accessibilityIdentifier("responder.source-folder")
                    Text(L10n.t("以下条件同时满足时响应")).font(Theme.heading)
                    field(L10n.t("发件邮箱白名单（必填）"), text: $rule.sender, placeholder: "alice@example.com, bob@example.com")
                        .onChange(of: rule.sender) { _, text in rule.senderAllowlist = MailResponder.parseAllowlist(text) }
                    Text(L10n.t("只接受完整邮箱地址，多个地址用逗号分隔。工具只读取触发邮件与其附件。")).font(Theme.label).foregroundStyle(Theme.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.t("允许触发的发件邮箱")).font(Theme.label)
                        let addresses = MailResponder.parseAllowlist(rule.sender)
                        if addresses.isEmpty { Text(L10n.t("尚未允许任何来源，不能启用。")).foregroundStyle(Theme.muted) }
                        ForEach(Array(Set(addresses)).sorted(), id: \.self) { address in Label(address, systemImage: MailResponder.validSender(address) ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(MailResponder.validSender(address) ? Theme.ink : Theme.error) }
                    }.font(Theme.body).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.sheet).accessibilityIdentifier("responder.source-allowlist")
                    Picker(L10n.t("发件身份验证"), selection: Binding(get: { rule.requireAuthentication != false }, set: { rule.requireAuthentication = $0 })) { Text(L10n.t("服务商 DMARC 验证")).tag(true); Text(L10n.t("仅地址白名单")).tag(false) }
                    if rule.requireAuthentication != false { field(L10n.t("可信认证服务"), text: Binding(get: { rule.trustedAuthService ?? "" }, set: { rule.trustedAuthService = $0 }), placeholder: "mx.google.com") }
                    else { Text(L10n.t("地址白名单只校验 From 地址，不验证发件身份。")).font(Theme.label).foregroundStyle(Theme.secondary) }
                    field(L10n.t("主题包含"), text: $rule.subjectContains, placeholder: L10n.t("项目评审"))
                    field(L10n.t("正文包含"), text: $rule.bodyContains, placeholder: L10n.t("可不填"))
                    Picker(L10n.t("回复内容"), selection: $rule.useAI) { Text(L10n.t("固定正文")).tag(false); Text(L10n.t("让 AI 按要求起草")).tag(true) }.pickerStyle(.segmented)
                    Text(L10n.t("两种写法都经过 Agent 的读取、工具执行和结果核对。")).font(Theme.label).foregroundStyle(Theme.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(rule.useAI ? L10n.t("AI 回复要求") : L10n.t("回复正文")).font(Theme.label)
                        TextEditor(text: $rule.response).font(Theme.body).scrollContentBackground(.hidden).padding(12).frame(height: 140).background(Theme.sheet).overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.fieldEdge)).accessibilityLabel(rule.useAI ? L10n.t("AI 回复要求") : L10n.t("回复正文"))
                        if !rule.useAI { Text(L10n.t("可用变量：{{senderName}}、{{subject}}、{{myName}}")).font(Theme.label).foregroundStyle(Theme.secondary) }
                    }
                    Picker(L10n.t("响应方式"), selection: $rule.delivery) { Text(L10n.t("先准备草稿")).tag("draft"); Text(L10n.t("自动发送回复")).tag("send") }.pickerStyle(.segmented)
                    if rule.delivery == "send" { Text(model.isDemo ? L10n.t("演示邮箱只模拟自动投递。正式邮箱会自动回复给匹配邮件的发件人，发送前有10秒撤回窗口。") : L10n.t("匹配的新邮件会自动回复给匹配邮件的发件人，发送前有10秒撤回窗口。")).font(Theme.label).foregroundStyle(Theme.secondary) }
                    Stepper(L10n.format("每天最多响应{0}封", "\(rule.dailyLimit)"), value: $rule.dailyLimit, in: 1...100)
                    Text(L10n.format("策略：最多{0}轮、{1}次工具调用、{2}秒；越界或失败停止投递。", "\(rule.policy.maximumTurns)", "\(rule.policy.maximumTools)", "\(rule.policy.maximumSeconds)")).font(Theme.label).foregroundStyle(Theme.secondary)
                    Text(rule.policy.networkDomains.isEmpty ? L10n.t("工具外网已禁用。") : L10n.t("工具网络仅允许：") + rule.policy.networkDomains.joined(separator: ", ")).font(Theme.label).foregroundStyle(Theme.secondary)
                    Text(L10n.t("自己发出的邮件、退信、邮件列表及自动生成/自动回复的来信会跳过，避免互相响应。")).font(Theme.label).foregroundStyle(Theme.secondary)
                    DisclosureGroup(L10n.t("执行策略")) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L10n.t("所有工具通过 Anthropic Sandbox Runtime 执行，仅可写本轮隔离目录，结束后清理。")).font(Theme.label).foregroundStyle(Theme.secondary)
                            Toggle(L10n.t("允许读取触发邮件的附件"), isOn: toolPermission("readAttachment"))
                            Toggle(L10n.t("允许沙箱脚本计算与整理"), isOn: toolPermission("sandbox"))
                            field(L10n.t("工具网络域名白名单"), text: Binding(get: { rule.policy.networkDomains.joined(separator: ", ") }, set: { var policy = rule.policy; policy.networkDomains = MailResponder.parseAllowlist($0); rule.executionPolicy = policy }), placeholder: L10n.t("留空禁止外网；例如 example.com"))
                            Text(L10n.t("只允许白名单域名的 HTTPS（443）；不允许本机服务和 Unix socket。")).font(Theme.label).foregroundStyle(Theme.secondary)
                            Stepper(L10n.format("最多{0}轮 Agent 循环", "\(rule.policy.maximumTurns)"), value: policyValue(\.maximumTurns), in: 2...8)
                            Stepper(L10n.format("最多{0}次工具调用", "\(rule.policy.maximumTools)"), value: policyValue(\.maximumTools), in: 1...20)
                            Stepper(L10n.format("总执行预算{0}秒", "\(rule.policy.maximumSeconds)"), value: policyValue(\.maximumSeconds), in: 30...600, step: 30)
                            Stepper(L10n.format("单条沙箱脚本最多{0}秒", "\(rule.policy.commandSeconds)"), value: policyValue(\.commandSeconds), in: 1...60)
                            Text(L10n.t("来源越界、工具失败或预算耗尽：停止投递，保留执行记录。回复只发给原发件人，不使用 Reply-To、抄送或密送。")).font(Theme.label).foregroundStyle(Theme.secondary)
                        }.padding(.top, 12)
                    }.accessibilityIdentifier("responder.execution-policy")
                    Toggle(L10n.t("保存后启用，只处理之后到来的新邮件"), isOn: $rule.enabled)
                    HStack {
                        Button(busy ? L10n.t("Agent 正在试跑…") : L10n.t("用现有邮件试跑")) { test() }.buttonStyle(QuietButtonStyle()).disabled(busy || saving)
                        Spacer()
                        Button(saving ? L10n.t("正在保存…") : rule.enabled ? L10n.t("保存并启用响应器") : L10n.t("保存为暂停")) { saving = true; Task { defer { saving = false }; do { try await model.saveResponder(rule); dismiss() } catch { message = error.localizedDescription } } }.buttonStyle(PrimaryButtonStyle()).disabled(busy || saving)
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
    private func policyValue<Value>(_ key: WritableKeyPath<ResponderExecutionPolicy, Value>) -> Binding<Value> { Binding(get: { rule.policy[keyPath: key] }, set: { var policy = rule.policy; policy[keyPath: key] = $0; rule.executionPolicy = policy }) }
    private func toolPermission(_ tool: String) -> Binding<Bool> { Binding(get: { rule.policy.allowedTools.contains(tool) }, set: { enabled in var policy = rule.policy; policy.allowedTools.removeAll { $0 == tool }; if enabled { policy.allowedTools.append(tool) }; rule.executionPolicy = policy }) }
    private func test() {
        busy = true; message = nil; preview = nil
        Task {
            defer { busy = false }
            do { try rule.validate(); guard let mail = model.primaryMails.first(where: { rule.matches($0) && !model.isOutbound($0) }) else { message = L10n.t("当前邮件里没有匹配项，调整条件后可以再试。"); return }; source = mail; preview = try await model.responderDraft(rule, mail: mail) }
            catch { message = error.localizedDescription }
        }
    }
}
