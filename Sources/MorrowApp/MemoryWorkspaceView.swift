import SwiftUI
import MorrowCore

struct MemoryWorkspaceView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var status = "active"
    @State private var scope = "全部"
    @State private var editing: AgentMemory?
    private var showingReferences: Bool { !model.memoryRevealIDs.isEmpty }
    private var values: [AgentMemory] { showingReferences ? model.revealedMemories : model.memories.filter { (status == "all" || $0.status == status) && (scope == "全部" || $0.scope.rawValue == scope) && (query.isEmpty || ($0.content + $0.source + ($0.scopeID ?? "")).localizedCaseInsensitiveContains(query)) }.sorted { $0.updatedAt > $1.updatedAt } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkspacePageHeader("伙伴记忆", subtitle: "管理已保存的偏好、事实与引用来源。") {
                Button(L10n.t("新建记忆")) { editing = AgentMemory(content: "") }.buttonStyle(PrimaryButtonStyle())
            }
            DisclosureGroup(L10n.t("记忆选项")) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(L10n.t("使用长期记忆"), isOn: $model.workspacePreferences.memoryEnabled).onChange(of: model.workspacePreferences.memoryEnabled) { Task { await model.savePreferences(); model.scheduleMemoryIndex() } }
                    Toggle(L10n.t("提取待确认的记忆候选"), isOn: $model.workspacePreferences.autoMemory).onChange(of: model.workspacePreferences.autoMemory) { Task { await model.savePreferences() } }
                }.font(Theme.label)
            }.font(Theme.label)
            if showingReferences {
                HStack { Text(L10n.t("本次回答引用的记忆")).font(Theme.label).foregroundStyle(Theme.secondary); Spacer(); Button(L10n.t("查看全部记忆")) { model.memoryRevealIDs = []; query = ""; scope = "全部"; status = "all" }.buttonStyle(CompactButtonStyle()) }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { search; filters }
                    VStack(alignment: .leading, spacing: 8) { search; HStack(spacing: 8) { filters; Spacer(minLength: 0) } }
                }
            }
            Divider().overlay(Theme.rule)
            if values.isEmpty {
                EmptyRegion(icon: "brain", title: L10n.t(showingReferences ? "这次引用的记忆已不可用" : query.isEmpty ? "此分类没有记忆" : "没有匹配的记忆"), detail: L10n.t(showingReferences ? "可查看全部记忆，核对当前保存的内容。" : "调整筛选条件，或添加一条需要保留的记忆。"), action: showingReferences ? nil : L10n.t("清除筛选"), perform: { query = ""; scope = "全部"; status = "all" })
            } else {
                ScrollView { LazyVStack(alignment: .leading, spacing: 0) { ForEach(values) { entry in
                    memoryRow(entry)
                    Divider().overlay(Theme.rule)
                } } }
            }
            HStack { Text(L10n.format("{0}条", String(values.count))).font(Theme.label).foregroundStyle(Theme.secondary); Spacer(); Button(L10n.t("导出记忆…")) { model.exportMemories() }.buttonStyle(CompactButtonStyle()) }
        }.padding(24).background(Theme.sheet).sheet(item: $editing) { entry in MemoryEditor(initial: entry).environmentObject(model) }.onDisappear { model.memoryRevealIDs = [] }
    }
    private var search: some View { TextField(L10n.t("搜索记忆内容、来源或范围"), text: $query).textFieldStyle(PaperFieldStyle()) }
    @ViewBuilder private var filters: some View {
        Picker(L10n.t("状态"), selection: $status) { Text(L10n.t("使用中")).tag("active"); Text(L10n.t("待确认")).tag("suggested"); Text(L10n.t("已停用")).tag("paused"); Text(L10n.t("历史版本")).tag("superseded"); Text(L10n.t("已忘记")).tag("forgotten"); Text(L10n.t("全部")).tag("all") }.frame(width: 140)
        Picker(L10n.t("作用范围"), selection: $scope) { Text(L10n.t("全部")).tag("全部"); ForEach(MemoryScope.allCases, id: \.rawValue) { Text(L10n.t($0.rawValue)).tag($0.rawValue) } }.frame(width: 130)
    }
    private func memoryRow(_ entry: AgentMemory) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(L10n.t(entry.kind.rawValue)).font(Theme.label.weight(.medium))
                Text(L10n.t(entry.scope.rawValue)).font(Theme.label).foregroundStyle(Theme.secondary)
                Spacer(minLength: 8)
                Menu {
                    Button(L10n.t("编辑")) { editing = entry }
                    if entry.status == "suggested" { Button(L10n.t("确认使用")) { Task { await model.changeMemoryState(entry.id, status: "active") } } }
                    Button(entry.status == "paused" ? L10n.t("恢复使用") : L10n.t("停用")) { Task { await model.changeMemoryState(entry.id, status: entry.status == "paused" ? "active" : "paused") } }
                    Button(entry.status == "forgotten" ? L10n.t("恢复") : L10n.t("忘记这条")) { Task { await model.changeMemoryState(entry.id, status: entry.status == "forgotten" ? "active" : "forgotten") } }
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }.menuStyle(.borderlessButton).menuIndicator(.hidden).accessibilityLabel(L10n.t("管理记忆"))
            }
            HStack(spacing: 12) {
                Text(statusLabel(entry.status)).font(Theme.label).foregroundStyle(entry.status == "suggested" ? Theme.accent2 : Theme.secondary)
                Text(L10n.t(entry.confirmed ? "已确认" : "待确认")).font(Theme.small).foregroundStyle(Theme.muted)
            }
            if let id = entry.scopeID { Text(model.cachedSession(id)?.title ?? id).font(Theme.small).foregroundStyle(Theme.secondary).lineLimit(1) }
            Text(entry.content).font(Theme.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) { sourceMetadata(entry) }
                VStack(alignment: .leading, spacing: 4) { sourceMetadata(entry) }
            }.font(Theme.small).foregroundStyle(Theme.muted)
            if let expiry = entry.expiresAt { Text(L10n.t(expiry <= Date() ? "已过期：" : "有效至：") + expiry.uiFormatted()).font(Theme.small).foregroundStyle(expiry <= Date() ? Theme.error : Theme.secondary) }
            if !entry.evidence.isEmpty {
                DisclosureGroup(L10n.t("依据与历史")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.evidence).font(Theme.label).foregroundStyle(Theme.secondary).textSelection(.enabled)
                        if let sid = entry.sourceSessionID, let chatID = entry.sourceChatID { Button(model.cachedSession(sid)?.archived == true ? L10n.t("恢复并查看来源对话") : L10n.t("查看来源对话")) { Task { await model.openSessionSource(sid, chatID: chatID) } }.buttonStyle(ReferenceRowButtonStyle()).font(Theme.label) }
                        ForEach(Array(entry.revisions.enumerated()), id: \.offset) { _, revision in VStack(alignment: .leading, spacing: 4) { Text(revision.content).textSelection(.enabled); Text(revision.date.uiFormatted()).foregroundStyle(Theme.muted) }.font(Theme.label) }
                    }
                }.font(Theme.label)
            }
        }.padding(.vertical, 12).accessibilityIdentifier("memory.entry")
    }
    @ViewBuilder private func sourceMetadata(_ entry: AgentMemory) -> some View {
        Text(entry.source).lineLimit(1)
        Text(entry.updatedAt.uiFormatted(date: .abbreviated, time: .shortened))
        if entry.useCount > 0 { Text(L10n.format("引用{0}次", String(entry.useCount))).monospacedDigit() }
    }
    private func statusLabel(_ status: String) -> String { switch status { case "active": return L10n.t("使用中"); case "suggested": return L10n.t("待确认"); case "paused": return L10n.t("已停用"); case "superseded": return L10n.t("历史版本"); case "forgotten": return L10n.t("已忘记"); default: return status } }
}

