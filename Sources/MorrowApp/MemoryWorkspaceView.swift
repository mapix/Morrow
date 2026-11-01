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
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(L10n.t("伙伴记忆")).font(Theme.title); Spacer(); Button(L10n.t("新建记忆")) { editing = AgentMemory(content: "") }.buttonStyle(CompactButtonStyle()) }
            ViewThatFits(in: .horizontal) { HStack(spacing: 18) { memoryOptions }; VStack(alignment: .leading, spacing: 12) { memoryOptions } }.font(Theme.label)
            if showingReferences { HStack { Text(L10n.t("本次回答引用的记忆")).font(Theme.label).foregroundStyle(Theme.secondary); Spacer(); Button(L10n.t("查看全部记忆")) { model.memoryRevealIDs = []; query = ""; scope = "全部"; status = "all" }.buttonStyle(QuietButtonStyle()) } }
            else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { memorySearch.frame(minWidth: 220); memoryFilters }
                    VStack(alignment: .leading, spacing: 10) { memorySearch; HStack(spacing: 12) { memoryFilters; Spacer(minLength: 0) } }
                }
            }
            if values.isEmpty { EmptyRegion(icon: "brain", title: showingReferences ? L10n.t("这次引用的记忆已不可用") : status == "suggested" ? L10n.t("暂时没有待确认的候选") : L10n.t("把值得记住的事告诉伙伴"), detail: showingReferences ? L10n.t("可查看全部记忆，核对当前保存的内容。") : L10n.t("在Chat中说“记住…”或“更正…”，记忆会保留来源，并用于后续对话。"), action: nil) }
            else { ScrollView { LazyVStack(alignment: .leading, spacing: 0) { ForEach(values) { entry in
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text(L10n.t(entry.kind.rawValue) + " / " + L10n.t(entry.scope.rawValue)).font(Theme.label).foregroundStyle(Theme.secondary); if showingReferences { Text(memoryStatusLabel(entry.status)).font(Theme.label).foregroundStyle(Theme.secondary) }; if let id = entry.scopeID { Text(model.contactProfiles.first { $0.email == id }?.display ?? model.chatSessions.first { $0.id == id }?.title ?? id).font(Theme.label).lineLimit(1) }; Spacer(); Text(entry.updatedAt.uiFormatted()).font(Theme.small).foregroundStyle(Theme.muted) }
                    if let expiry = entry.expiresAt { Text((expiry <= Date() ? L10n.t("已过期：") : L10n.t("有效至：")) + expiry.uiFormatted()).font(Theme.label).foregroundStyle(expiry <= Date() ? Theme.error : Theme.secondary) }
                    Text(entry.content).font(Theme.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    HStack { Text(entry.source + (entry.confirmed ? L10n.t("，已确认") : L10n.t("，待确认"))).font(Theme.label).foregroundStyle(Theme.secondary).lineLimit(2); if entry.useCount > 0 { Text(L10n.format("引用{0}次", "\(entry.useCount)")).font(Theme.label).foregroundStyle(Theme.muted) }; Spacer(); Button(L10n.t("编辑")) { editing = entry }.buttonStyle(CompactButtonStyle()).font(Theme.label); Menu(L10n.t("管理")) {
                        if entry.status == "suggested" { Button(L10n.t("确认使用")) { Task { await model.changeMemoryState(entry.id, status: "active") } } }
                        Button(entry.status == "paused" ? L10n.t("恢复使用") : L10n.t("停用")) { Task { await model.changeMemoryState(entry.id, status: entry.status == "paused" ? "active" : "paused") } }
                        Button(entry.status == "forgotten" ? L10n.t("恢复") : L10n.t("忘记这条")) { Task { await model.changeMemoryState(entry.id, status: entry.status == "forgotten" ? "active" : "forgotten") } }
                    }.menuStyle(.borderlessButton).font(Theme.label) }
                    if !entry.evidence.isEmpty { DisclosureGroup(L10n.t("依据与历史")) { VStack(alignment: .leading, spacing: 8) {
                        Text(entry.evidence).font(Theme.label).foregroundStyle(Theme.secondary).textSelection(.enabled)
                        if let sid = entry.sourceSessionID, let chatID = entry.sourceChatID { Button(model.chatSessions.first { $0.id == sid }?.archived == true ? L10n.t("恢复并查看来源对话") : L10n.t("查看来源对话")) { Task { await model.openSessionSource(sid, chatID: chatID) } }.buttonStyle(.plain).font(Theme.label).foregroundStyle(Theme.accent2) }
                        ForEach(Array(entry.revisions.enumerated()), id: \.offset) { _, revision in Text(revision.content + "\n" + revision.date.uiFormatted()).font(Theme.label).foregroundStyle(Theme.secondary) }
                    }.padding(.top, 10) }.font(Theme.label) }
                }.padding(.vertical, model.compactLayout ? 14 : 22)
                Rectangle().fill(Theme.rule).frame(height: 1)
            } } } }
            HStack { Text(L10n.format("{0}条", "\(values.count)")).font(Theme.label).foregroundStyle(Theme.secondary); Spacer(); Button(L10n.t("导出记忆…")) { model.exportMemories() }.buttonStyle(QuietButtonStyle()) }
        }.padding(model.compactLayout ? 22 : 28).background(Theme.paper).sheet(item: $editing) { entry in MemoryEditor(initial: entry).environmentObject(model) }.onDisappear { model.memoryRevealIDs = [] }
    }
    @ViewBuilder private var memoryOptions: some View {
        Toggle(L10n.t("使用长期记忆"), isOn: $model.workspacePreferences.memoryEnabled).onChange(of: model.workspacePreferences.memoryEnabled) { Task { await model.savePreferences(); model.scheduleMemoryIndex() } }
        Toggle(L10n.t("提取待确认的记忆候选"), isOn: $model.workspacePreferences.autoMemory).onChange(of: model.workspacePreferences.autoMemory) { Task { await model.savePreferences() } }
    }
    private var memorySearch: some View { TextField(L10n.t("搜索记忆内容、来源或范围"), text: $query).textFieldStyle(PaperFieldStyle()) }
    @ViewBuilder private var memoryFilters: some View {
        Picker(L10n.t("状态"), selection: $status) { Text(L10n.t("使用中")).tag("active"); Text(L10n.t("待确认")).tag("suggested"); Text(L10n.t("已停用")).tag("paused"); Text(L10n.t("历史版本")).tag("superseded"); Text(L10n.t("已忘记")).tag("forgotten"); Text(L10n.t("全部")).tag("all") }.frame(width: 150)
        Picker(L10n.t("作用范围"), selection: $scope) { Text(L10n.t("全部")).tag("全部"); ForEach(MemoryScope.allCases, id: \.rawValue) { Text(L10n.t($0.rawValue)).tag($0.rawValue) } }.frame(width: 130)
    }
    private func memoryStatusLabel(_ status: String) -> String { switch status { case "active": return L10n.t("使用中"); case "suggested": return L10n.t("待确认"); case "paused": return L10n.t("已停用"); case "superseded": return L10n.t("历史版本"); case "forgotten": return L10n.t("已忘记"); default: return status } }
}
private struct MemoryEditor: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    let initial: AgentMemory
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var entry: AgentMemory
    @State private var error: String?
    init(initial: AgentMemory) { self.initial = initial; _entry = State(initialValue: initial) }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.t("编辑记忆")).font(Theme.heading)
            TextEditor(text: $entry.content).font(Theme.body).scrollContentBackground(.hidden).padding(10).frame(height: 150).background(Theme.sheet).overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.fieldEdge)).accessibilityLabel(L10n.t("记忆内容"))
            Picker(L10n.t("类型"), selection: $entry.kind) { ForEach(MemoryKind.allCases, id: \.self) { Text(L10n.t($0.rawValue)).tag($0) } }
            Picker(L10n.t("作用范围"), selection: $entry.scope) { ForEach(MemoryScope.allCases, id: \.self) { Text(L10n.t($0.rawValue)).tag($0) } }.onChange(of: entry.scope) { entry.scopeID = entry.scope == .contact ? model.selectedContactEmail : entry.scope == .session ? model.activeSessionID : nil }
            if entry.scope == .contact { Picker(L10n.t("联系人"), selection: Binding(get: { entry.scopeID ?? "" }, set: { entry.scopeID = $0 })) { Text(L10n.t("选择联系人")).tag(""); ForEach(model.contactProfiles) { Text($0.display + " <" + $0.email + ">").tag($0.email) } } }
            if entry.scope == .session { Picker(L10n.t("会话"), selection: Binding(get: { entry.scopeID ?? "" }, set: { entry.scopeID = $0 })) { ForEach(model.chatSessions) { Text($0.title).tag($0.id) } } }
            Toggle(L10n.t("限定有效时间"), isOn: Binding(get: { entry.expiresAt != nil }, set: { entry.expiresAt = $0 ? Date().addingTimeInterval(30 * 86400) : nil }))
            if let expiry = entry.expiresAt { DatePicker(L10n.t("有效至"), selection: Binding(get: { entry.expiresAt ?? expiry }, set: { entry.expiresAt = $0 })).datePickerStyle(.compact) }
            if let error { Text(error).font(Theme.label).foregroundStyle(Theme.error) }
            HStack { Button(L10n.t("取消")) { dismiss() }.buttonStyle(QuietButtonStyle()); Spacer(); Button(initial.status == "suggested" ? L10n.t("保存并确认使用") : L10n.t("保存记忆")) { Task { do { try await model.saveUserEditedMemory(entry); dismiss() } catch { self.error = error.localizedDescription } } }.buttonStyle(PrimaryButtonStyle()).disabled(entry.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(28).frame(width: 600).background(Theme.paper)
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
