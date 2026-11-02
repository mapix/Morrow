import SwiftUI
import MorrowCore

struct PeopleWorkspaceView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var editing: ContactEntry?
    @State private var visibleClaims = 12
    @State private var showingDetail = false
    @State private var matchingIDs = Set<String>()
    @State private var searching = false
    @State private var searchError: String?
    private static let searchIndex = ContactSearchIndex()
    private struct SearchRequest: Equatable { let query: String; let revision: Int }
    private var searchRequest: SearchRequest { .init(query: query, revision: model.contactProfileRevision) }
    private var profiles: [ContactProfile] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? model.contactProfiles : model.contactProfiles.filter { matchingIDs.contains($0.id) }
    }
    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 660
            Group {
                if compact {
                    if showingDetail && model.selectedProfile != nil {
                        VStack(spacing: 0) {
                            HStack { Button { showingDetail = false; model.selectedContactEmail = nil } label: { Label(L10n.t("联系人列表"), systemImage: "chevron.left") }.buttonStyle(CompactButtonStyle()); Spacer() }.padding(.horizontal, 24).padding(.vertical, 12)
                            Divider().overlay(Theme.rule)
                            detailContent
                        }
                    } else { indexContent }
                } else {
                    HSplitView {
                        indexContent.frame(minWidth: 200, idealWidth: 230, maxWidth: 260)
                        detailContent.frame(minWidth: 400)
                    }
                }
            }.onAppear {
                showingDetail = model.selectedProfile != nil
                if !compact && model.selectedContactEmail == nil { model.selectedContactEmail = profiles.first?.email }
            }
        }.background(Theme.sheet).sheet(item: $editing) { contact in ContactEditor(initial: contact).environmentObject(model) }
            .onChange(of: model.selectedContactEmail) { visibleClaims = 12; showingDetail = model.selectedProfile != nil }
            .task(id: searchRequest) {
                let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !term.isEmpty else { matchingIDs = []; searching = false; searchError = nil; return }
                searching = true; searchError = nil
                do {
                    try await Task.sleep(for: .milliseconds(150))
                    let ids = try await Self.searchIndex.matchingIDs(in: model.contactProfiles, query: term)
                    guard !Task.isCancelled else { return }; matchingIDs = ids; searching = false
                } catch { if !Task.isCancelled { searchError = error.localizedDescription; searching = false } }
            }
    }
    private var indexContent: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(L10n.t("联系人")).font(Theme.heading)
                    Text(String(profiles.count)).font(Theme.label).foregroundStyle(Theme.muted).monospacedDigit()
                    Spacer()
                    Menu {
                        Button(L10n.t("添加联系人")) { editing = ContactEntry() }
                        Button(L10n.t("导入系统通讯录")) { Task { await model.importSystemContacts() } }
                        Button(L10n.t("导入vCard或邮件")) { model.importFiles() }
                    } label: { Image(systemName: "person.badge.plus").frame(width: 28, height: 28) }.menuStyle(.borderlessButton).menuIndicator(.hidden).help(L10n.t("联系人管理")).accessibilityLabel(L10n.t("联系人管理"))
                }
                TextField(L10n.t("搜索姓名、邮箱或往来主题"), text: $query).textFieldStyle(PaperFieldStyle()).accessibilityIdentifier("people.search")
                if searching { ProgressView(L10n.t("正在搜索联系人…")).font(Theme.label) }
                if let searchError { Text(searchError).font(Theme.label).foregroundStyle(Theme.error) }
                if !model.ready { ProgressView(L10n.t("正在加载联系人…")).font(Theme.label).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if profiles.isEmpty && !searching {
                    EmptyRegion(icon: "person.crop.circle", title: L10n.t(query.isEmpty ? "还没有联系人" : "没有匹配的联系人"), detail: L10n.t(query.isEmpty ? "同步邮件或导入通讯录后，联系人会出现在这里。" : "换一个关键词，或清除搜索。"), action: query.isEmpty ? L10n.t("添加联系人") : L10n.t("清除搜索"), perform: { if query.isEmpty { editing = ContactEntry() } else { query = "" } })
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(profiles) { profile in
                                Button { model.selectProfile(profile.email); showingDetail = true } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 8) {
                                            Text(profile.display).font(Theme.body.weight(.medium)).lineLimit(1)
                                            Spacer(minLength: 4)
                                            Text(String(profile.mailCount)).font(Theme.small).foregroundStyle(Theme.muted).monospacedDigit()
                                        }
                                        Text(profile.email).font(Theme.small).foregroundStyle(Theme.secondary).lineLimit(1)
                                    }.padding(.vertical, 10).padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading).background(model.selectedContactEmail == profile.email ? Theme.selected : Theme.clear, in: RoundedRectangle(cornerRadius: Theme.radius))
                                }.buttonStyle(ListRowButtonStyle()).help(profile.email).accessibilityAddTraits(model.selectedContactEmail == profile.email ? .isSelected : []).accessibilityIdentifier("people.open")
                            }
                        }
                    }
                }
            }.padding(16).background(Theme.sidebar)
    }
    @ViewBuilder private var detailContent: some View {
            if let profile = model.selectedProfile {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        profileHeader(profile)
                        VStack(alignment: .leading, spacing: 12) {
                            HStack { Text(L10n.t("往来线索")).font(Theme.heading); Spacer(); Button(L10n.t("重新整理")) { model.scheduleProfileAnalysis(force: profile.email) }.buttonStyle(CompactButtonStyle()).disabled(!model.settings.enabled || !model.settings.autoAnalyze).help(profile.analyzedAt.map { L10n.t("上次整理：") + $0.uiFormatted() } ?? L10n.t("整理历史邮件线索")) }
                            if profile.claims.isEmpty || profile.analysisStatus.contains("未完成") { Text(profile.analysisStatus).font(Theme.label).foregroundStyle(Theme.secondary) }
                            ForEach(profile.claims.prefix(visibleClaims)) { claim in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(claim.text).font(Theme.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    DisclosureGroup(L10n.t("依据")) {
                                        Text(claim.quote).font(Theme.label).foregroundStyle(Theme.secondary).textSelection(.enabled)
                                        if let mail = model.mailByID(claim.mailID) { Button(mail.subject) { model.revealMail(mail) }.buttonStyle(ReferenceRowButtonStyle()).font(Theme.label) }
                                    }.font(Theme.label)
                                }.padding(.vertical, 8)
                                Divider().overlay(Theme.rule)
                            }
                            if profile.claims.count > visibleClaims { Button(L10n.t("显示更多线索")) { visibleClaims += 12 }.buttonStyle(CompactButtonStyle()) }
                        }
                        MailReferenceList(ids: profile.mailIDs, title: L10n.t("全部往来邮件"), collapsible: false, showsDetails: true, open: model.revealMail)
                    }.padding(24).frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                EmptyRegion(icon: "person.crop.rectangle", title: L10n.t("选择联系人"), detail: L10n.t("查看往来邮件、可核验线索和通讯录资料。"), action: nil)
            }
    }
    private func profileHeader(_ profile: ContactProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) { Text(profile.display).font(Theme.title); Text(profile.email).font(Theme.body).foregroundStyle(Theme.secondary).textSelection(.enabled) }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { profileActions(profile); Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 8) { profileActions(profile) }
            }
            Text(L10n.format("往来{0}封，收到{1}封，发给对方{2}封", String(profile.mailCount), String(profile.received), String(profile.sent))).font(Theme.label).foregroundStyle(Theme.secondary)
            if let last = profile.lastSeen { Text(L10n.t("最近：") + last.uiFormatted(date: .abbreviated, time: .omitted)).font(Theme.small).foregroundStyle(Theme.muted) }
            if profile.firstSeen != nil || profile.aliases.count > 1 {
                DisclosureGroup(L10n.t("往来资料")) {
                    if let first = profile.firstSeen { Text(L10n.t("首次：") + first.uiFormatted(date: .abbreviated, time: .omitted)) }
                    if profile.aliases.count > 1 { Text(L10n.t("曾用名称：") + profile.aliases.joined(separator: "、")) }
                }.font(Theme.label).foregroundStyle(Theme.secondary)
            }
            Divider().overlay(Theme.rule)
        }
    }
    @ViewBuilder private func profileActions(_ profile: ContactProfile) -> some View {
        Button(L10n.t("写邮件")) { Task { await model.compose(); model.composer?.to = profile.email } }.buttonStyle(PrimaryButtonStyle())
        Button(L10n.t("分析往来")) { model.chatInput = L10n.t("分析当前联系人的全部往来，整理合作事项、尚未解决的问题与下一步，并引用邮件。"); model.beginSidebarChat() }.buttonStyle(CompactButtonStyle()).disabled(model.partnerBusy)
        Menu(L10n.t("联系人资料")) {
            Button(L10n.t("编辑通讯录信息")) { editing = contact(for: profile) }
            Button(L10n.t("导出vCard")) { model.exportContact(contact(for: profile)) }
        }.menuStyle(.borderlessButton).font(Theme.label)
    }
    private func contact(for profile: ContactProfile) -> ContactEntry {
        var contact = model.contacts.first(where: { $0.email.lowercased() == profile.email }) ?? ContactEntry()
        contact.email = profile.email; if contact.name.isEmpty { contact.name = profile.name }; return contact
    }
}
