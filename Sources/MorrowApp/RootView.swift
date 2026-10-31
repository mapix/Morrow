import SwiftUI
import MorrowCore

struct LegacyRootView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    @FocusState private var searchFocused: Bool
    var body: some View {
        HSplitView {
            SidebarView().frame(minWidth: 190, idealWidth: 216, maxWidth: 250)
            VStack(spacing: 0) {
                topbar
                Divider().overlay(Theme.rule)
                content
                statusbar
            }.frame(minWidth: 820).background(Theme.paper)
        }.font(Theme.body).foregroundStyle(Theme.ink).background(Theme.paper)
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MorrowFocusSearch"))) { _ in searchFocused = true }
            .sheet(item: $model.composer) { draft in ComposerView(initial: draft).environmentObject(model) }
            .sheet(isPresented: $model.showAccount) { AccountSetupView().environmentObject(model) }
            .sheet(isPresented: $model.showDelegation) { DelegationEditor().environmentObject(model) }
            .sheet(item: $model.calendarDraft) { invitation in CalendarEditor(invitation: invitation).environmentObject(model) }
            .sheet(item: $model.attachmentTextPreview) { preview in AttachmentTextView(preview: preview) }
            .alert(L10n.t("操作未完成"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button(L10n.t("知道了")) { model.error = nil } } message: { Text(model.error ?? "") }
    }
    private var topbar: some View {
        HStack(spacing: 16) {
            Text(L10n.t(model.destination.rawValue)).font(Theme.heading)
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted).accessibilityHidden(true)
                TextField("", text: $model.searchText, prompt: Text(L10n.t("搜索邮件，或描述你记得的内容")).foregroundStyle(Theme.muted)).textFieldStyle(.plain).focused($searchFocused).onChange(of: model.searchText) { model.search() }.onSubmit { model.search() }.accessibilityLabel(L10n.t("搜索邮件"))
                if !model.searchText.isEmpty { Button { model.searchText = ""; model.searchMode = false } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help(L10n.t("清除搜索")) }
                if model.searchBusy { ProgressView().controlSize(.small) }
            }.padding(.horizontal, 12).frame(width: 320, height: 34).background(Theme.sheet, in: RoundedRectangle(cornerRadius: Theme.radius)).overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(searchFocused ? Theme.focus : Theme.muted, lineWidth: 1))
            Button { Task { await model.sync() } } label: { if model.syncBusy { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") } }.buttonStyle(.borderless).frame(width: 32, height: 34).disabled(model.syncBusy).help(L10n.t("同步邮箱 (⌘R)"))
            Button { Task { await model.compose() } } label: { Label(L10n.t("写邮件"), systemImage: "square.and.pencil") }.buttonStyle(PrimaryButtonStyle()).help(L10n.t("写邮件 (⌘N)"))
        }.padding(.horizontal, 24).frame(height: 64)
    }
    @ViewBuilder private var content: some View {
        if !model.ready { VStack(spacing: 16) { ProgressView(); Text(L10n.t("正在打开邮件工作区…")).font(Theme.body).foregroundStyle(Theme.muted) }.frame(maxWidth: .infinity, maxHeight: .infinity) }
        else if model.searchMode { mailWorkspace }
        else {
            switch model.destination {
            case .partner: partnerWorkspace
            case .delegations: DelegationsView()
            case .drafts: DraftsView()
            case .settings: SettingsView()
            case .contacts: ContactsView()
            default: mailWorkspace
            }
        }
    }
    private var partnerWorkspace: some View {
        HSplitView {
            PartnerHome().frame(minWidth: 360, idealWidth: 570)
            if let selected = model.selected { ReaderView(mail: selected).id(selected.id).frame(minWidth: 380, idealWidth: 520) }
            else { PartnerConversation().frame(minWidth: 360, idealWidth: 470) }
        }
    }
    private var mailWorkspace: some View {
        HSplitView {
            MailListView().frame(minWidth: 310, idealWidth: 370, maxWidth: 480)
            if let selected = model.selected { ReaderView(mail: selected).id(selected.id).frame(minWidth: 420) }
            else { EmptyRegion(icon: "envelope.open", title: L10n.t("选择一封邮件"), detail: L10n.t("原文、事项和回复建议会在这里展开。"), action: nil).frame(minWidth: 400) }
        }
    }
    private var statusbar: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.rule)
            HStack(spacing: 12) {
                if model.isDemo { Label(L10n.t("示例工作区"), systemImage: "rectangle.dashed").foregroundStyle(Theme.muted) }
                Text(L10n.status(model.syncStatus)).lineLimit(1).help(L10n.status(model.syncStatus))
                Spacer()
                if let label = model.undoLabel { Button(L10n.format("撤销{0}", "\(label)")) { Task { await model.undo() } }.buttonStyle(.link) }
                Text(L10n.status(model.indexStatus)).lineLimit(1).help(L10n.status(model.indexStatus))
            }.font(Theme.small).foregroundStyle(Theme.muted).padding(.horizontal, 20).frame(height: 32)
        }
    }
}

