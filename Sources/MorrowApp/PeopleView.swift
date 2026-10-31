import SwiftUI
import MorrowCore

struct PeopleWorkspaceView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var editing: ContactEntry?
    private var profiles: [ContactProfile] { model.contactProfiles.filter { query.isEmpty || ($0.display + $0.email + $0.topics.joined()).localizedCaseInsensitiveContains(query) } }
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text(L10n.t("联系人")).font(Theme.heading); Text("\(profiles.count)").font(Theme.label).foregroundStyle(Theme.muted); Spacer(); Menu {
                    Button(L10n.t("添加联系人")) { editing = ContactEntry() }
                    Button(L10n.t("导入系统通讯录")) { Task { await model.importSystemContacts() } }
                    Button(L10n.t("导入vCard或邮件")) { model.importFiles() }
                } label: { Image(systemName: "person.badge.plus").frame(width: 30, height: 40) }.menuStyle(.borderlessButton).help(L10n.t("联系人管理")) }
                TextField(L10n.t("搜索姓名、邮箱或往来主题"), text: $query).textFieldStyle(PaperFieldStyle())
                ScrollView { LazyVStack(spacing: 0) { ForEach(profiles) { p in
                    Button { model.selectProfile(p.email) } label: { VStack(alignment: .leading, spacing: 6) { Text(p.display).font(Theme.body.weight(.medium)); Text(p.email).font(Theme.label).foregroundStyle(Theme.secondary).lineLimit(1); Text(L10n.format("{0}封往来", "\(p.mailCount)")).font(Theme.label).foregroundStyle(Theme.muted) }.frame(maxWidth: .infinity, alignment: .leading).padding(model.compactLayout ? 8 : 14).background(model.selectedContactEmail == p.email ? Theme.selected : Theme.clear).contentShape(Rectangle()) }.buttonStyle(.plain)
                    Rectangle().fill(Theme.rule).frame(height: 1)
                } } }
            }.padding(20).frame(minWidth: 200, idealWidth: 230, maxWidth: 290)
            if let p = model.selectedProfile {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) { Text(p.display).font(Theme.title); Text(p.email).font(Theme.body).foregroundStyle(Theme.secondary).textSelection(.enabled) }
                        HStack { Button(L10n.t("分析往来")) { model.chatInput = L10n.t("分析当前联系人的全部往来，整理合作事项、尚未解决的问题与下一步，并引用邮件。"); model.beginSidebarChat() }.buttonStyle(CompactButtonStyle()); Button(L10n.t("写邮件")) { Task { await model.compose(); model.composer?.to = p.email } }.buttonStyle(CompactButtonStyle()); Spacer(); Menu(L10n.t("联系人资料")) { Button(L10n.t("编辑通讯录信息")) { var contact = model.contacts.first(where: { $0.email.lowercased() == p.email }) ?? ContactEntry(); contact.email = p.email; if contact.name.isEmpty { contact.name = p.name }; editing = contact }; Button(L10n.t("导出vCard")) { var contact = model.contacts.first(where: { $0.email.lowercased() == p.email }) ?? ContactEntry(); contact.email = p.email; if contact.name.isEmpty { contact.name = p.name }; model.exportContact(contact) } }.menuStyle(.borderlessButton).font(Theme.label) }
                        Text(L10n.format("往来{0}封，收到{1}封，发给对方{2}封", "\(p.mailCount)", "\(p.received)", "\(p.sent)")).font(Theme.label).foregroundStyle(Theme.muted)
                        if p.firstSeen != nil || p.aliases.count > 1 { DisclosureGroup(L10n.t("往来资料")) { VStack(alignment: .leading, spacing: 8) { if let first = p.firstSeen, let last = p.lastSeen { Text(L10n.t("首次：") + first.uiFormatted(date: .abbreviated, time: .omitted)); Text(L10n.t("最近：") + last.uiFormatted(date: .abbreviated, time: .omitted)) }; if p.aliases.count > 1 { Text(L10n.t("曾用名称：") + p.aliases.joined(separator: "、")) } }.font(Theme.label).foregroundStyle(Theme.secondary).padding(.top, 8) }.font(Theme.label) }
                        VStack(alignment: .leading, spacing: 14) {
                            HStack { Text(L10n.t("往来线索")).font(Theme.heading); Spacer(); Button(L10n.t("重新整理")) { model.scheduleProfileAnalysis(force: p.email) }.buttonStyle(.plain).font(Theme.label).help(p.analyzedAt.map { L10n.t("上次整理：") + $0.uiFormatted() } ?? L10n.t("整理历史邮件线索")) }
                            if p.claims.isEmpty || p.analysisStatus.contains("未完成") { Text(p.analysisStatus).font(Theme.label).foregroundStyle(Theme.secondary) }
                            ForEach(p.claims) { claim in
                                VStack(alignment: .leading, spacing: 7) { Text(claim.text).font(Theme.body).textSelection(.enabled); DisclosureGroup(L10n.t("依据")) { Text("“" + claim.quote + "”").font(Theme.label).foregroundStyle(Theme.secondary).textSelection(.enabled); if let mail = model.mailByID(claim.mailID) { Button(mail.subject) { model.revealMail(mail) }.buttonStyle(.plain).font(Theme.label).foregroundStyle(Theme.accent2) } }.font(Theme.label) }.padding(.vertical, 8)
                            }
                        }
                        Text(L10n.t("全部往来邮件")).font(Theme.heading)
                        ForEach(model.mails(withIDs: p.mailIDs)) { mail in
                            Button { model.revealMail(mail) } label: { VStack(alignment: .leading, spacing: 7) { HStack { Text(mail.subject).font(Theme.body.weight(.medium)); Spacer(); Text(mail.date.uiFormatted(date: .abbreviated, time: .omitted)).font(Theme.label) }; Text(mail.analysis?.summary ?? mail.preview).font(Theme.label).foregroundStyle(Theme.secondary).lineLimit(3) }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14) }.buttonStyle(.plain)
                            Rectangle().fill(Theme.rule).frame(height: 1)
                        }
                    }.padding(28).frame(maxWidth: 800, alignment: .leading).frame(maxWidth: .infinity)
                }
            } else { EmptyRegion(icon: "person.crop.rectangle", title: L10n.t("历史邮件，按人串起来"), detail: L10n.t("选择联系人，查看往来邮件、可核验线索和你补充的信息。"), action: nil) }
        }.background(Theme.paper).sheet(item: $editing) { contact in ContactEditor(initial: contact).environmentObject(model) }.onAppear { if model.selectedContactEmail == nil { model.selectedContactEmail = profiles.first?.email } }
    }
}
