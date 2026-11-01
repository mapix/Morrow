import SwiftUI
import MorrowCore

struct RootView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    @State private var command = ""
    @FocusState private var commandFocused: Bool
    @State private var showDemoScenarios = false
    @State private var preferredChatWidth: CGFloat = 400
    @State private var dragOrigin: CGFloat?
    var body: some View {
        HStack(spacing: 0) {
            UnifiedSidebar(simulate: { showDemoScenarios = true })
            GeometryReader { geometry in
                let layout = CompanionPaneLayout.resolve(available: geometry.size.width, preferredChat: preferredChatWidth, expanded: model.chatExpanded)
                HStack(spacing: 0) {
                    workspaceContent.frame(width: layout.workspace, height: geometry.size.height, alignment: .topLeading)
                    if model.chatExpanded {
                        Rectangle().fill(Theme.rule).frame(width: CompanionPaneLayout.divider)
                            .overlay { Color.clear.frame(width: 12).contentShape(Rectangle()).gesture(
                                DragGesture(minimumDistance: 0).onChanged { value in
                                    if dragOrigin == nil { dragOrigin = layout.chat }
                                    let proposed = (dragOrigin ?? layout.chat) - value.translation.width
                                    preferredChatWidth = CompanionPaneLayout.resolve(available: geometry.size.width, preferredChat: proposed, expanded: true).chat
                                }.onEnded { _ in dragOrigin = nil }
                            ) }
                            .accessibilityHidden(true)
                        SidebarChatView().frame(width: layout.chat, height: geometry.size.height)
                    }
                }
            }

        }.font(Theme.body).foregroundStyle(Theme.ink).background(Theme.paper)
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 12) {
                    Button { model.chatExpanded.toggle(); dragOrigin = nil } label: {
                        Image(systemName: "sidebar.right").font(Theme.actionIcon).frame(width: 36, height: 32)
                            .foregroundStyle(Theme.muted).background(Theme.sheet, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
                    }.buttonStyle(.plain).accessibilityIdentifier("morrow-chat-toggle")
                        .accessibilityLabel(model.chatExpanded ? L10n.t("收起对话") : L10n.t("打开伙伴Chat"))
                        .help(model.chatExpanded ? L10n.t("收起对话") : L10n.t("打开伙伴Chat"))
                }.padding(.top, 13).padding(.trailing, 16)
            }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MorrowFocusMission"))) { _ in model.chatExpanded = true; model.chatFocusNonce += 1 }
            .onReceive(NotificationCenter.default.publisher(for: Notification.Name("MorrowFocusSearch"))) { _ in model.workspacePage = .mail; model.navigate(.inbox); model.focusMailSearch = true }
            .sheet(isPresented: $model.showAccount) { AccountSetupView().environmentObject(model) }
            .sheet(isPresented: $model.showDelegation) { DelegationEditor().environmentObject(model) }
            .sheet(item: $model.calendarDraft) { invitation in CalendarEditor(invitation: invitation).environmentObject(model) }
            .sheet(item: $model.responderEditor) { rule in ResponderEditor(initial: rule).environmentObject(model) }
            .sheet(isPresented: $showDemoScenarios) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack { Text(L10n.t("让工作出现新变化")).font(Theme.heading); Spacer(); Button(L10n.t("关闭")) { showDemoScenarios = false }.buttonStyle(QuietButtonStyle()) }
                    Text(L10n.t("选择一封演示来信，查看伙伴如何接着推进原来的工作。所有资料只写入演示邮箱。")).foregroundStyle(Theme.secondary)
                    ForEach([("client", L10n.t("客户回复报价"), L10n.t("客户确认金额，继续询问交付安排。")), ("invoice", L10n.t("财务补充差额说明"), L10n.t("差额200元的原因已到达，重新核对三份依据。")), ("contract", L10n.t("合同验收条款补充"), L10n.t("验收期限从10个工作日改为7个工作日。")), ("meeting", L10n.t("评审材料已到达"), L10n.t("在原评审工作里更新资料和回复。"))], id: \.0) { scenario in
                        Button { showDemoScenarios = false; Task { await model.simulateIncoming(scenario.0) } } label: { VStack(alignment: .leading, spacing: 6) { Text(scenario.1).font(Theme.body.weight(.medium)); Text(scenario.2).font(Theme.label).foregroundStyle(Theme.secondary) }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14) }.buttonStyle(.plain)
                    }
                }.padding(28).frame(width: 560).foregroundStyle(Theme.ink).background(Theme.paper)
            }
            .alert(L10n.t("这一步未完成"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button(L10n.t("知道了")) { model.error = nil } } message: { Text(model.error ?? "") }
    }
    private var activity: CompanionActivity? {
        CompanionActivity.resolve(activeSessionID: model.activeSessionID, executingSessionID: model.executingSessionID,
            sidebarRunning: model.sidebarTask != nil, executingRunIDs: model.executingRunIDs, runs: model.agentRuns)
    }
    private func reveal(_ activity: CompanionActivity) {
        if let sessionID = activity.sessionID { model.switchChatSession(sessionID) }
        else if let runID = activity.runID, let run = model.agentRuns.first(where: { $0.id == runID }) { model.selectRun(run) }
    }
    private var workspaceContent: some View {
        VStack(spacing: 0) {
            if !model.ready { ProgressView(L10n.t("正在打开工作区…")).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let draft = model.composer { ComposerView(inline: true, initial: draft).id(draft.id) }
            else if let preview = model.attachmentTextPreview { AttachmentTextView(inline: true, preview: preview).environmentObject(model) }
            else {
                switch model.workspacePage {
                case .desk: desk
                case .history: AgentHistoryView()
                case .library: AgentLibraryView()
                case .responders: RespondersView()
                case .mail: mailWorkspace
                case .people: PeopleWorkspaceView()
                case .attachments: AttachmentWorkspaceView()
                case .memory: MemoryWorkspaceView()
                }
            }
            footer
        }.padding(.top, model.chatExpanded || hasMailToolbar ? 0 : 40).frame(minWidth: CompanionPaneLayout.minimumWorkspace)
    }
    private var hasMailToolbar: Bool {
        model.workspacePage == .mail && model.composer == nil && model.attachmentTextPreview == nil && ![Destination.settings, .contacts, .drafts, .delegations].contains(model.destination)
    }
    private var navigation: some View {
        VStack(spacing: 12) {
            RailButton(title: L10n.t("交给伙伴"), icon: "plus", selected: false) { model.newChatWork = true; model.workspacePage = .desk; model.selectedRunID = nil; NotificationCenter.default.post(name: Notification.Name("MorrowFocusMission"), object: nil) }
            Rectangle().fill(Theme.rule).frame(width: 28, height: 1).padding(.vertical, 4)
            ForEach(WorkspacePage.allCases) { page in
                RailButton(title: L10n.t(page.rawValue), icon: railIcon(page), selected: model.workspacePage == page) { model.dismissInlineTools(); model.workspacePage = page; if page == .desk { model.selectedRunID = nil }; if page == .mail { model.navigate(.inbox) } }
            }
            Spacer()
            if model.isDemo {
                Text(L10n.t("演示")).font(Theme.small).foregroundStyle(Theme.muted)
                RailButton(title: L10n.t("模拟来信"), icon: "tray.and.arrow.down", selected: false) { showDemoScenarios = true }
            }
            RailButton(title: L10n.t("工作区设置"), icon: "slider.horizontal.3", selected: false) { model.destination = .settings; model.workspacePage = .mail }
        }.padding(.top, 48).padding(.bottom, 18).frame(width: 76).background(Theme.sidebar)
    }
    private func railIcon(_ page: WorkspacePage) -> String { switch page { case .desk: return "square.and.pencil"; case .history: return "clock.arrow.circlepath"; case .library: return "books.vertical"; case .responders: return "bolt.horizontal.circle"; case .mail: return "envelope"; case .people: return "person.2"; case .attachments: return "paperclip"; case .memory: return "brain" } }
    private var desk: some View { WorkHandoffSurface() }
    private var commandBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(Theme.rule).frame(height: 1)
            HStack { Text(model.selectedRun == nil ? L10n.t("交给伙伴一件事") : L10n.t("继续这项委托")).font(Theme.label).foregroundStyle(Theme.muted); Spacer(); if model.partnerBusy { ProgressView().controlSize(.small); Text(L10n.t("正在推进")).font(Theme.label).foregroundStyle(Theme.muted) } }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $command).font(Theme.reader).scrollContentBackground(.hidden).focused($commandFocused).padding(8).frame(height: 70).accessibilityLabel(L10n.t("工作指令"))
                if command.isEmpty { Text(model.selectedRun == nil ? L10n.t("例如：跟进评审邮件，备好回复；核对账单与合同；把资料整理成简报。") : L10n.t("补充要求、追问证据，或让我继续下一步。") ).font(Theme.body).foregroundStyle(Theme.muted).padding(14).allowsHitTesting(false).accessibilityHidden(true) }
            }.background(Theme.sheet).overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(commandFocused ? Theme.focus : Theme.rule, lineWidth: 1))
            HStack {
                Button { model.importFiles() } label: { Label(L10n.t("交给我资料"), systemImage: "paperclip") }.buttonStyle(.plain).font(Theme.label).foregroundStyle(Theme.secondary)
                Spacer(); Text(L10n.t("⌘K 聚焦")).font(Theme.small).foregroundStyle(Theme.muted)
                Button(model.selectedRun == nil ? L10n.t("交给伙伴") : L10n.t("继续推进")) { let text = command; command = ""; Task { await model.workspaceCommand(text) } }.buttonStyle(PrimaryButtonStyle()).disabled(command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.partnerBusy).keyboardShortcut(.return, modifiers: .command)
            }
        }.padding(.horizontal, 24).padding(.bottom, 16)
    }
    @ViewBuilder private var mailWorkspace: some View {
        VStack(spacing: 0) {
            if model.destination == .settings { SettingsView() }
            else if model.destination == .contacts { PeopleWorkspaceView() }
            else if model.destination == .drafts { DraftsView() }
            else if model.destination == .delegations { DelegationsView() }
            else { MailWorkspaceToolbar(reservesCornerControl: !model.chatExpanded); HSplitView { MailListView().frame(minWidth: 240, idealWidth: 290, maxWidth: 360); if let mail = model.selected { ReaderView(mail: mail).frame(minWidth: 330) } else { EmptyRegion(icon: "envelope.open", title: L10n.t("选择一封邮件"), detail: L10n.t("也可以直接在对话里查询当前邮箱。"), action: nil) } } }
        }
    }
    @ViewBuilder private var footer: some View {
        if model.syncBusy { MailSyncStatusLine() }
        if let activity, !(model.chatExpanded && activity.kind == .currentConversation) {
            Button { reveal(activity) } label: {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small).frame(width: 14, height: 14)
                    Text(L10n.t(activity.label)).font(Theme.label.weight(.medium))
                    if !activity.title.isEmpty { Text(activity.title).font(Theme.label).lineLimit(1) }
                    Spacer(minLength: 0)
                }.foregroundStyle(Theme.secondary).padding(.horizontal, 24).frame(height: 32)
            }.buttonStyle(.plain).accessibilityIdentifier("morrow-agent-running")
                .accessibilityLabel(L10n.t(activity.label) + (activity.title.isEmpty ? "" : "：" + activity.title))
        }
        if let label = model.undoLabel {
            HStack { Image(systemName: "arrow.uturn.backward"); Text(label).lineLimit(1); Spacer(); Button(L10n.t("撤销")) { Task { await model.undo() } }.buttonStyle(.plain).foregroundStyle(Theme.accent2) }.font(Theme.label).padding(.horizontal, 24).frame(height: 36).background(Theme.sheet)
        }
    }
}

