import SwiftUI
import MorrowCore
import UniformTypeIdentifiers

@main struct MorrowMobileApp: App {
    @StateObject private var model = MobileModel()
    @Environment(\.scenePhase) private var phase
    @AppStorage("SmailMobileTheme") private var theme = "coral"
    @AppStorage("SmailMobileLanguage") private var language = "zh-Hans"
    var body: some Scene {
        WindowGroup { MobileRoot().environmentObject(model).tint(MobilePalette.value(theme).accent).preferredColorScheme(theme == "dark" ? .dark : .light).environment(\.locale, Locale(identifier: language)).onChange(of: language) { _, _ in model.presentationRevision += 1; model.settings.replyLanguage = MobileL10n.responseLanguage }.onChange(of: theme) { _, _ in model.presentationRevision += 1 }.task { if !model.ready { await model.start() }; while !Task.isCancelled { try? await Task.sleep(for: .seconds(30)); if Task.isCancelled { break }; if phase == .active { await model.syncCloud() } } }.onChange(of: phase) { _, value in if value == .active { Task { await model.syncCloud() } } } }
    }
}

struct MobileRoot: View {
    @EnvironmentObject var model: MobileModel
    @State private var settings = false
    @AppStorage("SmailMobileTheme") private var theme = "coral"
    var palette: MobilePalette { .value(theme) }
    var body: some View {
        TabView(selection: Binding(get: { model.selectedTab }, set: { model.selectedTab = $0; model.refreshVisibleContext() })) {
            Tab(MobileL10n.text("工作"), systemImage: "sparkles", value: MobileTab.work) { stack(.work) { MobileWork() } }
            Tab(MobileL10n.text("邮件"), systemImage: "tray", value: MobileTab.mail) { stack(.mail) { MobileInbox() } }
            Tab(MobileL10n.text("联系人"), systemImage: "person.2", value: MobileTab.people) { stack(.people) { MobilePeople() } }
            Tab(MobileL10n.text("附件"), systemImage: "paperclip", value: MobileTab.attachments) { stack(.attachments) { MobileAttachments() } }
        }
        .sheet(isPresented: $model.showChat) { MobileChat().environmentObject(model) }
        .sheet(isPresented: $settings) { NavigationStack { MobileSettings().environmentObject(model) } }
        .sheet(item: $model.compose) { value in MobileComposer(initial: value).environmentObject(model) }
        .alert(MobileL10n.text("错误"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button(MobileL10n.text("完成")) { model.error = nil } } message: { Text(model.error ?? "") }
    }
    @ViewBuilder func destination(_ route: MobileRoute) -> some View {
        switch route {
        case .mail(let id): MobileReader(mailID: id)
        case .contact(let email): MobileContactReader(email: email)
        case .attachment(let id):
            if let item = model.attachments.first(where: { $0.id == id || $0.attachment.id == id }) { MobileAttachmentReader(attachment: item.attachment, mail: item.mail) }
        case .drafts: MobileDraftLibrary()
        case .memory: MobileMemories()
        case .responders: MobileResponders()
        case .settings: MobileSettings()
        case .connectMailbox(let hint): MobileMailboxConnectionScreen(hint: hint)
        }
    }
    func stack<Content: View>(_ tab: MobileTab, @ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack(path: model.pathBinding(tab)) {
            content().navigationDestination(for: MobileRoute.self) { route in destination(route) }.toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { settings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel(MobileL10n.text("设置")).accessibilityIdentifier("settings.open")
                }
            }.background(palette.paper)
        }.safeAreaInset(edge: .bottom, spacing: 0) {
            Button { model.showChat = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "sparkle")
                    Text(MobileL10n.text("委托给 Morrow")).fontWeight(.medium)
                    Spacer()
                    if let label = model.context?.label { Text(label).font(.caption).lineLimit(1).foregroundStyle(palette.muted).frame(maxWidth: 145) }
                    Image(systemName: "bubble.left")
                }.padding(.horizontal, 20).padding(.vertical, 14).foregroundStyle(palette.ink).background(palette.sheet)
                    .overlay(alignment: .top) { Rectangle().fill(palette.rule).frame(height: 0.5) }
            }.accessibilityIdentifier("partner.open")
        }
    }

}

