// Hallmark Coral, native app screens. Attachments have their own unified workspace.
// Pre-emit critique: P5 H4 E4 S5 R4 V5. Native layout and keyboard focus await app-level verification.
import SwiftUI
import MorrowCore

struct AgentLibraryView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var scope: LibraryScope = .all
    @State private var artifactKind: AgentArtifactKind?
    @State private var extractingID: String?

    private enum LibraryScope: String, CaseIterable, Identifiable {
        case all = "全部", artifacts = "产出", attachments = "附件", notes = "笔记", labels = "标签"
        var id: String { rawValue }
    }
    private struct AttachmentEntry: Identifiable {
        let attachment: MailAttachment
        let mail: MailMessage
        var id: String { attachment.id }
    }
    private struct LabelEntry: Identifiable {
        let title: String
        let mails: [MailMessage]
        var id: String { title }
    }
    private var attachmentIndex: [AttachmentEntry] {
        var seen = Set<String>()
        return model.mails.sorted { $0.date > $1.date }.flatMap { mail in
            mail.attachments.compactMap { attachment in
                seen.insert(attachment.id).inserted ? AttachmentEntry(attachment: attachment, mail: mail) : nil
            }
        }
    }
    private var noteIndex: [MailMessage] {
        model.primaryMails.filter { !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    private var labelIndex: [LabelEntry] {
        var groups: [String: [MailMessage]] = [:]
        for mail in model.primaryMails {
            for label in Set(mail.labels) where !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                groups[label, default: []].append(mail)
            }
        }
        return groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { LabelEntry(title: $0, mails: groups[$0] ?? []) }
    }
    private var artifacts: [AgentArtifact] {
        model.agentArtifacts.filter { artifact in
            (artifactKind == nil || (artifactKind == .report ? artifact.isBrief : artifact.kind == artifactKind)) && matches([artifact.title, artifact.content, runTitle(artifact.runID), artifactName(artifact.kind)])
        }.sorted { $0.createdAt > $1.createdAt }
    }
    private var attachments: [AttachmentEntry] {
        attachmentIndex.filter { matches([$0.attachment.name, $0.attachment.mimeType, $0.mail.subject, $0.mail.from.display] + $0.mail.labels) }
    }
    private var notes: [MailMessage] {
        noteIndex.filter { matches([$0.note, $0.subject, $0.from.display] + $0.labels) }
    }
    private var labels: [LabelEntry] {
        labelIndex.filter { matches([$0.title] + $0.mails.flatMap { [$0.subject, $0.from.display] }) }
    }
    private var resultCount: Int {
        switch scope {
        case .all: return artifacts.count + notes.count + labels.count
        case .artifacts: return artifacts.count
        case .attachments: return attachments.count
        case .notes: return notes.count
        case .labels: return labels.count
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentIndexHeader(title: L10n.t("成果与笔记"), detail: L10n.t("准备好的简报、回复草稿，以及邮件笔记和标签。"))
            controls
            if let error = model.error { AgentIndexError(detail: error) { model.error = nil } }
            if !model.ready {
                AgentIndexLoading(label: L10n.t("正在打开资料索引"))
            } else if resultCount == 0 {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if scope == .all || scope == .artifacts, !artifacts.isEmpty {
                            AgentIndexSection(title: L10n.t("工作产出"), count: artifacts.count)
                            ForEach(artifacts) { artifact in artifactRow(artifact) }
                        }
                        if scope == .attachments, !attachments.isEmpty {
                            AgentIndexSection(title: L10n.t("邮件附件"), count: attachments.count)
                            ForEach(attachments) { entry in attachmentRow(entry) }
                        }
                        if scope == .all || scope == .notes, !notes.isEmpty {
                            AgentIndexSection(title: L10n.t("笔记"), count: notes.count)
                            ForEach(notes) { mail in noteRow(mail) }
                        }
                        if scope == .all || scope == .labels, !labels.isEmpty {
                            AgentIndexSection(title: L10n.t("标签"), count: labels.count)
                            ForEach(labels) { entry in labelRow(entry) }
                        }
                    }.padding(.horizontal, 24).padding(.bottom, 24)
                }
            }
        }.font(Theme.body).foregroundStyle(Theme.ink).background(Theme.paper)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AgentIndexSearch(query: $query, prompt: L10n.t("搜索成果标题、笔记或标签"))
                if scope == .all || scope == .artifacts {
                    Menu {
                        Button(L10n.t("全部产出")) { artifactKind = nil }
                        ForEach([AgentArtifactKind.draft, .report, .action], id: \.rawValue) { kind in
                            Button(artifactName(kind)) { artifactKind = kind }
                        }
                    } label: {
                        Label(artifactKind.map(artifactName) ?? L10n.t("全部产出"), systemImage: "line.3.horizontal.decrease")
                    }.menuStyle(.borderlessButton).frame(minWidth: 100, minHeight: 44)
                }
            }
            HStack(spacing: 16) {
                Picker(L10n.t("资料类型"), selection: $scope) {
                    ForEach(LibraryScope.allCases.filter { $0 != .attachments }) { item in Text(L10n.t(item.rawValue)).tag(item) }
                }.pickerStyle(.segmented).frame(maxWidth: 440).frame(minHeight: 44)
                Spacer(minLength: 0)
                Text(L10n.format("{0} 项", "\(resultCount)")).font(Theme.label).monospacedDigit().foregroundStyle(Theme.muted)
            }
        }.padding(.horizontal, 24).padding(.bottom, 16).overlay(alignment: .bottom) { AgentIndexRule() }
    }
    private var emptyState: some View {
        let filtering = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || artifactKind != nil || scope != .all
        return EmptyRegion(icon: filtering ? "magnifyingglass" : "tray", title: filtering ? L10n.t("没有符合条件的成果") : L10n.t("工作成果会保存在这里"), detail: filtering ? L10n.t("换一个关键词，或查看全部成果。") : L10n.t("完成一次委托后，可在这里查找简报、回复草稿、标签和笔记。"), action: filtering ? L10n.t("清除筛选") : L10n.t("回到工作台"), perform: {
            if filtering { query = ""; scope = .all; artifactKind = nil }
            else { model.workspacePage = .desk }
        })
    }
    private func artifactRow(_ artifact: AgentArtifact) -> some View {
        Button {
            if artifact.isBrief { model.openBrief(artifact); return }
            model.selectedRunID = artifact.runID
            model.selectedID = nil
            model.workspacePage = .desk
            model.inspectorPage = .artifacts
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: artifact.kind == .draft ? "square.and.pencil" : "doc.text").foregroundStyle(Theme.secondary).frame(width: 22).padding(.top, 3).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(artifact.title.isEmpty ? artifactName(artifact.kind) : artifact.title).font(Theme.body.weight(.medium)).lineLimit(2)
                        Spacer(minLength: 12)
                        Text(artifact.createdAt.uiFormatted(date: .abbreviated, time: .omitted)).font(Theme.label).foregroundStyle(Theme.muted)
                    }
                    if !artifact.content.isEmpty { Text(artifact.content).font(Theme.label).foregroundStyle(Theme.secondary).lineLimit(2) }
                    HStack(spacing: 16) {
                        Text(artifactName(artifact.kind))
                        Text(runTitle(artifact.runID)).lineLimit(1)
                        if !artifact.sourceMailIDs.isEmpty { Text(L10n.format("{0} 封来源邮件", "\(Set(artifact.sourceMailIDs).count)")).monospacedDigit() }
                    }.font(Theme.small).foregroundStyle(Theme.muted)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(AgentIndexRowButtonStyle()).help(L10n.t("查看这份产出所属的工作"))
            .overlay(alignment: .bottom) { AgentIndexRule() }
    }
    private func attachmentRow(_ entry: AttachmentEntry) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "paperclip").foregroundStyle(Theme.secondary).frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(entry.attachment.name).font(Theme.body.weight(.medium)).lineLimit(2)
                Button { openMail(entry.mail) } label: {
                    Text(entry.mail.subject.isEmpty ? L10n.t("无主题邮件") : entry.mail.subject).font(Theme.label).foregroundStyle(Theme.secondary).lineLimit(1).frame(minHeight: 44, alignment: .leading)
                }.buttonStyle(.plain).help(L10n.t("查看附件的来源邮件"))
                Text(entry.attachment.size).font(Theme.small).foregroundStyle(Theme.muted).monospacedDigit()
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button {
                extractingID = entry.id
                Task { await model.previewText(entry.attachment); extractingID = nil }
            } label: {
                if extractingID == entry.id && model.attachmentTextBusy { ProgressView().controlSize(.small).frame(minWidth: 72) }
                else { Text(L10n.t("提取文字")) }
            }.buttonStyle(QuietButtonStyle()).disabled(model.attachmentTextBusy)
            Menu {
                Button(L10n.t("打开附件")) { Task { await model.attachment(entry.attachment) } }
                Button(L10n.t("保存附件…")) { Task { await model.attachment(entry.attachment, save: true) } }
                Button(L10n.t("重新提取文字")) { extractingID = entry.id; Task { await model.previewText(entry.attachment, force: true); extractingID = nil } }.disabled(model.attachmentTextBusy)
            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                .menuStyle(.borderlessButton).frame(width: 44, height: 44).help(L10n.t("附件操作"))
        }.padding(.vertical, 16).overlay(alignment: .bottom) { AgentIndexRule() }
    }
    private func noteRow(_ mail: MailMessage) -> some View {
        Button { openMail(mail) } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "note.text").foregroundStyle(Theme.secondary).frame(width: 22).padding(.top, 3).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 7) {
                    Text(mail.subject.isEmpty ? L10n.t("无主题邮件") : mail.subject).font(Theme.body.weight(.medium)).lineLimit(2)
                    Text(mail.note).font(Theme.label).foregroundStyle(Theme.secondary).lineLimit(3)
                    HStack(spacing: 16) {
                        Text(mail.from.display).lineLimit(1)
                        if !mail.labels.isEmpty { Text(mail.labels.joined(separator: "、")).lineLimit(1) }
                    }.font(Theme.small).foregroundStyle(Theme.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.buttonStyle(AgentIndexRowButtonStyle()).help(L10n.t("打开邮件并查看笔记"))
            .overlay(alignment: .bottom) { AgentIndexRule() }
    }
    private func labelRow(_ entry: LabelEntry) -> some View {
        DisclosureGroup {
            ForEach(entry.mails) { mail in
                Button { openMail(mail) } label: {
                    HStack(spacing: 16) {
                        Text(mail.subject.isEmpty ? L10n.t("无主题邮件") : mail.subject).lineLimit(1)
                        Spacer()
                        Text(mail.from.display).foregroundStyle(Theme.muted).lineLimit(1)
                    }.font(Theme.label).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.buttonStyle(.plain).help(L10n.t("打开带有这个标签的邮件"))
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "tag").foregroundStyle(Theme.secondary).frame(width: 22).accessibilityHidden(true)
                Text(entry.title).font(Theme.body.weight(.medium))
                Spacer()
                Text(L10n.format("{0} 封邮件", "\(entry.mails.count)")).font(Theme.label).monospacedDigit().foregroundStyle(Theme.muted)
            }.frame(minHeight: 44)
        }.tint(Theme.secondary).padding(.vertical, 8).overlay(alignment: .bottom) { AgentIndexRule() }
    }
    private func matches(_ values: [String]) -> Bool { AgentIndexMatch.matches(query, values: values) }
    private func runTitle(_ id: String) -> String { model.agentRuns.first { $0.id == id }?.title ?? L10n.t("未找到所属工作") }
    private func artifactName(_ kind: AgentArtifactKind) -> String {
        switch kind { case .draft: return L10n.t("回复草稿"); case .report, .brief: return L10n.t("简报"); case .action: return L10n.t("行动方案") }
    }
    private func openMail(_ mail: MailMessage) {
        model.selectedRunID = nil
        model.workspacePage = .mail
        model.select(mail)
    }
}

