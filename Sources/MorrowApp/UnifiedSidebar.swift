import SwiftUI
import MorrowCore

struct UnifiedSidebar: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    var simulate: () -> Void
    @State private var renaming: ChatSession?
    @State private var title = ""
    @State private var showArchived = false
    @State private var showingStatus = false
    @State private var showSessionSearch = false
    @State private var sessionQuery = ""
    private var sessions: [ChatSession] { model.orderedChatSessions(archived: showArchived).filter { sessionQuery.isEmpty || $0.title.localizedCaseInsensitiveContains(sessionQuery) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Morrow").font(Theme.wordmark).padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
            VStack(alignment: .leading, spacing: 2) {
                SidebarRow(title: L10n.t("工作"), icon: "square.and.pencil", selected: model.workspacePage == .desk, count: model.pendingDecisions.count, compact: model.compactLayout) { model.openWorkspace(.desk) }
                SidebarRow(title: L10n.t("联系人"), icon: "person.2", selected: model.workspacePage == .people, count: 0, compact: model.compactLayout) { model.openWorkspace(.people) }
                SidebarRow(title: L10n.t("附件"), icon: "paperclip", selected: model.workspacePage == .attachments, count: 0, compact: model.compactLayout) { model.openWorkspace(.attachments) }
                SidebarRow(title: L10n.t("简报"), icon: "doc.text.magnifyingglass", selected: model.workspacePage == .briefs, count: 0, compact: model.compactLayout) { model.openBriefs() }.accessibilityIdentifier("morrow.briefs")
            }.padding(.horizontal, 10)
            sectionHeader(L10n.t("邮件")) { EmptyView() }.padding(.horizontal, 10)
            if !model.accounts.isEmpty {
                Menu {
                    Button(L10n.t("全部邮箱")) { model.chooseMailbox(nil) }
                    ForEach(model.accounts) { account in
                        Button(account.name.isEmpty ? account.email : account.name) { model.chooseMailbox(account.id) }
                    }
                    Divider()
                    ForEach(model.accounts) { account in
                        Menu(account.name.isEmpty ? account.email : account.name) {
                            ForEach(model.folders.filter { $0.accountID == account.id }) { folder in Button(folder.name) { model.chooseFolder(folder) } }
                            Button(L10n.t("同步这个邮箱")) { Task { await model.sync(accountID: account.id, userInitiated: true) } }
                        }
                    }
                } label: {
                    HStack(spacing: 6) { Text(model.accounts.first { $0.id == model.selectedAccount }?.name ?? L10n.t("全部邮箱")).lineLimit(1); Spacer(minLength: 0); Image(systemName: "chevron.down").font(Theme.small) }
                }.font(Theme.label).foregroundStyle(Theme.secondary).menuStyle(.borderlessButton).menuIndicator(.hidden).padding(.horizontal, 20).frame(height: 28).accessibilityIdentifier("morrow.mailbox-picker")
            }
            VStack(alignment: .leading, spacing: 2) {
                SidebarRow(title: L10n.t("收件箱"), icon: "tray", selected: selected(.inbox), count: model.inboxUnreadCount(model.selectedAccount), compact: model.compactLayout) { choose(.inbox) }.accessibilityIdentifier("morrow.inbox")
                SidebarRow(title: L10n.t("已发送"), icon: "paperplane", selected: selected(.sent), count: 0, compact: model.compactLayout) { choose(.sent) }.accessibilityIdentifier("morrow.sent")
                SidebarRow(title: L10n.t("发件箱"), icon: "tray.and.arrow.up", selected: selected(.outbox), count: model.outboxDrafts.count, compact: model.compactLayout) { choose(.outbox) }.accessibilityIdentifier("morrow.outbox")
                SidebarRow(title: L10n.t("草稿箱"), icon: "doc.text", selected: selected(.drafts), count: model.editableDrafts.count, compact: model.compactLayout) { choose(.drafts) }.accessibilityIdentifier("morrow.drafts")
            }.padding(.horizontal, 10)
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader(showArchived ? L10n.t("已归档对话") : L10n.t("对话")) {
                    Button { showSessionSearch.toggle(); if !showSessionSearch { sessionQuery = "" } } label: { Image(systemName: "magnifyingglass") }.buttonStyle(ToolbarIconButtonStyle()).frame(width: 26, height: 26).accessibilityLabel(L10n.t("搜索对话"))
                    Menu { Button(showArchived ? L10n.t("查看当前对话") : L10n.t("查看已归档对话")) { showArchived.toggle() } } label: { Image(systemName: "ellipsis").frame(width: 26, height: 26).contentShape(Rectangle()) }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 32).accessibilityLabel(L10n.t("对话列表管理"))
                    Button { Task { _ = await model.createChatSession() } } label: { Image(systemName: "plus") }.buttonStyle(ToolbarIconButtonStyle()).frame(width: 26, height: 26).accessibilityLabel(L10n.t("新建对话"))
                }
                if showSessionSearch { TextField(L10n.t("搜索对话标题"), text: $sessionQuery).textFieldStyle(.plain).font(Theme.label).padding(8).background(Theme.sheet, in: RoundedRectangle(cornerRadius: Theme.radius)).overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.fieldEdge)).accessibilityLabel(L10n.t("搜索对话标题")) }
                ScrollViewReader { proxy in
                    ScrollView { LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(sessions) { session in
                        SidebarRow(title: session.title, icon: session.id == model.executingSessionID ? "hourglass" : session.isPinned ? "pin.fill" : "bubble.left", selected: session.id == model.activeSessionID, count: 0, compact: model.compactLayout) {
                            if session.archived { Task { await model.archiveChatSession(session.id, archived: false); model.switchChatSession(session.id) } }
                            else { model.switchChatSession(session.id) }
                        }.id(session.id).contextMenu {
                            if !session.archived { Button(L10n.t(session.isPinned ? "取消置顶" : "置顶对话")) { Task { await model.pinChatSession(session.id, pinned: !session.isPinned) } } }
                            Button(L10n.t("重命名")) { title = session.title; renaming = session }
                            Button(session.archived ? L10n.t("恢复对话") : L10n.t("归档对话")) { Task { await model.archiveChatSession(session.id, archived: !session.archived) } }
                        }
                    }
                    } }
                    .onAppear { proxy.scrollTo(model.activeSessionID) }
                    .onChange(of: model.activeSessionID) { showArchived = false; if !sessionQuery.isEmpty && !sessions.contains(where: { $0.id == model.activeSessionID }) { sessionQuery = "" }; proxy.scrollTo(model.activeSessionID) }
                }.frame(maxHeight: .infinity)
            }.padding(.horizontal, 12).frame(minHeight: 80, maxHeight: .infinity)
            HStack(spacing: 10) {
                Menu {
                    Button(L10n.t("工作记录")) { model.openWorkspace(.history) }
                    Button(L10n.t("成果与笔记")) { model.openWorkspace(.library) }
                    Button(L10n.t("自动响应")) { model.openWorkspace(.responders) }
                    Button(L10n.t("伙伴记忆")) { model.openWorkspace(.memory) }
                    Divider()
                    Button(L10n.t("同步与索引状态")) { showingStatus = true }
                    if model.isDemo { Button(L10n.t("加入演示来信")) { simulate() } }
                } label: { Label(L10n.t("管理"), systemImage: "ellipsis.circle").font(Theme.label).foregroundStyle([WorkspacePage.history, .library, .responders, .memory].contains(model.workspacePage) ? Theme.accent2 : Theme.secondary).frame(height: 36) }.menuStyle(.borderlessButton).fixedSize()
                Spacer(minLength: 0)
                Button { model.openSettings() } label: { Image(systemName: "gearshape").font(Theme.actionIcon).foregroundStyle(model.workspacePage == .mail && model.destination == .settings ? Theme.accent2 : Theme.secondary) }.buttonStyle(ToolbarIconButtonStyle()).accessibilityLabel(L10n.t("设置")).help(L10n.t("邮箱、模型与布局设置"))
            }.padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 10)
                .popover(isPresented: $showingStatus) { VStack(alignment: .leading, spacing: 14) { Text(L10n.t("同步与索引")).font(Theme.heading); Text(L10n.status(model.syncStatus)); Text(L10n.status(model.indexStatus)); Text(L10n.status(model.partnerStatus)); Text(L10n.status(model.memoryStatus)) }.font(Theme.label).foregroundStyle(Theme.secondary).padding(22).frame(width: 320) }
        }.frame(width: Theme.sidebarWidth).background(Theme.sidebar)
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MorrowSearchSessions"))) { _ in showArchived = false; showSessionSearch = true; sessionQuery = "" }
        .sheet(item: $renaming) { session in VStack(alignment: .leading, spacing: 18) { Text(L10n.t("重命名对话")).font(Theme.heading); TextField(L10n.t("对话名称"), text: $title).textFieldStyle(PaperFieldStyle()); HStack { Button(L10n.t("取消")) { renaming = nil }.buttonStyle(QuietButtonStyle()); Spacer(); Button(L10n.t("保存")) { Task { await model.renameChatSession(session.id, title: title); renaming = nil } }.buttonStyle(PrimaryButtonStyle()) } }.padding(28).frame(width: 460).background(Theme.paper) }
    }
    private func selected(_ destination: Destination) -> Bool { model.workspacePage == .mail && model.destination == destination && model.selectedFolder == nil }
    private func choose(_ destination: Destination) { let account = model.selectedAccount; model.dismissInlineTools(); model.navigate(destination); model.selectedAccount = account }
    private func sectionHeader<Content: View>(_ title: String, @ViewBuilder controls: () -> Content) -> some View {
        HStack(spacing: 0) { Text(title).font(Theme.label).foregroundStyle(Theme.muted).lineLimit(1); Spacer(minLength: 0); controls() }.padding(.leading, 10).padding(.top, 10).padding(.bottom, 4)
    }
    private func icon(_ page: WorkspacePage) -> String { switch page { case .desk: return "square.and.pencil"; case .mail: return "tray"; case .people: return "person.2"; case .attachments: return "paperclip"; default: return "square" } }
}

private struct SidebarRow: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    var title: String
    var subtitle: String? = nil
    var icon: String
    var selected: Bool
    var count: Int
    var compact = false
    var action: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).frame(width: 20).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Theme.navigation).lineLimit(1)
                    if let subtitle, subtitle != title { Text(subtitle).font(Theme.small).foregroundStyle(Theme.muted).lineLimit(1) }
                }
                Spacer(minLength: 0)
                if count > 0 { Text("\(count)").font(Theme.label.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.secondary) }
            }.foregroundStyle(selected ? Theme.ink : Theme.secondary).padding(.horizontal, 10).padding(.vertical, compact ? 4 : 6)
                .frame(maxWidth: .infinity, minHeight: compact ? 28 : 32, alignment: .leading)
                .background(selected ? Theme.selected : hovered ? Theme.hover : Theme.clear, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(focused ? Theme.focus : Theme.clear, lineWidth: 1.5)).contentShape(Rectangle())
        }.buttonStyle(.plain).focused($focused).onHover { hovered = $0 }.help(subtitle ?? title)
    }
}