private struct RailButton: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    var title: String
    var icon: String
    var selected: Bool
    var action: () -> Void
    @FocusState private var focused: Bool
    @State private var hovered = false
    var body: some View {
        Button(action: action) { Image(systemName: icon).font(Theme.actionIcon).frame(width: 44, height: 44).foregroundStyle(selected ? Theme.accent2 : Theme.ink).background(selected || hovered ? Theme.selected : Theme.clear, in: RoundedRectangle(cornerRadius: Theme.radius)).overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(focused ? Theme.focus : Theme.clear, lineWidth: 1.5)) }
            .buttonStyle(.plain).focused($focused).onHover { hovered = $0 }.help(title).accessibilityLabel(title)
    }
}

struct MissionIndexView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    @State private var filter = "all"
    private var runs: [AgentRun] { model.agentRuns.filter { filter == "all" || (filter == "waiting" && $0.phase == .waitingUser) || (filter == "active" && [.queued, .reading, .working, .waitingReply].contains($0.phase)) }.sorted { $0.updatedAt > $1.updatedAt } }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text(L10n.t("交给我的事")).font(Theme.heading); Spacer(); Text("\(model.agentRuns.count)").font(Theme.label).foregroundStyle(Theme.muted) }.padding(24)
            Picker(L10n.t("筛选委托"), selection: $filter) { Text(L10n.t("全部")).tag("all"); Text(L10n.t("等你")).tag("waiting"); Text(L10n.t("推进中")).tag("active") }.pickerStyle(.segmented).padding(.horizontal, 16).padding(.bottom, 16)
            ScrollView {
                VStack(spacing: 0) {
                    Button { model.selectedRunID = nil; model.selectedID = nil } label: { HStack { Image(systemName: "square.grid.2x2"); Text(L10n.t("工作概览")); Spacer() }.font(Theme.label).foregroundStyle(Theme.secondary).padding(16) }.buttonStyle(.plain)
                    ForEach(runs) { run in
                        Button { model.selectRun(run) } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(run.title).font(Theme.body.weight(.medium)).foregroundStyle(Theme.ink).lineLimit(2)
                                Text(run.summary.isEmpty ? run.instruction : run.summary).font(Theme.label).foregroundStyle(Theme.muted).lineLimit(2)
                                HStack { AgentPhaseLabel(phase: run.phase); Spacer(); Text(run.updatedAt.uiFormatted(date: .omitted, time: .shortened)).font(Theme.small).foregroundStyle(Theme.muted) }
                            }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(model.selectedRunID == run.id ? Theme.sidebar : Theme.clear).overlay(alignment: .leading) { if model.selectedRunID == run.id { Rectangle().fill(Theme.accent).frame(width: 2) } }.overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if runs.isEmpty { Text(L10n.t("还没有委托。把邮件里的事交给我，我会保留进度和产出。")).font(Theme.body).foregroundStyle(Theme.muted).padding(20) }
                }
            }
            HStack { Image(systemName: "tray.full"); Text(L10n.format("{0}封邮件作为工作资料", "\(model.mailCount)")).font(Theme.small) }.foregroundStyle(Theme.muted).padding(18)
        }.background(Theme.paper)
    }
}