struct AgentHistoryView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject private var model: AppModel
    @State private var query = ""
    @State private var scope: HistoryScope = .runs
    @State private var phase: AgentPhase?
    @State private var expanded = Set<String>()

    private enum HistoryScope: String, CaseIterable, Identifiable {
        case runs = "工作", events = "活动"
        var id: String { rawValue }
    }
    private var runs: [AgentRun] {
        model.agentRuns.filter { run in
            (phase == nil || phase == run.phase) && AgentIndexMatch.matches(query, values: [run.title, run.instruction, run.summary, run.phase.label] + run.steps.flatMap { [$0.title, $0.detail, $0.tool] } + relatedEvents(run).flatMap { [$0.title, $0.detail] })
        }.sorted { $0.updatedAt > $1.updatedAt }
    }
    private var events: [PartnerEvent] {
        model.events.filter { AgentIndexMatch.matches(query, values: [$0.title, $0.detail, eventName($0.kind)]) }.sorted { $0.date > $1.date }
    }
    private var resultCount: Int { scope == .runs ? runs.count : events.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AgentIndexHeader(title: L10n.t("工作记录"), detail: L10n.t("按事项查看进度、执行步骤、决定和操作回执。"))
            controls
            if let error = model.error { AgentIndexError(detail: error) { model.error = nil } }
            if !model.ready {
                AgentIndexLoading(label: L10n.t("正在打开工作记录"))
            } else if resultCount == 0 {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if scope == .runs { ForEach(runs) { run in runRow(run) } }
                        else { ForEach(events) { event in eventRow(event, showRun: true) } }
                    }.padding(.horizontal, 24).padding(.bottom, 24)
                }
            }
        }.font(Theme.body).foregroundStyle(Theme.ink).background(Theme.paper)
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                AgentIndexSearch(query: $query, prompt: L10n.t("搜索工作、步骤或记录"))
                if scope == .runs {
                    Menu {
                        Button(L10n.t("全部状态")) { phase = nil }
                        ForEach(AgentPhase.allCases, id: \.rawValue) { value in Button(value.label) { phase = value } }
                    } label: { Label(phase?.label ?? L10n.t("全部状态"), systemImage: "line.3.horizontal.decrease") }
                        .menuStyle(.borderlessButton).frame(minWidth: 110, minHeight: 44)
                }
            }
            HStack(spacing: 16) {
                Picker(L10n.t("记录类型"), selection: $scope) {
                    ForEach(HistoryScope.allCases) { value in Text(L10n.t(value.rawValue)).tag(value) }
                }.pickerStyle(.segmented).frame(width: 180).frame(minHeight: 44)
                Spacer()
                Text(L10n.format("{0} 项", "\(resultCount)")).font(Theme.label).monospacedDigit().foregroundStyle(Theme.muted)
            }
        }.padding(.horizontal, 24).padding(.bottom, 16).overlay(alignment: .bottom) { AgentIndexRule() }
    }
    private var emptyState: some View {
        let filtering = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (scope == .runs && phase != nil)
        return EmptyRegion(icon: filtering ? "magnifyingglass" : "clock", title: filtering ? L10n.t("没有符合条件的记录") : L10n.t("这里保留工作的经过"), detail: filtering ? L10n.t("换一个关键词，或移除状态筛选。") : L10n.t("把事情交给伙伴后，步骤、产出和相关活动会留下记录。"), action: filtering ? L10n.t("清除筛选") : L10n.t("回到工作台"), perform: {
            if filtering { query = ""; phase = nil }
            else { model.workspacePage = .desk }
        })
    }
    private func runRow(_ run: AgentRun) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { model.selectRun(run) } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        Text(run.title).font(Theme.heading).lineLimit(2)
                        Spacer(minLength: 12)
                        Text(L10n.t(run.phase.label)).font(Theme.label).foregroundStyle(phaseColor(run.phase))
                    }
                    Text(run.summary.isEmpty ? run.instruction : run.summary).font(Theme.body).foregroundStyle(Theme.secondary).lineLimit(3)
                    HStack(spacing: 16) {
                        Text(run.updatedAt.uiFormatted()).lineLimit(1)
                        Text(L10n.format("{0} 个步骤", "\(run.steps.count)")).monospacedDigit()
                        Text(L10n.format("{0} 份产出", "\(model.agentArtifacts.filter { $0.runID == run.id }.count)")).monospacedDigit()
                        if run.isDemo { Text(L10n.t("演示工作")) }
                    }.font(Theme.small).foregroundStyle(Theme.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(AgentIndexRowButtonStyle()).help(L10n.t("打开工作台，查看这项工作"))
            DisclosureGroup(isExpanded: Binding(get: { expanded.contains(run.id) }, set: { value in if value { expanded.insert(run.id) } else { expanded.remove(run.id) } })) {
                VStack(alignment: .leading, spacing: 0) {
                    if run.steps.isEmpty {
                        Text(L10n.t("这项工作还没有记录步骤。")).font(Theme.label).foregroundStyle(Theme.muted).padding(.vertical, 16)
                    } else {
                        ForEach(run.steps.sorted { $0.date < $1.date }) { step in stepRow(step) }
                    }
                    let linkedEvents = relatedEvents(run)
                    if !linkedEvents.isEmpty {
                        AgentIndexSection(title: L10n.t("相关委托活动"), count: linkedEvents.count)
                        ForEach(linkedEvents) { event in eventRow(event, showRun: false) }
                    }
                }.padding(.leading, 8)
            } label: {
                HStack(spacing: 12) {
                    Text(L10n.t("查看经过")).font(Theme.label)
                    if let step = run.steps.max(by: { $0.date < $1.date }) { Text(step.title).font(Theme.label).foregroundStyle(Theme.muted).lineLimit(1) }
                }.frame(minHeight: 44)
            }.tint(Theme.secondary).padding(.bottom, 12)
        }.overlay(alignment: .bottom) { AgentIndexRule() }
    }
    private func stepRow(_ step: AgentStep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(step.title).font(Theme.body.weight(.medium))
                Spacer()
                Text(stepState(step.state)).font(Theme.label).foregroundStyle(step.state == .failed ? Theme.error : step.state == .active ? Theme.accent2 : Theme.muted)
                Text(step.date.uiFormatted()).font(Theme.small).foregroundStyle(Theme.muted)
            }
            if !step.detail.isEmpty { Text(step.detail).font(Theme.label).foregroundStyle(Theme.secondary).textSelection(.enabled) }
            HStack(spacing: 16) {
                if !step.tool.isEmpty { Text(step.tool).font(Theme.small).foregroundStyle(Theme.muted) }
                if !step.sourceMailIDs.isEmpty { Text(L10n.format("{0} 封来源邮件", "\(Set(step.sourceMailIDs).count)")).font(Theme.small).foregroundStyle(Theme.muted).monospacedDigit() }
            }
            sourceLinks(step.sourceMailIDs)
        }.padding(.vertical, 16).overlay(alignment: .bottom) { AgentIndexRule() }
    }
    private func eventRow(_ event: PartnerEvent, showRun: Bool) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(event.title).font(Theme.body.weight(.medium)).lineLimit(2)
                Spacer(minLength: 12)
                Text(event.date.uiFormatted()).font(Theme.small).foregroundStyle(Theme.muted)
            }
            if !event.detail.isEmpty { Text(event.detail).font(Theme.label).foregroundStyle(Theme.secondary).textSelection(.enabled) }
            HStack(spacing: 16) {
                Text(eventName(event.kind)).font(Theme.small).foregroundStyle(event.kind == "error" ? Theme.error : Theme.muted)
                if showRun, let delegationID = event.delegationID, let run = model.agentRuns.first(where: { $0.delegationID == delegationID }) {
                    Button(L10n.t("查看所属工作")) { model.selectRun(run) }.buttonStyle(.plain).font(Theme.label).frame(minHeight: 44).help(run.title)
                }
            }
            sourceLinks(event.messageIDs)
        }.padding(.vertical, 20).overlay(alignment: .bottom) { AgentIndexRule() }
    }
    private func sourceLinks(_ ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(Set(ids)).sorted(), id: \.self) { id in
                if let mail = model.mails.first(where: { $0.id == id }) {
                    Button {
                        model.selectedRunID = nil
                        model.workspacePage = .mail
                        model.select(mail)
                    } label: {
                        Label(mail.subject.isEmpty ? L10n.t("无主题邮件") : mail.subject, systemImage: "envelope").font(Theme.label).lineLimit(1).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.buttonStyle(.plain).foregroundStyle(Theme.secondary).help(L10n.t("打开来源邮件"))
                }
            }
        }
    }
    private func relatedEvents(_ run: AgentRun) -> [PartnerEvent] {
        guard let delegationID = run.delegationID else { return [] }
        return model.events.filter { $0.delegationID == delegationID }.sorted { $0.date > $1.date }
    }
    private func phaseColor(_ phase: AgentPhase) -> Color {
        switch phase { case .failed: return Theme.error; case .reading, .working, .waitingUser: return Theme.accent2; default: return Theme.muted }
    }
    private func stepState(_ state: AgentStepState) -> String {
        switch state { case .pending: return L10n.t("待推进"); case .active: return L10n.t("正在进行"); case .completed: return L10n.t("已完成"); case .failed: return L10n.t("未完成") }
    }
    private func eventName(_ kind: String) -> String {
        switch kind {
        case "account": return L10n.t("邮箱连接")
        case "sync": return L10n.t("邮件同步")
        case "attention": return L10n.t("邮件事项")
        case "batch": return L10n.t("批量处理")
        case "outbox": return L10n.t("发送队列")
        case "delivery": return L10n.t("邮件投递")
        case "contact": return L10n.t("联系人")
        case "import": return L10n.t("资料导入")
        case "operation": return L10n.t("委托操作")
        case "draft": return L10n.t("草稿")
        case "delegation", "delegation-result": return L10n.t("委托")
        case "error": return L10n.t("需要处理")
        default: return L10n.t("工作活动")
        }
    }
}

