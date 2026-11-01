import SwiftUI
import MorrowCore

struct PartnerConversation: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    @State private var instruction = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(L10n.t("和伙伴一起推进")).font(Theme.heading); Spacer(); Button { model.showDelegation = true } label: { Image(systemName: "arrow.triangle.branch") }.buttonStyle(.plain).help(L10n.t("建立持续委托")) }.padding(24)
            Divider().overlay(Theme.rule)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        if model.chat.isEmpty {
                            VStack(alignment: .leading, spacing: 20) {
                                Text(L10n.t("把一件事交给我。")).font(Theme.heading)
                                Text(L10n.t("我会从邮件中找线索，准备下一步，也会记住需要持续跟进的事。")).font(Theme.reader).foregroundStyle(Theme.muted).lineSpacing(5)
                                ForEach([L10n.t("哪些邮件需要我今天回复？"), L10n.t("跟进项目评审，收到相关邮件就准备回复草稿"), L10n.t("帮我整理账单并说明还缺哪些资料")], id: \.self) { prompt in Button { instruction = prompt; focused = true } label: { HStack { Text(prompt).multilineTextAlignment(.leading); Spacer(); Image(systemName: "plus") }.padding(.vertical, 14).overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) } }.buttonStyle(.plain).font(Theme.body) }
                            }.padding(.top, 16)
                        }
                        ForEach(model.chat) { message in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(message.role == "user" ? L10n.t("你") : "Morrow").font(Theme.label.weight(.medium)).foregroundStyle(Theme.muted)
                                Text(message.text).font(Theme.reader).lineSpacing(6).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                if !message.messageIDs.isEmpty {
                                    ForEach(message.messageIDs, id: \.self) { id in
                                        if let mail = model.mails.first(where: { $0.id == id }) { Button { model.select(mail) } label: { Label(mail.subject, systemImage: "envelope").lineLimit(1) }.buttonStyle(.link).font(Theme.label) }
                                    }
                                }
                            }.padding(message.role == "user" ? 14 : 0).background(message.role == "user" ? Theme.paper : Theme.clear, in: RoundedRectangle(cornerRadius: Theme.radius)).id(message.id)
                        }
                        if model.partnerBusy { HStack(spacing: 10) { ProgressView().controlSize(.small); Text(L10n.t("正在查邮件、准备执行…")).foregroundStyle(Theme.muted) }.font(Theme.label).id("working") }
                    }.padding(24)
                }.onChange(of: model.chat.count) { if let id = model.chat.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            Divider().overlay(Theme.rule)
            VStack(alignment: .leading, spacing: 12) {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $instruction).font(Theme.reader).scrollContentBackground(.hidden).frame(minHeight: 72, maxHeight: 110).padding(8).focused($focused).accessibilityLabel(L10n.t("给伙伴的委托"))
                    if instruction.isEmpty { Text(L10n.t("把要推进的事情告诉我，例如跟进回复、准备草稿或整理资料。")).font(Theme.reader).foregroundStyle(Theme.muted).padding(14).allowsHitTesting(false).accessibilityHidden(true) }
                }.background(Theme.paper, in: RoundedRectangle(cornerRadius: Theme.radius)).overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(focused ? Theme.focus : Theme.muted, lineWidth: 1))
                HStack { Button { model.importFiles() } label: { Label(L10n.t("交给我资料"), systemImage: "paperclip") }.buttonStyle(.link).font(Theme.label); Spacer(); Button(L10n.t("交给你")) { let text = instruction; instruction = ""; Task { await model.askPartner(text) } }.buttonStyle(PrimaryButtonStyle()).disabled(model.partnerBusy || instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.return, modifiers: .command) }
            }.padding(20)
        }.background(Theme.sheet)
    }
}