struct AgentPhaseLabel: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    let phase: AgentPhase
    var body: some View { Label(L10n.t(phase.label), systemImage: icon).font(Theme.label).foregroundStyle(phase == .waitingUser ? Theme.accent2 : phase == .failed ? Theme.error : Theme.secondary) }
    private var icon: String { switch phase { case .completed: return "checkmark"; case .waitingUser: return "hand.raised"; case .waitingReply: return "arrow.turn.down.left"; case .monitoring: return "eye"; case .failed: return "exclamationmark.triangle"; case .paused: return "pause"; case .reading: return "doc.text.magnifyingglass"; case .working: return "arrow.triangle.branch"; case .queued: return "clock" } }
}

struct MissionCanvasView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    let run: AgentRun
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack { AgentPhaseLabel(phase: run.phase); Spacer(); Button { Task { await model.toggleRun(run) } } label: { Image(systemName: run.phase == .paused ? "play" : "pause") }.buttonStyle(IconButtonStyle()).help(run.phase == .paused ? L10n.t("恢复委托") : L10n.t("暂停委托")) }
                VStack(alignment: .leading, spacing: 12) { Text(run.title).font(Theme.title).fixedSize(horizontal: false, vertical: true); Text(run.instruction).font(Theme.reader).foregroundStyle(Theme.secondary).lineSpacing(5); Text(run.summary).font(Theme.body).foregroundStyle(Theme.muted).lineSpacing(4) }
                HStack(spacing: 24) { Label(L10n.format("{0}封来源", "\(run.sourceMailIDs.count)"), systemImage: "envelope"); Label(L10n.format("{0}份产出", "\(run.artifactIDs.count)"), systemImage: "doc.text"); if run.isDemo { Text(L10n.t("演示场景")) } }.font(Theme.label).foregroundStyle(Theme.muted)
                HStack { Text(L10n.t("执行主线")).font(Theme.heading); Spacer(); Text(L10n.t("每一步保留实际操作与依据")).font(Theme.small).foregroundStyle(Theme.muted) }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(run.steps) { step in
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: step.state == .completed ? "checkmark.square" : step.state == .failed ? "exclamationmark.square" : "square").foregroundStyle(step.state == .active ? Theme.accent2 : step.state == .failed ? Theme.error : Theme.muted).frame(width: 20).padding(.top, 2).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 10) {
                                HStack { Text(step.title).font(Theme.body.weight(.medium)); Spacer(); Text(step.tool).font(Theme.label).foregroundStyle(Theme.muted) }
                                Text(step.detail).font(Theme.body).foregroundStyle(Theme.secondary).lineSpacing(5).textSelection(.enabled)
                                HStack { Text(step.date.uiFormatted(date: .omitted, time: .shortened)).font(Theme.small).foregroundStyle(Theme.muted); if !step.sourceMailIDs.isEmpty { Button(L10n.t("查看依据")) { model.inspectorPage = .evidence }.buttonStyle(.plain).font(Theme.label).foregroundStyle(Theme.secondary) } }
                            }
                        }.padding(.vertical, 20).overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) }
                    }
                }
                if run.phase == .waitingReply { Text(L10n.t("我会继续关注后续邮件。收到对方回复后，可以从演示场景或新邮件触发下一步。")).font(Theme.body).foregroundStyle(Theme.muted).lineSpacing(5) }
            }.padding(28)
        }.background(Theme.paper)
    }
}