private enum AgentIndexMatch {
    static func matches(_ query: String, values: [String]) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return terms.allSatisfy { term in values.contains { $0.localizedCaseInsensitiveContains(term) } }
    }
}
private struct AgentIndexHeader: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(Theme.title).foregroundStyle(Theme.ink)
            Text(detail).font(Theme.body).foregroundStyle(Theme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
    }
}
private struct AgentIndexSearch: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @Binding var query: String
    let prompt: String
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted).accessibilityHidden(true)
            TextField("", text: $query, prompt: Text(prompt).foregroundStyle(Theme.muted))
                .textFieldStyle(.plain).font(Theme.body).foregroundStyle(Theme.ink).focused($focused).accessibilityLabel(prompt)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark").font(Theme.label).frame(width: 44, height: 44) }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondary).help(L10n.t("清除搜索")).accessibilityLabel(L10n.t("清除搜索"))
            }
        }.padding(.leading, 12).padding(.trailing, query.isEmpty ? 12 : 0).frame(minHeight: 44)
            .background(Theme.sheet, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(focused ? Theme.focus : Theme.rule, lineWidth: 1))
    }
}
private struct AgentIndexSection: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    let title: String
    let count: Int
    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(Theme.body.weight(.medium)).foregroundStyle(Theme.ink)
            Text("\(count)").font(Theme.label).monospacedDigit().foregroundStyle(Theme.muted)
            Spacer()
        }.padding(.top, 24).padding(.bottom, 12).overlay(alignment: .bottom) { AgentIndexRule() }
    }
}
private struct AgentIndexRule: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    var body: some View { Rectangle().fill(Theme.rule).frame(height: 1).accessibilityHidden(true) }
}
private struct AgentIndexRowButtonStyle: ButtonStyle {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.vertical, 18).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(configuration.isPressed ? Theme.sidebar : Theme.clear).contentShape(Rectangle())
    }
}
private struct AgentIndexError: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    let detail: String
    let dismiss: () -> Void
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.error).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.t("操作未完成")).font(Theme.body.weight(.medium)).foregroundStyle(Theme.ink)
                Text(detail).font(Theme.label).foregroundStyle(Theme.secondary).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(L10n.t("关闭"), action: dismiss).buttonStyle(QuietButtonStyle())
        }.padding(.horizontal, 24).padding(.vertical, 16).background(Theme.sheet).overlay(alignment: .bottom) { AgentIndexRule() }
    }
}
private struct AgentIndexLoading: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) { ProgressView().controlSize(.small); Text(label).font(Theme.label).foregroundStyle(Theme.muted) }.padding(.vertical, 24)
            ForEach(0..<5, id: \.self) { index in
                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.rule).frame(width: index.isMultiple(of: 2) ? 220 : 170, height: 15)
                    RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.rule.opacity(0.6)).frame(maxWidth: .infinity).frame(height: 12)
                    RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.rule.opacity(0.6)).frame(width: 130, height: 10)
                }.padding(.vertical, 20).overlay(alignment: .bottom) { AgentIndexRule() }.accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).accessibilityLabel(label)
    }
}
