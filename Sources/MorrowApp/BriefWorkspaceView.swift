import SwiftUI
import MorrowCore

struct BriefWorkspaceView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    private var entries: [AgentArtifact] { model.briefArtifacts.filter { (model.briefSessionFilter == nil || model.briefSessionID($0) == model.briefSessionFilter) && (query.isEmpty || ($0.title + $0.content).localizedCaseInsensitiveContains(query)) } }
    var body: some View {
        VStack(spacing: 0) {
            if let artifact = model.selectedBrief { detail(artifact) }
            else { list }
        }.background(Theme.sheet).accessibilityIdentifier("brief.workspace")
    }
    private var list: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkspacePageHeader("简报", subtitle: L10n.format("{0}份已保存的简报", String(model.briefArtifacts.count))) {
                if model.briefSessionFilter != nil { Button(L10n.t("查看所有会话")) { model.briefSessionFilter = nil }.buttonStyle(CompactButtonStyle()) }
            }
            if let id = model.briefSessionFilter, let session = model.cachedSession(id) { Label(L10n.format("来自对话：{0}", session.title), systemImage: "bubble.left").font(Theme.label).foregroundStyle(Theme.secondary).lineLimit(1) }
            TextField(L10n.t("搜索简报"), text: $query).textFieldStyle(PaperFieldStyle()).accessibilityIdentifier("brief.search")
            Divider().overlay(Theme.rule)
            if entries.isEmpty {
                let filtering = !query.isEmpty || model.briefSessionFilter != nil
                EmptyRegion(icon: filtering ? "magnifyingglass" : "doc.text", title: L10n.t(filtering ? "没有匹配的简报" : "还没有简报"), detail: L10n.t(filtering ? "调整搜索或会话筛选后重试。" : "在对话中保存整理结果，简报会显示在这里。"), action: L10n.t(filtering ? "清除筛选" : "打开对话"), perform: {
                    if filtering { query = ""; model.briefSessionFilter = nil }
                    else { model.chatExpanded = true; model.chatFocusNonce += 1 }
                })
            } else {
                ScrollView { LazyVStack(alignment: .leading, spacing: 0) { ForEach(entries) { artifact in
                    Button { model.openBrief(artifact) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) { Text(artifact.title).font(Theme.body.weight(.medium)).lineLimit(2); Spacer(minLength: 8); Text(artifact.createdAt.uiFormatted(date: .abbreviated, time: .omitted)).font(Theme.small).foregroundStyle(Theme.muted).fixedSize() }
                            Text(WorkTextPreview.text(artifact.briefDocument?.summary ?? artifact.content, role: .brief)).font(Theme.label).foregroundStyle(Theme.secondary).lineLimit(2)
                            if let id = model.briefSessionID(artifact), let session = model.cachedSession(id) { Label(session.title, systemImage: "bubble.left").font(Theme.small).foregroundStyle(Theme.muted).lineLimit(1) }
                        }.padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(ListRowButtonStyle()).accessibilityIdentifier("brief.open")
                    Divider().overlay(Theme.rule)
                } } }
            }
        }.padding(24)
    }
    private func detail(_ artifact: AgentArtifact) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    Button { model.selectedBriefID = nil } label: { Label(L10n.t("简报列表"), systemImage: "chevron.left") }.buttonStyle(CompactButtonStyle())
                    Spacer(minLength: 0)
                    Text(L10n.t(artifact.briefDocument.map { $0.status == .complete ? "已整理" : $0.status == .inProgress ? "整理中" : "待核实" } ?? "已保存")).font(Theme.label).foregroundStyle(Theme.secondary)
                    ChatReplyCopyButton(text: artifact.content, label: "复制简报")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(artifact.title).font(Theme.title).textSelection(.enabled)
                    Text(artifact.createdAt.uiFormatted()).font(Theme.small).foregroundStyle(Theme.muted)
                    BriefConversationLink(artifact: artifact)
                }
                Divider().overlay(Theme.rule)
                WorkReportContent(artifact: artifact)
                if let revisions = artifact.revisions, !revisions.isEmpty { DisclosureGroup(L10n.format("之前的版本（{0}）", String(revisions.count))) { ForEach(Array(revisions.reversed().prefix(20))) { revision in VStack(alignment: .leading, spacing: 8) { Text(revision.createdAt.uiFormatted()).font(Theme.small).foregroundStyle(Theme.muted); WorkMarkdownContent(text: revision.content) }.padding(.vertical, 12) } }.font(Theme.label) }
                MailReferenceList(ids: artifact.sourceMailIDs, open: model.revealMail)
            }.padding(24).frame(maxWidth: 940, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct BriefConversationLink: View {
    @EnvironmentObject var model: AppModel
    let artifact: AgentArtifact
    var body: some View {
        if let id = model.briefSessionID(artifact), let session = model.cachedSession(id) {
            Button { Task { await model.openBriefSource(artifact) } } label: { Label(L10n.format("来自对话：{0}", session.title), systemImage: "bubble.left").lineLimit(2) }.buttonStyle(ReferenceRowButtonStyle()).font(Theme.label).accessibilityIdentifier("brief.open-conversation")
        }
    }
}

struct BriefStructuredContent: View {
    let artifact: AgentArtifact
    private var document: BriefDocument { artifact.briefDocument ?? BriefDocument.legacy(artifact.content, title: artifact.title) }
    var body: some View {
        Group {
            if artifact.briefDocument == nil {
                VStack(alignment: .leading, spacing: 16) {
                    WorkMarkdownContent(text: artifact.content)
                    Text(L10n.t("旧简报按原文段落展示，未重新生成或验证结论。")).font(Theme.small).foregroundStyle(Theme.muted)
                }
            } else {
                let document = document
                VStack(alignment: .leading, spacing: 24) {
                    if !document.summary.isEmpty { section("摘要") { WorkMarkdownContent(text: document.summary) } }
                    if !document.coverage.isEmpty { section("覆盖范围与进度") { WorkMarkdownContent(text: document.coverage).foregroundStyle(Theme.secondary) } }
                    items("关键发现", document.findings)
                    items("待办事项", document.actions)
                    items("待核实", document.uncertainties)
                    ForEach(Array(document.tables.prefix(8).enumerated()), id: \.offset) { _, table in
                        section(table.title) { ScrollView(.horizontal) { NativeOpenUIView(interaction: OpenUIInteraction(source: table.openUISource)).frame(minWidth: CGFloat(table.columns.count) * 140) } }
                    }
                }
            }
        }
    }
    @ViewBuilder private func items(_ title: String, _ values: [String]) -> some View {
        if !values.isEmpty { section(title) { VStack(alignment: .leading, spacing: 12) { ForEach(Array(values.prefix(40).enumerated()), id: \.offset) { index, value in
            WorkMarkdownContent(text: value)
            if index < min(40, values.count) - 1 { Divider().overlay(Theme.rule) }
        }; if values.count > 40 { Text(L10n.t("完整内容可复制或在正文编辑中查看。")).font(Theme.small).foregroundStyle(Theme.muted) } } } }
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View { VStack(alignment: .leading, spacing: 12) { Text(L10n.t(title)).font(Theme.heading); Divider().overlay(Theme.rule); content() }.frame(maxWidth: .infinity, alignment: .leading) }
}

extension BriefDocument.Table {
    var openUISource: String {
        let json = { (value: [String]) in String(decoding: (try? JSONEncoder().encode(value)) ?? Data("[]".utf8), as: UTF8.self) }
        let cols = columns.prefix(8).enumerated().map { index, column in "Col(" + String(json([column]).dropFirst().dropLast()) + "," + json(rows.prefix(100).map { index < $0.count ? $0[index] : "" }) + ")" }
        return "root = Table([" + cols.joined(separator: ",") + "])"
    }
}