struct SidebarView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Morrow").font(Theme.wordmark); Spacer(); Image(systemName: "envelope.open").font(Theme.heading).foregroundStyle(Theme.secondary).accessibilityHidden(true) }.padding(24).padding(.top, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Destination.allCases.filter { $0 != .settings }) { destination in
                        Button { model.navigate(destination) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: destination.icon).frame(width: 18).accessibilityHidden(true)
                                Text(L10n.t(destination.rawValue)); Spacer()
                                if let count = count(destination), count > 0 { Text("\(count)").font(Theme.label).monospacedDigit().foregroundStyle(Theme.muted) }
                            }.padding(.horizontal, 12).frame(height: 38).background(model.destination == destination && model.selectedAccount == nil ? Theme.selected : Theme.clear, in: RoundedRectangle(cornerRadius: Theme.radius)).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(L10n.t(destination.rawValue))
                    }
                    Divider().overlay(Theme.rule).padding(.vertical, 16)
                    HStack { Text(L10n.t("邮箱")).font(Theme.label).foregroundStyle(Theme.muted); Spacer(); Button { model.suggestedAccount = ""; model.showAccount = true } label: { Image(systemName: "plus") }.buttonStyle(.plain).help(L10n.t("添加邮箱")) }.padding(.horizontal, 12).padding(.bottom, 8)
                    ForEach(model.accounts) { a in
                        DisclosureGroup {
                            ForEach(model.folders.filter { $0.accountID == a.id }) { folder in
                                Button { model.destination = .inbox; model.selectedAccount = a.id; model.selectedFolder = folder.path; model.selectedID = nil; model.searchMode = false } label: {
                                    HStack { Text(folder.name).lineLimit(1); Spacer() }.font(Theme.label).padding(.vertical, 6).padding(.leading, 16).background(model.selectedAccount == a.id && model.selectedFolder == folder.path ? Theme.selected : Theme.clear, in: RoundedRectangle(cornerRadius: Theme.radius))
                                }.buttonStyle(.plain)
                            }
                        } label: { Text(a.name.isEmpty ? a.email : a.name).font(Theme.label).lineLimit(1).help(a.email) }.padding(.horizontal, 12).padding(.vertical, 5)
                    }
                }.padding(.horizontal, 12)
            }
            Button { model.navigate(.settings) } label: { Label(L10n.t("设置"), systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading).padding(20) }.buttonStyle(.plain)
        }.background(Theme.sidebar).foregroundStyle(Theme.ink)
    }
    private func count(_ d: Destination) -> Int? { switch d { case .inbox: return model.mails.filter { !$0.isRead && $0.folder == "INBOX" }.count; case .focus: return model.actionCount; case .drafts: return model.drafts.filter { $0.state != "sent" }.count; case .delegations: return model.delegations.filter(\.active).count; default: return nil } }
}