struct MobileWork: View {
    @EnvironmentObject var model: MobileModel
    @AppStorage("SmailMobileTheme") var theme = "coral"
    @State var importMail = false
    var body: some View {
        List {
            if model.accounts.isEmpty { Section { Text(MobileL10n.text("让往来的邮件，成为可委托的工作。")).font(.title2).fontWeight(.semibold); Button(MobileL10n.text("演示工作区")) { Task { await model.loadDemo() } }.accessibilityIdentifier("demo.open") } }
            Section {
                ForEach(model.mails.filter { $0.actionable || $0.analysis?.needsReply == true }) { mail in NavigationLink(value: MobileRoute.mail(mail.id)) { VStack(alignment: .leading, spacing: 7) { HStack { Text(mail.subject).font(.headline); Spacer(); Text(MobileL10n.text("待回复")).font(.caption).foregroundStyle(MobilePalette.value(theme).accent) }; Text(mail.analysis?.summary ?? mail.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(3); Text(mail.from.display).font(.caption) } } }
                if model.accounts.count > 0 && model.mails.filter({ $0.actionable || $0.analysis?.needsReply == true }).isEmpty { Text(MobileL10n.text("暂无待办")).foregroundStyle(.secondary) }
            }
            if !model.drafts.filter({ $0.state == "draft" }).isEmpty { Section(MobileL10n.text("草稿")) { ForEach(model.drafts.filter { $0.state == "draft" }) { draft in Button { model.compose = draft } label: { Label(draft.subject.isEmpty ? MobileL10n.text("草稿") : draft.subject, systemImage: "square.and.pencil") } } } }
            if !model.runs.isEmpty { Section(MobileL10n.text("工作")) { ForEach(model.runs) { run in VStack(alignment: .leading) { Text(run.title).font(.headline); Text(run.phase.label + "\n" + run.summary).font(.subheadline).foregroundStyle(.secondary) } } } }
            if !model.status.isEmpty { Section { Text(model.status).font(.caption).foregroundStyle(.secondary) } }
        }.scrollContentBackground(.hidden).navigationTitle("Morrow").toolbar { ToolbarItem(placement: .topBarLeading) { Menu { Button(MobileL10n.text("前台同步")) { Task { await model.sync() } }; Button(MobileL10n.text("导入邮件")) { importMail = true } } label: { Image(systemName: model.syncing ? "arrow.triangle.2.circlepath" : "ellipsis.circle") } } }.fileImporter(isPresented: $importMail, allowedContentTypes: [UTType(filenameExtension: "eml") ?? .data]) { result in if case .success(let url) = result { Task { await model.importMail(url) } } }.onAppear { if model.selectedTab == .work && model.workPath.isEmpty { model.context = model.pageContext("work", label: MobileL10n.text("工作")) } }
    }
}

struct MobileInbox: View {
    @EnvironmentObject var model: MobileModel
    @AppStorage("SmailMobileTheme") var theme = "coral"
    @AppStorage("SmailMobileCompact") var compact = false
    var filter: String { model.mailFilter }
    var visible: [MailMessage] { model.query.isEmpty ? model.scopedMails.filter(model.mailMatchesFilter) : model.searchHits.map(\.message) }
    var body: some View {
        List {
            Section { Picker(MobileL10n.text("全部邮箱"), selection: $model.accountID) { Text(MobileL10n.text("全部邮箱")).tag(""); ForEach(model.accounts) { account in Text(account.name.isEmpty ? account.email : account.name).tag(account.id) } }.onChange(of: model.accountID) { _, _ in model.updateInboxContext(); if !model.query.isEmpty { model.search() } }
                if model.query.isEmpty { Picker("", selection: $model.mailFilter) { Text(MobileL10n.text("邮件")).tag("inbox"); Text(MobileL10n.text("未读")).tag("unread"); Text(MobileL10n.text("全部")).tag("all"); Text(MobileL10n.text("已发送")).tag("sent"); Text(MobileL10n.text("星标")).tag("starred"); Text(MobileL10n.text("归档")).tag("archive"); Text(MobileL10n.text("废纸篓")).tag("trash") }.pickerStyle(.menu).onChange(of: model.mailFilter) { _, _ in model.updateInboxContext() } }
                else { Picker("", selection: $model.strategy) { Text(MobileL10n.text("语义")).tag(MailSearchStrategy.semantic); Text(MobileL10n.text("关键词")).tag(MailSearchStrategy.keyword) }.pickerStyle(.segmented).onChange(of: model.strategy) { _, _ in model.search() }; Text(model.status).font(.caption).foregroundStyle(.secondary) }
            }
            ForEach(visible) { mail in NavigationLink(value: MobileRoute.mail(mail.id)) { VStack(alignment: .leading, spacing: compact ? 4 : 8) { HStack { Text(mail.from.display).fontWeight(mail.isRead ? .regular : .semibold); Spacer(); Text(mail.date, style: .date).font(.caption).foregroundStyle(.secondary) }; Text(mail.subject).fontWeight(mail.isRead ? .regular : .semibold).lineLimit(2); HStack { if !mail.isRead { Text(MobileL10n.text("未读")).font(.caption).fontWeight(.semibold).padding(.horizontal, 7).padding(.vertical, 3).background(MobilePalette.value(theme).unread, in: Capsule()) }; if mail.isStarred { Image(systemName: "star.fill").foregroundStyle(MobilePalette.value(theme).accent) }; if !mail.attachments.isEmpty { Image(systemName: "paperclip") }; if !compact { Text(mail.preview).font(.caption).foregroundStyle(.secondary).lineLimit(1) } } }.padding(.vertical, compact ? 2 : 6) }.listRowBackground(mail.isRead ? MobilePalette.value(theme).sheet : MobilePalette.value(theme).unread.opacity(0.55)).swipeActions(edge: .leading) { Button { Task { await model.mark(mail, read: !mail.isRead) } } label: { Label(MobileL10n.text(mail.isRead ? "标记未读" : "标记已读"), systemImage: "envelope") } }.swipeActions { Button { Task { await model.mark(mail, star: !mail.isStarred) } } label: { Label("Star", systemImage: "star") } } }
            if visible.isEmpty { Text(MobileL10n.text("暂无邮件")).foregroundStyle(.secondary) }
        }.scrollContentBackground(.hidden).navigationTitle(MobileL10n.text("邮件")).searchable(text: $model.query, prompt: MobileL10n.text("搜索邮件")).onChange(of: model.query) { _, value in model.updateInboxContext(); if !value.isEmpty { model.search() } }.refreshable { await model.sync() }.toolbar { ToolbarItem(placement: .topBarLeading) { Button { var draft = ComposeDraft(); draft.accountID = model.accountID.isEmpty ? model.accounts.first?.id ?? "" : model.accountID; model.compose = draft } label: { Image(systemName: "square.and.pencil") }.accessibilityLabel(MobileL10n.text("草稿")) } }.onAppear { model.updateInboxContext() }
    }
}

struct MobileReader: View {
    @EnvironmentObject var model: MobileModel
    let mailID: String
    @State var analyzing = false
    var mail: MailMessage? { model.mails.first { $0.id == mailID } }
    var body: some View {
        ScrollView { if let mail { VStack(alignment: .leading, spacing: 22) { Text(mail.subject).font(.title2).fontWeight(.semibold).accessibilityIdentifier("mail.subject"); HStack { VStack(alignment: .leading) { Text(mail.from.display).font(.headline); Text(mail.from.email).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text(MobileL10n.text(mail.isRead ? "已读" : "未读")).font(.caption).fontWeight(.semibold) }; if let analysis = mail.analysis { VStack(alignment: .leading, spacing: 10) { Text(analysis.summary).font(.body); if !analysis.reasoning.isEmpty { Text(analysis.reasoning).font(.caption).foregroundStyle(.secondary) }; Text(analysis.source).font(.caption2).foregroundStyle(.secondary) }.padding(16).background(.quaternary, in: RoundedRectangle(cornerRadius: 14)) }; Text(mail.text).textSelection(.enabled).font(.body).lineSpacing(6); ForEach(mail.attachments) { item in NavigationLink(value: MobileRoute.attachment(item.id)) { Label(item.name + " (" + item.size + ")", systemImage: "paperclip") } }; HStack { Button(MobileL10n.text("回复")) { model.compose = model.reply(mail) }.buttonStyle(.borderedProminent).accessibilityIdentifier("mail.reply"); Button(MobileL10n.text(mail.isRead ? "标记未读" : "标记已读")) { Task { await model.mark(mail, read: !mail.isRead) } }.buttonStyle(.bordered) } }.padding(22) } }.navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .topBarTrailing) { Button(MobileL10n.text("分析邮件")) { guard let mail else { return }; analyzing = true; Task { do { var updated = mail; updated.analysis = try await model.partner.analyze(mail, settings: model.settings); _ = try await model.store.upsert(updated); await model.reload() } catch { model.error = error.localizedDescription }; analyzing = false } }.disabled(analyzing) } }.onAppear { if let mail { model.context = .init(page: "mail", label: mail.subject, mailIDs: [mail.id]); model.context?.accountID = mail.accountID } }
    }
}