struct DelegationsView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    @State private var editing: Delegation?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { VStack(alignment: .leading, spacing: 8) { Text(L10n.t("交出去的事，持续有进展。")).font(Theme.title); Text(L10n.t("收到新邮件或到达约定时间时，伙伴会继续推进。关闭窗口后仍会运行。退出应用会暂停执行。")).font(Theme.body).foregroundStyle(Theme.muted) }; Spacer(); Button(L10n.t("新委托")) { model.showDelegation = true }.buttonStyle(PrimaryButtonStyle()) }.padding(32)
            if model.delegations.isEmpty { EmptyRegion(icon: "arrow.triangle.branch", title: L10n.t("还没有持续委托"), detail: L10n.t("跟进回复、准备草稿、整理项目邮件，或定时汇总，都可以交给伙伴。"), action: L10n.t("建立委托"), perform: { model.showDelegation = true }) }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack { Text(L10n.t("委托")).frame(maxWidth: .infinity, alignment: .leading); Text(L10n.t("进度")).frame(width: 260, alignment: .leading); Text(L10n.t("操作")).frame(width: 170, alignment: .trailing) }.font(Theme.label).foregroundStyle(Theme.muted).padding(.vertical, 12)
                        Divider().overlay(Theme.ink)
                        ForEach(model.delegations) { d in
                            HStack(alignment: .top, spacing: 24) {
                                VStack(alignment: .leading, spacing: 8) { Text(d.title).font(Theme.heading); Text(d.instruction).font(Theme.body).foregroundStyle(Theme.muted).lineLimit(3); Text(d.match.isEmpty ? L10n.t("匹配所有来信") : L10n.t("匹配：") + d.match).font(Theme.label).foregroundStyle(Theme.muted); if d.sendAuthorized { Text(L10n.format("可向 {0} 发送", "\(d.recipient)")).font(Theme.label).foregroundStyle(Theme.error) } }.frame(maxWidth: .infinity, alignment: .leading)
                                VStack(alignment: .leading, spacing: 8) { Text(d.status).font(Theme.body).lineLimit(3); if let next = d.nextRun { Text(L10n.t("下次：") + next.uiFormatted(date: .abbreviated, time: .shortened)).font(Theme.label).foregroundStyle(Theme.muted) }; if let last = d.lastRun { Text(L10n.t("上次：") + last.uiFormatted(date: .abbreviated, time: .shortened)).font(Theme.label).foregroundStyle(Theme.muted) } }.frame(width: 260, alignment: .leading)
                                HStack { Button(d.active ? L10n.t("暂停") : L10n.t("恢复")) { var updated = d; updated.active.toggle(); Task { await model.saveDelegation(updated) } }.buttonStyle(.link); Menu { Button(L10n.t("立即推进")) { Task { await model.runDelegations(forceID: d.id) } }; Button(L10n.t("编辑委托")) { editing = d } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24) }.frame(width: 170, alignment: .trailing)
                            }.padding(.vertical, 24)
                            Divider().overlay(Theme.rule)
                        }
                        Text(L10n.t("执行记录")).font(Theme.heading).padding(.top, 32).padding(.bottom, 20)
                        ForEach(model.events.filter { $0.delegationID != nil }.suffix(20).reversed()) { e in VStack(alignment: .leading, spacing: 10) { HStack { Text(e.title).font(Theme.body.weight(.medium)); Spacer(); Text(e.date.uiFormatted()).font(Theme.label).foregroundStyle(Theme.muted) }; Text(e.detail).font(Theme.reader).lineSpacing(4).textSelection(.enabled); HStack { ForEach(e.messageIDs, id: \.self) { id in if let mail = model.mails.first(where: { $0.id == id }) { Button(mail.subject) { model.select(mail); model.destination = .inbox }.buttonStyle(.link).font(Theme.label).lineLimit(1) } } } }.padding(.vertical, 20).overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) } }
                    }.padding(.horizontal, 32)
                }
            }
        }.background(Theme.paper).sheet(item: $editing) { d in DelegationEditor(initial: d).environmentObject(model) }
    }
}

struct DelegationEditor: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    var initial: Delegation? = nil
    @State private var delegation = Delegation()
    @State private var error = ""
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack { Text(initial == nil ? L10n.t("把一件事交给伙伴") : L10n.t("编辑委托")).font(Theme.title); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help(L10n.t("关闭")) }
            Form {
                TextField(L10n.t("委托名称"), text: $delegation.title)
                Picker(L10n.t("如何推进"), selection: $delegation.kind) { Text(L10n.t("看到相关新邮件就跟进")).tag("watch"); Text(L10n.t("收到请求就准备回复")).tag("reply"); Text(L10n.t("定时汇总")).tag("briefing"); Text(L10n.t("到时间追踪进展")).tag("followUp"); Text(L10n.t("自动归类到标签")).tag("organize") }
                TextField(L10n.t("匹配主题、正文或发件人"), text: $delegation.match)
                if ["watch", "reply", "organize"].contains(delegation.kind) { Toggle(L10n.t("也处理现有邮件"), isOn: $delegation.includeExisting) }
                VStack(alignment: .leading, spacing: 8) { Text(L10n.t("具体委托")).font(Theme.label); TextEditor(text: $delegation.instruction).font(Theme.reader).frame(height: 130).padding(8).background(Theme.sheet).overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.rule)) }
                if delegation.kind == "briefing" || delegation.kind == "followUp" {
                    Stepper(L10n.format("每 {0} 小时", "\(delegation.intervalHours)"), value: $delegation.intervalHours, in: 1...168)
                    DatePicker(L10n.t("首次推进时间"), selection: Binding(get: { delegation.nextRun ?? Date().addingTimeInterval(3600) }, set: { delegation.nextRun = $0 }))
                }
                Picker(L10n.t("交付方式"), selection: $delegation.action) { Text(L10n.t("准备草稿，等我审阅")).tag("draft"); Text(L10n.t("给我进展和提醒")).tag("notify") }
                if delegation.action == "draft" { TextField(L10n.t("草稿收件人（可选）"), text: $delegation.recipient) }
                if delegation.kind != "organize" {
                    Toggle(L10n.t("授权这项委托自动发送"), isOn: $delegation.sendAuthorized)
                    if delegation.sendAuthorized { TextField(L10n.t("仅允许发送给此邮箱"), text: $delegation.recipient); Text(L10n.t("每次执行的邮件会进入发件队列，并留下记录。授权只适用于这项委托和这个收件人。")).font(Theme.label).foregroundStyle(Theme.muted) }
                }
            }.formStyle(.grouped)
            if !error.isEmpty { Text(error).font(Theme.label).foregroundStyle(Theme.error) }
            HStack { Button(L10n.t("取消")) { dismiss() }.buttonStyle(QuietButtonStyle()); Spacer(); Button(saving ? L10n.t("保存中…") : L10n.t("交给伙伴")) {
                guard !delegation.title.isEmpty, !delegation.instruction.isEmpty else { error = L10n.t("请填写名称和具体委托。"); return }
                if delegation.sendAuthorized && !MailAddress.isValid(delegation.recipient) { error = L10n.t("自动发送必须限定一个有效收件人。"); return }
                if ["briefing", "followUp"].contains(delegation.kind), delegation.nextRun == nil { delegation.nextRun = Date().addingTimeInterval(Double(delegation.intervalHours * 3600)) }
                saving = true; Task { await model.saveDelegation(delegation); saving = false; dismiss() }
            }.buttonStyle(PrimaryButtonStyle()).disabled(saving) }
        }.padding(28).frame(width: 680, height: 760).background(Theme.paper).onAppear { if let initial { delegation = initial } }
    }
}