struct MissionOverviewView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 12) { Text(L10n.t("让事情，持续有进展。")).font(Theme.title); Text(L10n.t("我会从邮件取证，准备下一步，把需要你决定的事带回来。")).font(Theme.reader).foregroundStyle(Theme.secondary).lineSpacing(5) }.padding(.top, 16)
                if !model.pendingDecisions.isEmpty {
                    Text(L10n.t("现在等你决定")).font(Theme.heading)
                    ForEach(model.pendingDecisions) { decision in
                        Button { if let run = model.agentRuns.first(where: { $0.id == decision.runID }) { model.selectRun(run); model.inspectorPage = .decisions } } label: { VStack(alignment: .leading, spacing: 10) { Text(decision.title).font(Theme.body.weight(.medium)); Text(decision.detail).font(Theme.body).foregroundStyle(Theme.muted).lineLimit(2); if let run = model.agentRuns.first(where: { $0.id == decision.runID }) { Text(run.title).font(Theme.label).foregroundStyle(Theme.secondary) } }.padding(.vertical, 20).frame(maxWidth: .infinity, alignment: .leading).overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) } }.buttonStyle(.plain)
                    }
                }
                Text(L10n.t("最近推进的工作")).font(Theme.heading)
                ForEach(model.agentRuns.sorted { $0.updatedAt > $1.updatedAt }.prefix(6)) { run in Button { model.selectRun(run) } label: { HStack(alignment: .top, spacing: 20) { VStack(alignment: .leading, spacing: 10) { Text(run.title).font(Theme.heading); Text(run.summary.isEmpty ? run.instruction : run.summary).font(Theme.body).foregroundStyle(Theme.muted).lineLimit(2) }; Spacer(); AgentPhaseLabel(phase: run.phase) }.padding(.vertical, 20).overlay(alignment: .bottom) { Rectangle().fill(Theme.rule).frame(height: 1) } }.buttonStyle(.plain) }
                if model.agentRuns.isEmpty { Text(L10n.t("从一项具体委托开始：跟进回复、准备邮件、核对资料或整理一份简报。")).font(Theme.body).foregroundStyle(Theme.muted).lineSpacing(5) }
            }.padding(28)
        }
    }
}

