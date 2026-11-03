import SwiftUI
import MorrowCore

struct RespondersView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    @State private var receiptLimits: [String: Int] = [:]
    private var rules: [MailResponder] { model.responders.filter { !$0.archived }.sorted { $0.createdAt > $1.createdAt } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkspacePageHeader("自动响应", subtitle: "按明确来源处理新来信，查看草稿与投递回执。") {
                Button(L10n.t("新建响应规则")) { model.responderEditor = MailResponder() }.buttonStyle(PrimaryButtonStyle())
            }
            Divider().overlay(Theme.rule)
            if !model.ready { ProgressView(L10n.t("正在加载响应规则…")).font(Theme.label).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if rules.isEmpty { EmptyRegion(icon: "arrowshape.turn.up.left", title: L10n.t("还没有响应规则"), detail: L10n.t("指定邮箱、文件夹和发件人，再选择准备草稿或自动回复。"), action: L10n.t("新建响应规则"), perform: { model.responderEditor = MailResponder() }) }
            else {
                ScrollView { LazyVStack(alignment: .leading, spacing: 0) { ForEach(rules) { rule in
                    ruleRow(rule)
                    Divider().overlay(Theme.rule)
                } } }
            }
        }.padding(24).background(Theme.sheet)
    }
    private func ruleRow(_ rule: MailResponder) -> some View {
        let receipts = model.responderReceipts.filter { $0.responderID == rule.id }.sorted { $0.createdAt > $1.createdAt }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(rule.title).font(Theme.heading).lineLimit(2)
                Spacer(minLength: 8)
                if model.activeResponderID == rule.id { ProgressView().controlSize(.small); Text(model.responderStage).font(Theme.label) }
                else { Text(L10n.t(rule.enabled ? "等待匹配来信" : "已暂停")).font(Theme.label).foregroundStyle(rule.enabled ? Theme.secondary : Theme.muted) }
            }
            Text(condition(rule)).font(Theme.label).foregroundStyle(Theme.secondary).lineLimit(2).help(condition(rule))
            Text(rule.delivery == "send" ? L10n.format("自动回复；每天最多{0}封", String(rule.dailyLimit)) : L10n.t("准备回复草稿，等待审阅")).font(Theme.label).foregroundStyle(Theme.secondary)
            if !rule.status.isEmpty { Text(rule.status).font(Theme.small).foregroundStyle(Theme.muted).lineLimit(2) }
            HStack(spacing: 8) {
                Button(L10n.t("编辑与试跑")) { model.responderEditor = rule }.buttonStyle(CompactButtonStyle())
                Button(L10n.t(rule.enabled ? "暂停响应" : "启用响应")) { Task { await model.setResponderEnabled(rule, !rule.enabled) } }.buttonStyle(CompactButtonStyle()).disabled(model.activeResponderID == rule.id)
                Spacer(minLength: 0)
            }
            if !receipts.isEmpty {
                DisclosureGroup(L10n.format("响应记录（{0}）", String(receipts.count))) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(receipts.prefix(receiptLimits[rule.id] ?? 20)) { receipt in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(model.mailByID(receipt.mailID)?.subject ?? L10n.t("来源邮件")).font(Theme.body.weight(.medium)).lineLimit(2)
                                Text(receipt.detail).font(Theme.label).foregroundStyle(receipt.state == "failed" ? Theme.error : Theme.secondary).textSelection(.enabled)
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 8) { receiptActions(receipt, rule: rule); Spacer(minLength: 0) }
                                    VStack(alignment: .leading, spacing: 8) { receiptActions(receipt, rule: rule) }
                                }
                            }.padding(.vertical, 8)
                            Divider().overlay(Theme.rule)
                        }
                        if receipts.count > (receiptLimits[rule.id] ?? 20) { Button(L10n.t("显示更多记录")) { receiptLimits[rule.id] = (receiptLimits[rule.id] ?? 20) + 20 }.buttonStyle(CompactButtonStyle()) }
                    }
                }.font(Theme.label)
            }
        }.padding(.vertical, 16).accessibilityIdentifier("responder.rule")
    }
    @ViewBuilder private func receiptActions(_ receipt: ResponderReceipt, rule: MailResponder) -> some View {
        if ["failed", "cancelled", "skipped"].contains(receipt.state), (receipt.attempts ?? 1) < 3 { Button(L10n.t("重新处理")) { Task { await model.runResponders(retryReceiptID: receipt.id) } }.buttonStyle(CompactButtonStyle()).disabled(model.responderBusy || !rule.enabled) }
        if let id = receipt.runID, let run = model.agentRuns.first(where: { $0.id == id }) { Button(L10n.t("查看执行过程")) { model.selectRun(run) }.buttonStyle(CompactButtonStyle()) }
        if let id = receipt.draftID, let draft = model.drafts.first(where: { $0.id == id }) { Button(L10n.t(draft.state == "sent" ? "查看回复" : "打开草稿")) { model.openDraft(draft) }.buttonStyle(CompactButtonStyle()) }
    }
    private func condition(_ rule: MailResponder) -> String {
        let account = model.accounts.first { $0.id == rule.accountID }?.email ?? L10n.t("未选择邮箱")
        return account + " / " + (rule.folderPath ?? "INBOX") + "\n" + rule.allowedSenders.joined(separator: ", ")
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
    @State private var testTask: Task<Void, Never>?
    @State private var message: String?
    @State private var messageIsError = false
    init(initial: MailResponder) { self.initial = initial; var value = initial; if value.senderAllowlist != nil { value.sender = value.allowedSenders.joined(separator: ", ") }; _rule = State(initialValue: value) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text(L10n.t("响应规则")).font(Theme.title); Spacer(); Button(L10n.t("关闭")) { testTask?.cancel(); dismiss() }.buttonStyle(CompactButtonStyle()).disabled(saving).keyboardShortcut(.cancelAction) }
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
                    Picker(L10n.t("发件身份验证"), selection: Binding(get: { rule.requireAuthentication == true }, set: { rule.requireAuthentication = $0 })) { Text(L10n.t("服务商 DMARC 验证（可选）")).tag(true); Text(L10n.t("按来源条件匹配")).tag(false) }
                    if rule.requireAuthentication == true { field(L10n.t("可信认证服务"), text: Binding(get: { rule.trustedAuthService ?? "" }, set: { rule.trustedAuthService = $0 }), placeholder: "mx.google.com") }
                    else { Text(L10n.t("按绑定邮箱、发件地址和关键词匹配来信。")).font(Theme.label).foregroundStyle(Theme.secondary) }
                    field(L10n.t("主题包含"), text: $rule.subjectContains, placeholder: L10n.t("项目评审"))
                    field(L10n.t("正文包含"), text: $rule.bodyContains, placeholder: L10n.t("可不填"))
                    Picker(L10n.t("回复内容"), selection: $rule.useAI) { Text(L10n.t("固定正文")).tag(false); Text(L10n.t("让 AI 按要求起草")).tag(true) }.pickerStyle(.segmented)
                    Toggle(L10n.t("生成一张图片并作为回复附件"), isOn: Binding(get: { rule.imageReply != nil }, set: { enabled in
                        rule.imageReply = enabled ? .init() : nil
                        var policy = rule.policy; policy.allowedTools.removeAll { $0 == "generateImage" }
                        if enabled { policy.allowedTools.append("generateImage"); policy.maximumSeconds = max(360, policy.maximumSeconds); rule.useAI = true; rule.dailyLimit = min(3, rule.dailyLimit) }
                        rule.executionPolicy = policy
                    })).accessibilityIdentifier("responder.image-reply")
                    if rule.imageReply != nil {
                        field(L10n.t("图片模型（留空使用默认模型）"), text: Binding(get: { rule.imageReply?.model ?? "" }, set: { rule.imageReply?.model = $0.isEmpty ? nil : $0 }), placeholder: L10n.t("使用已配置的默认生图模型"))
                        Picker(L10n.t("图片尺寸"), selection: Binding(get: { rule.imageReply?.size ?? "1024x1024" }, set: { rule.imageReply?.size = $0 })) {
                            Text(L10n.t("自动")).tag("auto"); ForEach(["1024x1024", "1536x1024", "1024x1536"], id: \.self) { Text($0).tag($0) }
                        }
                        Picker(L10n.t("图片质量"), selection: Binding(get: { rule.imageReply?.quality ?? "auto" }, set: { rule.imageReply?.quality = $0 })) {
                            Text(L10n.t("自动")).tag("auto"); Text(L10n.t("低")).tag("low"); Text(L10n.t("中")).tag("medium"); Text(L10n.t("高")).tag("high")
                            Text(L10n.t("极高")).tag("xhigh"); Text(L10n.t("最高")).tag("max")
                        }
                        Text(L10n.t("每封匹配来信最多生成一张图片，生图有费用。试跑也会生成图片；重试复用成功结果，结果不确定时停止。")).font(Theme.label).foregroundStyle(Theme.secondary)
                    }
                    Text(L10n.t("保存后只处理符合来源条件的新邮件。")).font(Theme.label).foregroundStyle(Theme.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(rule.useAI ? L10n.t("AI 回复要求") : L10n.t("回复正文")).font(Theme.label)
                        TextEditor(text: $rule.response).font(Theme.body).scrollContentBackground(.hidden).padding(12).frame(height: 140).background(Theme.sheet).overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.fieldEdge)).accessibilityLabel(rule.useAI ? L10n.t("AI 回复要求") : L10n.t("回复正文"))
                        if !rule.useAI { Text(L10n.t("可用变量：{{senderName}}、{{subject}}、{{myName}}")).font(Theme.label).foregroundStyle(Theme.secondary) }
                    }
                    Picker(L10n.t("响应方式"), selection: $rule.delivery) { Text(L10n.t("先准备草稿")).tag("draft"); Text(L10n.t("自动发送回复")).tag("send") }.pickerStyle(.segmented)
                    if rule.delivery == "send" { Text(model.isDemo ? L10n.t("演示邮箱只模拟自动投递。正式邮箱会自动回复给匹配邮件的发件人，发送前有10秒撤回窗口。") : L10n.t("匹配的新邮件会自动回复给匹配邮件的发件人，发送前有10秒撤回窗口。")).font(Theme.label).foregroundStyle(Theme.secondary) }
                    Stepper(L10n.format("每天最多响应{0}封", "\(rule.dailyLimit)"), value: $rule.dailyLimit, in: 1...100)
                    DisclosureGroup(L10n.t("执行策略")) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L10n.format("策略：最多{0}轮、{1}次工具调用、{2}秒；越界或失败停止投递。", "\(rule.policy.maximumTurns)", "\(rule.policy.maximumTools)", "\(rule.policy.maximumSeconds)")).font(Theme.label).foregroundStyle(Theme.secondary)
                            Text(rule.policy.networkDomains.isEmpty ? L10n.t("工具外网已禁用。") : L10n.t("工具网络仅允许：") + rule.policy.networkDomains.joined(separator: ", ")).font(Theme.label).foregroundStyle(Theme.secondary)
                            Text(L10n.t("自己发出的邮件、退信、邮件列表及自动生成/自动回复的来信会跳过，避免互相响应。")).font(Theme.label).foregroundStyle(Theme.secondary)
                            Text(L10n.t("工具只可写隔离的临时目录，不能访问其他用户文件。")).font(Theme.label).foregroundStyle(Theme.secondary)
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
                    if let preview, let source {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L10n.t("试跑结果")).font(Theme.heading); Text(L10n.t("匹配邮件：") + source.subject).font(Theme.label)
                            Text(L10n.t("收件人：") + preview.to).font(Theme.label); Text(preview.body).font(Theme.reader).textSelection(.enabled)
                            ForEach(preview.attachments) { attachment in Text(L10n.t("附件：") + attachment.name + " · " + attachment.size).font(Theme.label) }
                            Text(L10n.t("试跑没有发送邮件，也没有启用响应器。")).font(Theme.label).foregroundStyle(Theme.secondary)
                        }.padding(20).background(Theme.sheet)
                    }
                }.disabled(busy || saving)
            }
            if let message { Text(message).font(Theme.label).foregroundStyle(messageIsError ? Theme.error : Theme.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            Divider().overlay(Theme.rule)
            footer
        }.padding(24).frame(minWidth: 400, idealWidth: 620, maxWidth: 700, minHeight: 520, idealHeight: 680, maxHeight: 760).background(Theme.paper).foregroundStyle(Theme.ink).onDisappear { testTask?.cancel() }
    }
    private var footer: some View {
        HStack(spacing: 8) {
            Button(busy ? L10n.t("Agent 正在试跑…") : L10n.t("用现有邮件试跑")) { test() }.buttonStyle(CompactButtonStyle()).disabled(busy || saving)
            Spacer(minLength: 8)
            Button(saving ? L10n.t("正在保存…") : rule.enabled ? L10n.t("保存并启用响应器") : L10n.t("保存为暂停")) {
                let snapshot = rule
                saving = true; message = nil; messageIsError = false; Task { defer { saving = false }; do { try await model.saveResponder(snapshot, expectedFingerprint: initial.boundAccountFingerprint == nil ? nil : initial.configurationFingerprint, expectNew: initial.boundAccountFingerprint == nil); dismiss() } catch { message = error.localizedDescription; messageIsError = true } }
            }.buttonStyle(PrimaryButtonStyle()).disabled(busy || saving).keyboardShortcut(.defaultAction)
        }
    }
    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(Theme.label).foregroundStyle(Theme.secondary); TextField(placeholder, text: text).textFieldStyle(PaperFieldStyle()).accessibilityLabel(title) } }
    private func policyValue<Value>(_ key: WritableKeyPath<ResponderExecutionPolicy, Value>) -> Binding<Value> { Binding(get: { rule.policy[keyPath: key] }, set: { var policy = rule.policy; policy[keyPath: key] = $0; rule.executionPolicy = policy }) }
    private func toolPermission(_ tool: String) -> Binding<Bool> { Binding(get: { rule.policy.allowedTools.contains(tool) }, set: { enabled in var policy = rule.policy; policy.allowedTools.removeAll { $0 == tool }; if enabled { policy.allowedTools.append(tool) }; rule.executionPolicy = policy }) }
    private func test() {
        busy = true; message = nil; messageIsError = false; preview = nil
        let snapshot = rule
        testTask = Task {
            defer { busy = false; testTask = nil }
            do {
                try snapshot.validate()
                guard let mail = model.primaryMails.first(where: { snapshot.matches($0) && !model.isOutbound($0) }) else { message = L10n.t("当前邮件里没有匹配项，调整条件后可以再试。"); return }
                let result = try await model.responderDraft(snapshot, mail: mail)
                guard !Task.isCancelled else { return }; source = mail; preview = result
            } catch { if !Task.isCancelled { message = error.localizedDescription; messageIsError = true } }
        }
    }
}
