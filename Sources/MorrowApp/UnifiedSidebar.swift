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
            Text("Morrow").font(Theme.wordmark).padding(.horizontal, 22).padding(.top, 48).padding(.bottom, 22)
            VStack(alignment: .leading, spacing: 4) {
                    ForEach([WorkspacePage.desk, .mail, .people, .attachments]) { page in
                        SidebarRow(title: page == .desk ? L10n.t("工作") : L10n.t(page.rawValue), icon: page == .desk && (model.partnerBusy || model.delegationBusy) ? "hourglass" : icon(page), selected: model.workspacePage == page && (page != .mail || (model.selectedAccount == nil && model.destination != .settings)), count: page == .mail ? model.inboxUnreadCount(nil) : page == .desk ? model.pendingDecisions.count : 0, compact: model.compactLayout) { model.openWorkspace(page) }.help(page == .desk && (model.partnerBusy || model.delegationBusy) ? L10n.t("伙伴正在处理委托") : L10n.t(page.rawValue))
                    }
            }.padding(.horizontal, 12)
            if !model.accounts.isEmpty {
                sectionHeader(L10n.t("邮箱")) { Button { model.showAccount = true } label: { Image(systemName: "plus") }.buttonStyle(.plain).frame(width: 28, height: 28).help(L10n.t("添加邮箱")).accessibilityLabel(L10n.t("添加邮箱")) }.padding(.horizontal, 12)
                ScrollView { LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.accounts) { account in
                            SidebarRow(title: account.name.isEmpty ? account.email : account.name, subtitle: account.email, icon: "envelope", selected: model.selectedAccount == account.id && model.workspacePage == .mail && model.destination != .settings, count: model.inboxUnreadCount(account.id), compact: model.compactLayout) { model.chooseMailbox(account.id) }
                                .contextMenu { Button(L10n.t("同步这个邮箱")) { Task { await model.sync(accountID: account.id) } }; Button(L10n.t("邮箱设置")) { model.openSettings() } }
                        }
                } }.frame(height: min(CGFloat(model.accounts.count) * (model.compactLayout ? 52 : 58), 170)).padding(.horizontal, 12)
            }
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader(showArchived ? L10n.t("已归档对话") : L10n.t("对话")) {
                    Button { showSessionSearch.toggle(); if !showSessionSearch { sessionQuery = "" } } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.plain).frame(width: 24, height: 28).accessibilityLabel(L10n.t("搜索对话"))
                    Menu { Button(showArchived ? L10n.t("查看当前对话") : L10n.t("查看已归档对话")) { showArchived.toggle() } } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }.menuStyle(.borderlessButton).frame(width: 24).accessibilityLabel(L10n.t("对话列表管理"))
                    Button { Task { _ = await model.createChatSession() } } label: { Image(systemName: "plus") }.buttonStyle(.plain).frame(width: 24, height: 28).accessibilityLabel(L10n.t("新建对话"))
                }
                if showSessionSearch { TextField(L10n.t("搜索对话标题"), text: $sessionQuery).textFieldStyle(.plain).font(Theme.label).padding(8).background(Theme.sheet, in: RoundedRectangle(cornerRadius: Theme.radius)).overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.fieldEdge)).accessibilityLabel(L10n.t("搜索对话标题")) }
                ScrollViewReader { proxy in
                    ScrollView { LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(sessions) { session in
                        SidebarRow(title: session.title, icon: session.id == model.executingSessionID ? "hourglass" : "bubble.left", selected: session.id == model.activeSessionID, count: 0, compact: model.compactLayout) {
                            if session.archived { Task { await model.archiveChatSession(session.id, archived: false); model.switchChatSession(session.id) } }
                            else { model.switchChatSession(session.id) }
                        }.id(session.id).contextMenu {
                            Button(L10n.t("重命名")) { title = session.title; renaming = session }
                            Button(session.archived ? L10n.t("恢复对话") : L10n.t("归档对话")) { Task { await model.archiveChatSession(session.id, archived: !session.archived) } }.disabled(session.id == model.executingSessionID)
                        }
                    }
                    } }
                    .onAppear { proxy.scrollTo(model.activeSessionID, anchor: .top) }
                    .onChange(of: model.activeSessionID) { showArchived = false; if !sessionQuery.isEmpty && !sessions.contains(where: { $0.id == model.activeSessionID }) { sessionQuery = "" }; proxy.scrollTo(model.activeSessionID, anchor: .top) }
                    .onChange(of: sessions.map(\.id)) { if sessionQuery.isEmpty && !showArchived { proxy.scrollTo(model.activeSessionID, anchor: .top) } }
                }.frame(maxHeight: .infinity)
            }.padding(.horizontal, 12).frame(minHeight: 120, maxHeight: .infinity)
            HStack(spacing: 16) {
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
                Button { model.openSettings() } label: { Label(L10n.t("设置"), systemImage: "gearshape").font(Theme.label).foregroundStyle(model.workspacePage == .mail && model.destination == .settings ? Theme.accent2 : Theme.secondary).frame(height: 36) }.buttonStyle(.plain).help(L10n.t("邮箱、模型与布局设置"))
            }.padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 12)
                .popover(isPresented: $showingStatus) { VStack(alignment: .leading, spacing: 14) { Text(L10n.t("同步与索引")).font(Theme.heading); Text(L10n.status(model.syncStatus)); Text(L10n.status(model.indexStatus)); Text(L10n.status(model.partnerStatus)); Text(L10n.status(model.memoryStatus)) }.font(Theme.label).foregroundStyle(Theme.secondary).padding(22).frame(width: 320) }
        }.frame(width: Theme.sidebarWidth).background(Theme.sidebar)
        .sheet(item: $renaming) { session in VStack(alignment: .leading, spacing: 18) { Text(L10n.t("重命名对话")).font(Theme.heading); TextField(L10n.t("对话名称"), text: $title).textFieldStyle(PaperFieldStyle()); HStack { Button(L10n.t("取消")) { renaming = nil }.buttonStyle(QuietButtonStyle()); Spacer(); Button(L10n.t("保存")) { Task { await model.renameChatSession(session.id, title: title); renaming = nil } }.buttonStyle(PrimaryButtonStyle()) } }.padding(28).frame(width: 460).background(Theme.paper) }
    }
    private func sectionHeader<Content: View>(_ title: String, @ViewBuilder controls: () -> Content) -> some View {
        HStack(spacing: 0) { Text(title).font(Theme.label).foregroundStyle(Theme.muted); Spacer(); controls() }.padding(.leading, 10).padding(.top, 20).padding(.bottom, 4)
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
                    Text(title).font(Theme.navigation).lineLimit(2)
                    if let subtitle, subtitle != title { Text(subtitle).font(Theme.small).foregroundStyle(Theme.muted).lineLimit(1) }
                }
                Spacer(minLength: 0)
                if count > 0 { Text("\(count)").font(Theme.label.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.accent2) }
            }.foregroundStyle(selected ? Theme.ink : Theme.secondary).padding(.horizontal, 10).padding(.vertical, compact ? 7 : 10)
                .frame(maxWidth: .infinity, minHeight: compact ? 36 : 42, alignment: .leading)
                .background(selected || hovered ? Theme.selected : Theme.clear, in: RoundedRectangle(cornerRadius: Theme.radius))
                .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(focused ? Theme.focus : Theme.clear, lineWidth: 1.5)).contentShape(Rectangle())
        }.buttonStyle(.plain).focused($focused).onHover { hovered = $0 }.help(subtitle ?? title)
    }
}