struct MailWorkspaceToolbar: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    @FocusState private var focused: Bool
    var reservesCornerControl = false
    private var mailboxTitle: String { model.accounts.first { $0.id == model.selectedAccount }?.name ?? L10n.t("全部邮箱") }
    var body: some View {
        HStack(spacing: 12) {
            Menu {
                Button(L10n.t("全部邮箱")) { model.chooseMailbox(nil) }
                ForEach(model.accounts) { account in Button(account.name.isEmpty ? account.email : account.name) { model.chooseMailbox(account.id) } }
                Divider()
                ForEach(Destination.allCases.filter { ![.partner, .settings, .contacts, .delegations].contains($0) }) { destination in Button(destination.rawValue) { model.navigate(destination) } }
                Divider()
                ForEach(model.accounts) { account in Menu(account.name) { ForEach(model.folders.filter { $0.accountID == account.id }) { folder in Button(folder.name) { model.chooseFolder(folder) } } } }
            } label: { HStack(spacing: 6) { Text(mailboxTitle).lineLimit(1); Image(systemName: "chevron.down").font(Theme.small) } }.font(Theme.body.weight(.medium)).menuStyle(.borderlessButton).menuIndicator(.hidden).frame(maxWidth: 190, alignment: .leading)
            Spacer(minLength: 12)
            HStack { Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted); TextField(model.searchStrategy == .keyword ? L10n.t("按关键词搜索邮件…") : L10n.t("用意思搜索邮件…"), text: $model.searchText).textFieldStyle(.plain).focused($focused).onChange(of: model.searchText) { model.search() }.accessibilityLabel(L10n.t("搜索邮件")); if !model.searchText.isEmpty { Button { model.searchText = ""; model.search() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Theme.muted).accessibilityLabel(L10n.t("清除搜索")) }; if model.searchBusy { ProgressView().controlSize(.small).accessibilityLabel(L10n.t("正在搜索邮件")) } }.font(Theme.body).padding(.horizontal, 10).frame(minWidth: 140, idealWidth: 230, maxWidth: 320, minHeight: 36).background(Theme.sheet, in: RoundedRectangle(cornerRadius: Theme.radius)).overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(focused ? Theme.focus : Theme.fieldEdge))
            Menu {
                Picker(L10n.t("搜索方式"), selection: $model.searchStrategy) { ForEach(MailSearchStrategy.allCases, id: \.self) { Text($0.title).tag($0) } }
                Picker(L10n.t("搜索范围"), selection: $model.searchScope) { ForEach(MailboxSearchScope.allCases) { Text(L10n.t($0.rawValue)).tag($0) } }
            } label: { Text(model.searchStrategy.title).font(Theme.label).foregroundStyle(Theme.accent2) }.menuStyle(.borderlessButton).fixedSize().help(model.searchStrategy.title + L10n.t("搜索；") + L10n.t(model.searchScope.rawValue)).accessibilityLabel(L10n.t("搜索方式与范围"))
            MailSyncButton()
            Button { Task { await model.compose() } } label: { Label(L10n.t("写邮件"), systemImage: "square.and.pencil") }.buttonStyle(CompactButtonStyle())
        }.padding(.horizontal, 24).padding(.trailing, reservesCornerControl ? 44 : 0).frame(height: 58)
        .onSubmit { model.search(preserveSelection: true) }
        .onAppear { if model.focusMailSearch { focused = true; model.focusMailSearch = false } }
        .onChange(of: model.focusMailSearch) { if model.focusMailSearch { focused = true; model.focusMailSearch = false } }
    }
}