struct PartnerHome: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.t("把来信，变成进展。")).font(Theme.title)
                    Text(model.mails.isEmpty ? L10n.t("连接邮箱，或先用示例体验你的邮件伙伴。") : model.partnerStatus).font(Theme.body).foregroundStyle(Theme.muted).lineLimit(2)
                }.padding(.top, 12)
                if model.accounts.isEmpty {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(L10n.t("我会读每封新邮件，找出需要推进的事。你也可以交给我一项持续的委托。")).font(Theme.reader).lineSpacing(5)
                        HStack { Button(L10n.t("连接邮箱")) { model.showAccount = true }.buttonStyle(PrimaryButtonStyle()); Button(L10n.t("体验示例")) { Task { await model.loadDemo() } }.buttonStyle(QuietButtonStyle()) }
                        Button(L10n.t("导入邮件或资料")) { model.importFiles() }.buttonStyle(.link)
                    }.padding(.vertical, 24)
                } else {
                    HStack { Text(L10n.t("现在需要推进")).font(Theme.heading); Spacer(); Text(L10n.format("{0} 件", "\(model.visibleMails.count)")).font(Theme.label).foregroundStyle(Theme.muted) }
                    VStack(spacing: 0) {
                        Divider().overlay(Theme.ink)
                        if model.visibleMails.isEmpty { Text(L10n.t("目前没有未完成的事项。新邮件进来后，我会继续整理。")).foregroundStyle(Theme.muted).padding(.vertical, 24).frame(maxWidth: .infinity, alignment: .leading) }
                        ForEach(model.visibleMails.prefix(12)) { mail in ActionRow(mail: mail) }
                    }
                }
                HStack { Text(L10n.t("交给我的事")).font(Theme.heading); Spacer(); Button { model.showDelegation = true } label: { Label(L10n.t("新委托"), systemImage: "plus") }.buttonStyle(.link) }
                VStack(spacing: 0) {
                    Divider().overlay(Theme.rule)
                    if model.delegations.isEmpty { Text(L10n.t("例如：跟进项目评审，收到回复就告诉我；每天整理待回复的邮件。")).font(Theme.body).foregroundStyle(Theme.muted).lineSpacing(5).padding(.vertical, 20).frame(maxWidth: .infinity, alignment: .leading) }
                    ForEach(model.delegations.prefix(4)) { d in
                        Button { model.navigate(.delegations) } label: { VStack(alignment: .leading, spacing: 8) { HStack { Text(d.title).font(Theme.body.weight(.medium)); Spacer(); Text(d.active ? L10n.t("进行中") : L10n.t("暂停")).font(Theme.label).foregroundStyle(Theme.muted) }; Text(d.status).font(Theme.label).foregroundStyle(Theme.muted).lineLimit(2) }.padding(.vertical, 16).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain)
                        Divider().overlay(Theme.rule)
                    }
                }
                HStack { Text(L10n.t("最近的进展")).font(Theme.heading); Spacer() }
                VStack(alignment: .leading, spacing: 20) {
                    if model.events.isEmpty { Text(L10n.t("每次整理、起草和委托执行都会留下记录。")).font(Theme.body).foregroundStyle(Theme.muted) }
                    ForEach(model.events.suffix(6).reversed()) { event in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text(event.title).font(Theme.body.weight(.medium)); Spacer(); Text(event.date.uiFormatted(date: .omitted, time: .shortened)).font(Theme.label).foregroundStyle(Theme.muted) }
                            Text(event.detail).font(Theme.label).foregroundStyle(Theme.muted).lineLimit(3).textSelection(.enabled)
                            if let id = event.messageIDs.first, let mail = model.mails.first(where: { $0.id == id }) { Button(L10n.t("查看原邮件")) { model.select(mail) }.buttonStyle(.link).font(Theme.label) }
                        }
                    }
                }
            }.padding(28)
        }.background(Theme.paper)
    }
}

