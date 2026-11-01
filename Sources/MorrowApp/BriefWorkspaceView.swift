import SwiftUI
import MorrowCore

struct BriefWorkspaceView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    private var entries: [AgentArtifact] { model.briefArtifacts.filter { (model.briefSessionFilter == nil || model.briefSessionID($0) == model.briefSessionFilter) && (query.isEmpty || ($0.title + $0.content).localizedCaseInsensitiveContains(query)) } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let artifact = model.selectedBrief {
                    HStack { Button { model.selectedBriefID = nil } label: { Label(L10n.t("简报列表"), systemImage: "chevron.left") }.buttonStyle(CompactButtonStyle()); Spacer(); Text(L10n.t(artifact.briefDocument.map { $0.status == .complete ? "已整理" : $0.status == .inProgress ? "整理中" : "待核实" } ?? "已保存")).font(Theme.label).foregroundStyle(Theme.accent2) }
                    Text(artifact.title).font(Theme.title).textSelection(.enabled)
                    BriefConversationLink(artifact: artifact)
                    HStack { Text(artifact.createdAt.uiFormatted()).font(Theme.label).foregroundStyle(Theme.muted); Spacer(); ChatReplyCopyButton(text: artifact.content) }
                    WorkReportContent(artifact: artifact)
                    if let revisions = artifact.revisions, !revisions.isEmpty { DisclosureGroup(L10n.format("之前的版本（{0}）", String(revisions.count))) { ForEach(Array(revisions.reversed().prefix(20))) { revision in VStack(alignment: .leading, spacing: 10) { Text(revision.createdAt.uiFormatted()).font(Theme.small).foregroundStyle(Theme.muted); WorkMarkdownContent(text: revision.content) }.padding(.vertical, 12) } }.font(Theme.label) }
                    if !artifact.sourceMailIDs.isEmpty { DisclosureGroup(L10n.format("依据邮件（{0}）", String(artifact.sourceMailIDs.count))) { ForEach(artifact.sourceMailIDs, id: \.self) { id in if let mail = model.mailByID(id) { Button(mail.subject) { model.revealMail(mail) }.buttonStyle(ReferenceRowButtonStyle()) } } }.font(Theme.label) }
                } else {
                    HStack { Text(L10n.t("简报")).font(Theme.title); Spacer(); if model.briefSessionFilter != nil { Button(L10n.t("查看所有会话")) { model.briefSessionFilter = nil }.buttonStyle(CompactButtonStyle()) } }
                    if let id = model.briefSessionFilter, let session = model.cachedSession(id) { Text(L10n.format("来自对话：{0}", session.title)).font(Theme.label).foregroundStyle(Theme.secondary) }
                    TextField(L10n.t("搜索简报"), text: $query).textFieldStyle(PaperFieldStyle())
                    if entries.isEmpty { EmptyRegion(icon: "doc.text", title: L10n.t("还没有简报"), detail: L10n.t("在对话中让伙伴保存整理结果，简报会显示在这里。"), action: nil) }
                    else { LazyVStack(alignment: .leading, spacing: 0) { ForEach(entries) { artifact in
                        Button { model.openBrief(artifact) } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack { Text(artifact.title).font(Theme.heading).lineLimit(2); Spacer(); Text(artifact.createdAt.uiFormatted(date: .abbreviated, time: .omitted)).font(Theme.small).foregroundStyle(Theme.muted) }
                                Text(artifact.briefDocument?.summary ?? artifact.content).font(Theme.label).foregroundStyle(Theme.secondary).lineLimit(3)
                                if let id = model.briefSessionID(artifact), let session = model.cachedSession(id) { Label(session.title, systemImage: "bubble.left").font(Theme.small).foregroundStyle(Theme.accent2).lineLimit(1) }
                            }.padding(.vertical, 18)
                        }.buttonStyle(ListRowButtonStyle()).accessibilityIdentifier("brief.open")
                        Divider().overlay(Theme.rule)
                    } } }
                }
            }.padding(model.compactLayout ? 24 : 32).frame(maxWidth: 940, alignment: .leading).frame(maxWidth: .infinity, alignment: .center)
        }.background(Theme.paper).accessibilityIdentifier("brief.workspace")
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
        let document = document
        VStack(alignment: .leading, spacing: 24) {
            if !document.summary.isEmpty { section("摘要") { WorkMarkdownContent(text: document.summary) } }
            if !document.coverage.isEmpty { section("覆盖范围与进度") { WorkMarkdownContent(text: document.coverage).foregroundStyle(Theme.secondary) } }
            items("关键发现", document.findings, symbol: "circle.fill")
            items("待办事项", document.actions, symbol: "arrow.right")
            items("待核实", document.uncertainties, symbol: "questionmark.circle")
            ForEach(Array(document.tables.prefix(8).enumerated()), id: \.offset) { _, table in
                section(table.title) { ScrollView(.horizontal) { NativeOpenUIView(interaction: OpenUIInteraction(source: table.openUISource)).frame(minWidth: CGFloat(table.columns.count) * 140) } }
            }
            if artifact.briefDocument == nil { Text(L10n.t("旧简报按原文段落展示，未重新生成或验证结论。")).font(Theme.small).foregroundStyle(Theme.muted) }
        }
    }
    @ViewBuilder private func items(_ title: String, _ values: [String], symbol: String) -> some View {
        if !values.isEmpty { section(title) { VStack(alignment: .leading, spacing: 16) { ForEach(Array(values.prefix(40).enumerated()), id: \.offset) { _, value in HStack(alignment: .top, spacing: 12) { Image(systemName: symbol).font(.system(size: symbol == "circle.fill" ? 5 : 12)).foregroundStyle(Theme.accent2).frame(width: 16, height: 22); WorkMarkdownContent(text: value) } }; if values.count > 40 { Text(L10n.t("完整内容可复制或在正文编辑中查看。")).font(Theme.small).foregroundStyle(Theme.muted) } } } }
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
