import SwiftUI
import MorrowCore
import EventKit

struct InvitationView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    var invitation: CalendarInvitation
    var mail: MailMessage
    @State private var showEditor = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(invitation.title, systemImage: "calendar").font(Theme.heading)
            Text(invitation.start.uiFormatted(date: .complete, time: invitation.allDay ? .omitted : .shortened)).font(Theme.body)
            if !invitation.location.isEmpty { Text(invitation.location).font(Theme.label).foregroundStyle(Theme.secondary) }
            ViewThatFits(in: .horizontal) { HStack(spacing: 8) { actions }; VStack(alignment: .leading, spacing: 8) { actions } }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Theme.sheet).sheet(isPresented: $showEditor) { CalendarEditor(invitation: invitation).environmentObject(model) }
    }
    @ViewBuilder private var actions: some View {
        Button(L10n.t("添加到日历")) { showEditor = true }.buttonStyle(CompactButtonStyle())
        if !invitation.organizer.isEmpty {
            Button(L10n.t("准备接受回复")) { reply(true) }.buttonStyle(CompactButtonStyle())
            Button(L10n.t("准备拒绝回复")) { reply(false) }.buttonStyle(CompactButtonStyle())
        }
    }
    private func reply(_ accepted: Bool) {
        guard let account = model.accounts.first(where: { $0.id == mail.accountID }) else { return }
        do {
            let attachment = try invitation.reply(from: account.email, accepted: accepted)
            var draft = ComposeDraft(); draft.accountID = account.id; draft.to = invitation.organizer; draft.subject = (accepted ? "Accepted: " : "Declined: ") + invitation.title; draft.body = accepted ? L10n.t("我接受这次会议邀请。") : L10n.t("我无法参加这次会议。"); draft.attachments = [attachment]; draft.inReplyTo = mail.messageID; draft.references = mail.references + " " + mail.messageID
            model.composer = draft
        } catch { model.error = error.localizedDescription }
    }
}

struct CalendarEditor: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let invitation: CalendarInvitation
    @State private var title = ""
    @State private var location = ""
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(3600)
    @State private var busy = false
    @State private var error: String?
    @State private var added = false
    @State private var saveTask: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text(L10n.t(added ? "已加入日历" : "添加到日历")).font(Theme.title); Spacer(); Button { close() } label: { Image(systemName: "xmark") }.buttonStyle(ToolbarIconButtonStyle()).accessibilityLabel(L10n.t("关闭")) }
            Divider().overlay(Theme.rule)
            if added {
                VStack(alignment: .leading, spacing: 12) {
                    Label(title, systemImage: "checkmark.circle").font(Theme.heading)
                    Text(start.uiFormatted(date: .complete, time: invitation.allDay ? .omitted : .shortened)).font(Theme.body)
                    if !location.isEmpty { Text(location).font(Theme.label).foregroundStyle(Theme.secondary) }
                }.padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        field("标题", text: $title)
                        field("地点", text: $location)
                        VStack(alignment: .leading, spacing: 6) { Text(L10n.t("开始")).font(Theme.label).foregroundStyle(Theme.secondary); DatePicker("", selection: $start, displayedComponents: invitation.allDay ? .date : [.date, .hourAndMinute]).labelsHidden().datePickerStyle(.compact) }
                        VStack(alignment: .leading, spacing: 6) { Text(L10n.t("结束")).font(Theme.label).foregroundStyle(Theme.secondary); DatePicker("", selection: $end, displayedComponents: invitation.allDay ? .date : [.date, .hourAndMinute]).labelsHidden().datePickerStyle(.compact) }
                        Text(L10n.t("保存到系统默认日历，可能由系统同步到你的日历账户。")).font(Theme.label).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                    }.disabled(busy).padding(.vertical, 8)
                }.frame(maxHeight: 320)
            }
            if let error { Text(error).font(Theme.label).foregroundStyle(Theme.error).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            Divider().overlay(Theme.rule)
            HStack(spacing: 8) {
                Button(L10n.t(added ? "关闭" : "取消")) { close() }.buttonStyle(CompactButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                if !added { Button(L10n.t(busy ? "添加中…" : "添加到日历")) { save() }.buttonStyle(PrimaryButtonStyle()).disabled(busy || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction) }
            }
        }.padding(24).frame(minWidth: 400, idealWidth: 540, maxWidth: 600, minHeight: 360).background(Theme.paper)
            .onAppear { title = invitation.title; location = invitation.location; start = invitation.start; end = invitation.end }
            .onDisappear { saveTask?.cancel() }
    }
    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(L10n.t(label)).font(Theme.label).foregroundStyle(Theme.secondary); TextField("", text: text).textFieldStyle(PaperFieldStyle()).accessibilityLabel(L10n.t(label)) }
    }
    private func close() { saveTask?.cancel(); dismiss() }
    private func save() {
        guard !busy, end > start else { error = L10n.t("结束时间需要晚于开始时间。"); return }
        let eventTitle = title, eventLocation = location, eventStart = start, eventEnd = end
        busy = true; error = nil
        saveTask = Task {
            defer { busy = false; saveTask = nil }
            do {
                let eventStore = EKEventStore()
                guard try await eventStore.requestWriteOnlyAccessToEvents() else { throw MailError.message(L10n.t("未获得日历写入权限。")) }
                try Task.checkCancellation()
                guard let calendar = eventStore.defaultCalendarForNewEvents else { throw MailError.message(L10n.t("系统没有可写入的默认日历，请先在日历应用中配置。")) }
                let event = EKEvent(eventStore: eventStore); event.title = eventTitle; event.location = eventLocation; event.startDate = eventStart; event.endDate = eventEnd; event.isAllDay = invitation.allDay; event.calendar = calendar; event.notes = invitation.detail; event.addAlarm(EKAlarm(relativeOffset: -900))
                try eventStore.save(event, span: .thisEvent, commit: true); added = true
                await model.log(L10n.t("会议已加入系统日历"), detail: eventTitle + "，" + eventStart.uiFormatted(), kind: "calendar")
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}