struct ActionRow: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    var mail: MailMessage
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { Task { await model.complete(mail) } } label: { Image(systemName: mail.actionDone ? "checkmark.circle.fill" : "circle").font(Theme.actionIcon).foregroundStyle(mail.actionDone ? Theme.green : Theme.muted) }.buttonStyle(.plain).help(L10n.t("标记事项完成")).accessibilityLabel(mail.actionDone ? L10n.t("重新打开事项") : L10n.t("完成事项")).accessibilityValue(mail.actionDone ? L10n.t("已完成") : L10n.t("未完成")).padding(.top, 2)
            Button { model.select(mail) } label: {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .top) { Text(mail.analysis?.action ?? mail.subject).font(Theme.body.weight(.medium)).lineLimit(2); Spacer(minLength: 4); if (mail.analysis?.priority ?? 0) == 2 { Text(L10n.t("优先处理")).font(Theme.small).foregroundStyle(Theme.error) } }
                    Text(mail.analysis?.summary ?? mail.preview).font(Theme.label).foregroundStyle(Theme.muted).lineLimit(2)
                    HStack(spacing: 12) { Text(mail.from.display); if mail.analysis?.needsReply == true { Text(L10n.t("在等你的回复")) }; if let due = mail.analysis?.deadline { Text(due.uiFormatted(date: .abbreviated, time: .shortened)).foregroundStyle(Theme.error) } }.font(Theme.small).foregroundStyle(Theme.muted)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }.padding(.vertical, 18).padding(.horizontal, 8).background(model.selectedID == mail.id ? Theme.selected : Theme.clear).overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
    }
}