struct MemoryEditor: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    let initial: AgentMemory
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var entry: AgentMemory
    @State private var error: String?
    @State private var saving = false
    init(initial: AgentMemory) { self.initial = initial; _entry = State(initialValue: initial) }
    private var valid: Bool { !entry.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (entry.scope != .contact || MailAddress.isValid(entry.scopeID ?? "")) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(L10n.t("编辑记忆")).font(Theme.title); Spacer(); Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(ToolbarIconButtonStyle()).disabled(saving).accessibilityLabel(L10n.t("关闭")) }
            ScrollView { VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) { Text(L10n.t("记忆内容")).font(Theme.label).foregroundStyle(Theme.secondary); TextEditor(text: $entry.content).font(Theme.body).scrollContentBackground(.hidden).padding(8).frame(height: 130).background(Theme.sheet).overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).stroke(Theme.fieldEdge)).accessibilityLabel(L10n.t("记忆内容")) }
                Picker(L10n.t("类型"), selection: $entry.kind) { ForEach(MemoryKind.allCases, id: \.self) { Text(L10n.t($0.rawValue)).tag($0) } }
                Picker(L10n.t("作用范围"), selection: $entry.scope) { ForEach(MemoryScope.allCases, id: \.self) { Text(L10n.t($0.rawValue)).tag($0) } }.onChange(of: entry.scope) { entry.scopeID = entry.scope == .contact ? model.selectedContactEmail : entry.scope == .session ? model.activeSessionID : nil }
                if entry.scope == .contact {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.t("联系人邮箱")).font(Theme.label).foregroundStyle(Theme.secondary)
                        TextField("name@example.com", text: Binding(get: { entry.scopeID ?? "" }, set: { entry.scopeID = $0 })).textFieldStyle(PaperFieldStyle()).accessibilityLabel(L10n.t("联系人邮箱"))
                        if let email = model.selectedContactEmail { Button(L10n.t("使用当前联系人")) { entry.scopeID = email }.buttonStyle(CompactButtonStyle()) }
                    }
                }
                if entry.scope == .session { Picker(L10n.t("会话"), selection: Binding(get: { entry.scopeID ?? "" }, set: { entry.scopeID = $0 })) { ForEach(model.chatSessions) { Text($0.title).tag($0.id) } } }
                Toggle(L10n.t("限定有效时间"), isOn: Binding(get: { entry.expiresAt != nil }, set: { entry.expiresAt = $0 ? Date().addingTimeInterval(30 * 86400) : nil }))
                if let expiry = entry.expiresAt { DatePicker(L10n.t("有效至"), selection: Binding(get: { entry.expiresAt ?? expiry }, set: { entry.expiresAt = $0 })).datePickerStyle(.compact) }
            }.disabled(saving) }.frame(maxHeight: 360)
            if let error { Text(error).font(Theme.label).foregroundStyle(Theme.error).textSelection(.enabled) }
            Divider().overlay(Theme.rule)
            HStack {
                Button(L10n.t("取消")) { dismiss() }.buttonStyle(CompactButtonStyle()).disabled(saving).keyboardShortcut(.cancelAction)
                Spacer()
                Button(saving ? L10n.t("保存中…") : initial.status == "suggested" ? L10n.t("保存并确认使用") : L10n.t("保存记忆")) {
                    saving = true; Task { defer { saving = false }; do { try await model.saveUserEditedMemory(entry); dismiss() } catch { self.error = error.localizedDescription } }
                }.buttonStyle(PrimaryButtonStyle()).disabled(!valid || saving).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(minWidth: 400, idealWidth: 560, maxWidth: 640).background(Theme.paper)
    }
}

extension AppModel {
    var revealedMemories: [AgentMemory] { memoryRevealIDs.compactMap { id in memories.first { $0.id == id } } }
    func revealMemories(_ ids: [String]) { var seen = Set<String>(); memoryRevealIDs = ids.filter { seen.insert($0).inserted }; dismissInlineTools(); workspacePage = .memory }
    func saveUserEditedMemory(_ value: AgentMemory) async throws {
        var entry = value; entry.confirmed = true; entry.source = "用户编辑"
        if entry.status == "suggested" { entry.status = "active" }
        try await saveMemory(entry)
    }
}