struct MobilePeople: View {
    @EnvironmentObject var model: MobileModel
    @State var search = ""
    var body: some View {
        List {
            ForEach(model.profiles.filter { search.isEmpty || ($0.email + $0.name).localizedCaseInsensitiveContains(search) }) { profile in
                NavigationLink(value: MobileRoute.contact(profile.email)) {
                    HStack { Image(systemName: "person.crop.circle").font(.title2); VStack(alignment: .leading) { Text(profile.name.isEmpty ? profile.email : profile.name).font(.headline); Text(profile.email).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text("\(profile.mailIDs.count)").font(.caption) }
                }
            }
            if model.profiles.isEmpty { Text(MobileL10n.text("暂无联系人")) }
        }.navigationTitle(MobileL10n.text("联系人")).searchable(text: $search)
            .onAppear { if model.selectedTab == .people && model.peoplePath.isEmpty { model.context = model.pageContext("contacts", label: MobileL10n.text("联系人")) } }
    }
}

struct MobileAttachments: View {
    @EnvironmentObject var model: MobileModel
    @State var search = ""
    var body: some View { List { ForEach(model.attachments.filter { search.isEmpty || $0.attachment.name.localizedCaseInsensitiveContains(search) }) { item in NavigationLink(value: MobileRoute.attachment(item.id)) { VStack(alignment: .leading, spacing: 8) { Label(item.attachment.name, systemImage: "doc").font(.headline); Text(item.mail.from.display + " — " + item.mail.subject).font(.caption).foregroundStyle(.secondary).lineLimit(1); Text(item.attachment.size).font(.caption) } } }; if model.attachments.isEmpty { Text(MobileL10n.text("暂无附件")) } }.navigationTitle(MobileL10n.text("附件")).searchable(text: $search).onAppear { if model.selectedTab == .attachments && model.attachmentsPath.isEmpty { model.context = model.pageContext("attachments", label: MobileL10n.text("附件")) } } }
}

struct MobileAttachmentReader: View {
    @EnvironmentObject var model: MobileModel
    let attachment: MailAttachment; let mail: MailMessage
    @State var text = ""; @State var url: URL?
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 18) { Text(attachment.name).font(.title2).fontWeight(.semibold).accessibilityIdentifier("attachment.title"); Text(text).textSelection(.enabled); if let url { ShareLink(item: url) { Label(MobileL10n.text("保存"), systemImage: "square.and.arrow.up") } }; NavigationLink(MobileL10n.text("来源邮件"), value: MobileRoute.mail(mail.id)) }.padding(22) }.onAppear { var scope = model.mailContext(mail); scope.page = "attachments"; scope.label = attachment.name; scope.attachmentIDs = [attachment.id]; model.context = scope }.task { do { let result = try await AttachmentTextExtractor.shared.extract(attachment, store: model.store); text = result.text.isEmpty ? result.failure ?? "" : result.text; let bytes = try await model.store.attachmentData(attachment); let target = FileManager.default.temporaryDirectory.appendingPathComponent(URL(fileURLWithPath: attachment.name).lastPathComponent); try bytes.write(to: target); url = target } catch { model.error = error.localizedDescription } } }
}