struct DraftsView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var accountID = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text(L10n.t("草稿箱")).font(Theme.title); Spacer(); Button(L10n.t("写邮件")) { Task { await model.compose() } }.buttonStyle(PrimaryButtonStyle()) }
            Text(L10n.t("自己写的、伙伴生成的，以及等待投递的邮件集中保存在这里。")).foregroundStyle(Theme.muted)
            HStack { TextField(L10n.t("搜索主题、收件人或正文"), text: $query).textFieldStyle(PaperFieldStyle()); Picker(L10n.t("发件邮箱"), selection: $accountID) { Text(L10n.t("全部邮箱")).tag(""); ForEach(model.accounts) { Text($0.email).tag($0.id) } }.frame(maxWidth: 220) }
            let drafts = model.drafts.filter { $0.state != "sent" && (accountID.isEmpty || $0.accountID == accountID) && (query.isEmpty || ($0.subject + $0.to + $0.body).localizedCaseInsensitiveContains(query)) }.sorted { $0.updatedAt > $1.updatedAt }
            if drafts.isEmpty { EmptyRegion(icon: "doc", title: L10n.t("还没有草稿"), detail: L10n.t("自己写一封，或让伙伴根据原邮件准备回复。"), action: L10n.t("写邮件"), perform: { Task { await model.compose() } }) }
            else {
                ScrollView { VStack(spacing: 0) { ForEach(drafts) { d in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text(d.subject.isEmpty ? L10n.t("无主题草稿") : d.subject).font(Theme.heading); Spacer(); Text(state(d)).font(Theme.label).foregroundStyle(d.state == "uncertain" ? Theme.error : Theme.muted) }
                        Text(d.to.isEmpty ? L10n.t("待填写收件人") : d.to).font(Theme.label).foregroundStyle(Theme.muted)
                        Text(model.accounts.first(where: { $0.id == d.accountID })?.email ?? L10n.t("尚未选择发件邮箱")).font(Theme.label).foregroundStyle(Theme.muted)
                        Text(d.body).lineLimit(3).foregroundStyle(Theme.muted)
                        if let error = d.error { Text(error).font(Theme.label).foregroundStyle(Theme.error) }
                        HStack { if d.state == "queued" { Button(L10n.t("撤回到草稿")) { Task { await model.cancelSend(d) } }.buttonStyle(.link) } else if d.state != "sending" { Button(L10n.t("编辑与预览")) { model.openDraft(d) }.buttonStyle(.link); Button(L10n.t("删除草稿")) { Task { await model.discardDraft(d) } }.buttonStyle(.link) } }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 24).overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
                } } }
            }
        }.padding(32).background(Theme.paper)
    }
    private func state(_ d: ComposeDraft) -> String { switch d.state { case "queued": return L10n.t("将在 ") + (d.scheduledAt?.uiFormatted(date: .abbreviated, time: .shortened) ?? L10n.t("稍后")) + L10n.t(" 发送"); case "sending": return L10n.t("发送中"); case "uncertain": return L10n.t("需要核对发送结果"); default: return L10n.t("草稿") } }
}