struct MailListView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    @State private var selecting = false
    @State private var selectedIDs = Set<String>()
    @State private var label = ""
    var body: some View {
        let page = model.mailPageWindow
        let pageMails = model.pagedMails
        let pageIdentity = [String(page.index), String(page.size), model.selectedAccount ?? "", model.selectedFolder ?? "", model.destination.rawValue, model.searchText, String(model.unreadOnly), model.category?.rawValue ?? ""]
        VStack(spacing: 0) {
            HStack {
                Text(model.searchMode ? L10n.t("检索结果") : model.selectedFolder.flatMap { path in model.folders.first { $0.path == path }?.name } ?? L10n.t(model.destination.rawValue)).font(Theme.heading)
                Spacer()
                Button(selecting ? L10n.t("结束选择") : L10n.t("选择")) { selecting.toggle(); selectedIDs = [] }.buttonStyle(.link).font(Theme.label).disabled(model.batchBusy)
                Menu { Toggle(L10n.t("只看未读"), isOn: $model.unreadOnly); Button(L10n.t("所有分类")) { model.category = nil }; ForEach(MailCategory.allCases, id: \.self) { category in Button(category.rawValue) { model.category = category } } } label: { Image(systemName: "line.3.horizontal.decrease") }.menuStyle(.borderlessButton).frame(width: 24).help(L10n.t("筛选邮件"))
            }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 12)
            HStack(spacing: 10) {
                Button(L10n.t("全部已读")) { Task { await model.markAllReadInCurrentList() } }
                    .buttonStyle(.plain).foregroundStyle(Theme.accent2).font(Theme.label)
                    .disabled(model.batchBusy || (page.total == 0 && !model.canMarkWholeFolderRead))
                    .help(L10n.t("将当前列表跨页的未读邮件全部标为已读"))
                    .accessibilityIdentifier("mail.mark-all-read")
                Spacer(minLength: 0)
                Menu { ForEach([25, 50, 100], id: \.self) { size in Button(L10n.format("每页 {0} 封", "\(size)")) { model.setMailPageSize(size) } } } label: {
                    Text(page.total == 0 ? "0 / 0" : "\(page.start + 1)–\(page.end) / \(page.total.formatted())").monospacedDigit().font(Theme.small)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden).foregroundStyle(Theme.secondary).help(L10n.t("每页邮件数量"))
                Button { model.turnMailPage(-1) } label: { Image(systemName: "chevron.left").frame(width: 20, height: 24) }
                    .buttonStyle(.plain).disabled(!page.hasPrevious || model.batchBusy).help(L10n.t("上一页")).accessibilityLabel(L10n.t("上一页")).accessibilityIdentifier("mail.pagination.previous")
                Button { model.turnMailPage(1) } label: { Image(systemName: "chevron.right").frame(width: 20, height: 24) }
                    .buttonStyle(.plain).disabled(!page.hasNext || model.batchBusy).help(L10n.t("下一页")).accessibilityLabel(L10n.t("下一页")).accessibilityIdentifier("mail.pagination.next")
            }.padding(.horizontal, 20).padding(.bottom, 12)
            if model.searchMode { Text(model.searchStatus).font(Theme.small).foregroundStyle(model.searchFallback ? Theme.error : Theme.muted).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 12) }
            Divider().overlay(Theme.rule)
            if model.searchBusy && model.visibleMails.isEmpty { VStack(spacing: 12) { ProgressView(); Text(L10n.t("正在按") + model.searchStrategy.title + L10n.t("查找…")).font(Theme.label).foregroundStyle(Theme.muted) }.frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if model.visibleMails.isEmpty { EmptyRegion(icon: "tray", title: model.searchMode ? L10n.t("没有找到匹配邮件") : L10n.t("这里还没有邮件"), detail: model.searchMode ? L10n.t("试试主题、发件人，或换一种描述。") : L10n.t("连接邮箱、同步，或导入邮件。"), action: model.accounts.isEmpty ? L10n.t("连接邮箱") : L10n.t("同步"), perform: { if model.accounts.isEmpty { model.showAccount = true } else { Task { await model.sync() } } }) }
            else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                        ForEach(pageMails) { mail in
                            HStack(spacing: 0) {
                                if selecting { Button { if selectedIDs.contains(mail.id) { selectedIDs.remove(mail.id) } else { selectedIDs.insert(mail.id) } } label: { Image(systemName: selectedIDs.contains(mail.id) ? "checkmark.square.fill" : "square").foregroundStyle(Theme.ink) }.buttonStyle(IconButtonStyle()).accessibilityLabel(L10n.t("选择") + mail.subject) }
                                Button { model.select(mail) } label: { MailRow(mail: mail) }.buttonStyle(.plain)
                            }.id(mail.id)
                                .contextMenu { Button(mail.isRead ? L10n.t("标记未读") : L10n.t("标记已读")) { Task { await model.markRead(mail, !mail.isRead) } }; Button(mail.isStarred ? L10n.t("取消星标") : L10n.t("添加星标")) { Task { await model.star(mail) } }; Button(L10n.t("归档")) { Task { await model.move(mail, role: "archive") } }; Button(L10n.t("移到废纸篓")) { Task { await model.move(mail, role: "trash") } } }
                        }
                        }
                    }.id(pageIdentity).focusable().focusEffectDisabled().onAppear { if let id = model.selectedID, pageMails.contains(where: { $0.id == id }) { proxy.scrollTo(id) } }.onKeyPress(.upArrow) { moveSelection(-1); return .handled }.onKeyPress(.downArrow) { moveSelection(1); return .handled }.onChange(of: model.selectedID) { model.revealSelectedMailPage(); if let id = model.selectedID { proxy.scrollTo(id) } }
                }
            }
            if selecting {
                Divider().overlay(Theme.rule)
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(L10n.format("已选{0}封", "\(selectedIDs.count)")).font(Theme.label); Spacer(); Button(L10n.t("全选本页")) { selectedIDs = Set(pageMails.map(\.id)) }.buttonStyle(.link).accessibilityIdentifier("mail.select-page"); Button(L10n.t("清除")) { selectedIDs = [] }.buttonStyle(.link) }
                    HStack {
                        Menu(L10n.t("标记")) { Button(L10n.t("已读")) { run(.read(true)) }; Button(L10n.t("未读")) { run(.read(false)) }; Button(L10n.t("星标")) { run(.star(true)) }; Button(L10n.t("取消星标")) { run(.star(false)) } }.menuStyle(.borderlessButton)
                        Button(L10n.t("归档")) { run(.move("archive")) }.buttonStyle(QuietButtonStyle())
                        Button(L10n.t("废纸篓")) { run(.move("trash")) }.buttonStyle(QuietButtonStyle())
                    }.disabled(selectedIDs.isEmpty || model.batchBusy)
                    HStack { TextField(L10n.t("标签"), text: $label).textFieldStyle(PaperFieldStyle()); Button(L10n.t("添加")) { run(.label(label)) }.buttonStyle(.link).disabled(selectedIDs.isEmpty || model.batchBusy) }
                }.padding(16)
            }
            if let status = model.batchStatus { HStack(spacing: 8) { if model.batchBusy { ProgressView().controlSize(.small) }; Text(status).font(Theme.small).lineLimit(2); Spacer(minLength: 0) }.foregroundStyle(Theme.secondary).padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Theme.sheet).accessibilityIdentifier("mail.batch.status") }
        }.background(Theme.paper)
            .onChange(of: model.pagedMails.map(\.id)) { selectedIDs.formIntersection(Set(model.pagedMails.map(\.id))) }
    }
    private func run(_ action: BatchMailAction) { let ids = selectedIDs; Task { await model.batch(ids, action: action) } }
    private func moveSelection(_ offset: Int) {
        let mails = model.pagedMails; guard !mails.isEmpty else { return }
        let current = mails.firstIndex { $0.id == model.selectedID } ?? (offset > 0 ? -1 : mails.count)
        model.select(mails[max(0, min(mails.count - 1, current + offset))])
    }
}

struct MailRow: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    var mail: MailMessage
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { MailReadState(read: mail.isRead); Text(mail.from.display).font(Theme.body.weight(mail.isRead ? .regular : .semibold)).lineLimit(1); Spacer(); if mail.isStarred { Image(systemName: "star.fill").font(Theme.small).foregroundStyle(Theme.secondary) }; Text(mail.date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute())).font(Theme.small).foregroundStyle(Theme.muted) }
            Text(mail.subject).font(Theme.body.weight(mail.isRead ? .regular : .semibold)).lineLimit(2)
            Text(mail.analysis?.summary ?? mail.preview).font(Theme.label).foregroundStyle(Theme.muted).lineLimit(2)
            HStack(spacing: 12) {
                if let account = model.accounts.first(where: { $0.id == mail.accountID }), model.accounts.count > 1 { Text(account.name).foregroundStyle(Theme.secondary) }
                if let analysis = mail.analysis { Text(L10n.t(analysis.category.rawValue)); if analysis.needsReply && !mail.actionDone { Text(L10n.t("待回复")).foregroundStyle(Theme.error) } }
                if !mail.attachments.isEmpty { Label("\(mail.attachments.count)", systemImage: "paperclip") }
                ForEach(mail.labels.prefix(2), id: \.self) { Text($0) }
            }.font(Theme.small).foregroundStyle(Theme.muted)
        }.padding(model.compactLayout ? 10 : 18).frame(maxWidth: .infinity, alignment: .leading).background(model.selectedID == mail.id ? Theme.selected : mail.isRead ? Theme.clear : Theme.unreadPaper.opacity(0.35)).overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }.contentShape(Rectangle()).overlay(alignment: .leading) { if !mail.isRead { Rectangle().fill(Theme.accent2).frame(width: 3) } }.accessibilityElement(children: .combine).accessibilityValue(mail.isRead ? L10n.t("已读") : L10n.t("未读"))
    }
}
