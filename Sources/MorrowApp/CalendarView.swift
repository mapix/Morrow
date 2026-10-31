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
            HStack { Image(systemName: "calendar").accessibilityHidden(true); Text(invitation.title).font(Theme.heading) }
            Text(invitation.start.uiFormatted(date: .complete, time: invitation.allDay ? .omitted : .shortened)).font(Theme.body)
            if !invitation.location.isEmpty { Text(invitation.location).font(Theme.label).foregroundStyle(Theme.muted) }
            HStack(spacing: 12) { Button(L10n.t("添加到日历")) { showEditor = true }.buttonStyle(QuietButtonStyle()); if !invitation.organizer.isEmpty { Button(L10n.t("准备接受回复")) { reply(true) }.buttonStyle(.link); Button(L10n.t("准备拒绝回复")) { reply(false) }.buttonStyle(.link) } }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).background(Theme.paper).sheet(isPresented: $showEditor) { CalendarEditor(invitation: invitation).environmentObject(model) }
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
    @Environment(\.dismiss) var dismiss
    let invitation: CalendarInvitation
    @State private var title = ""
    @State private var location = ""
    @State private var start = Date()
    @State private var end = Date().addingTimeInterval(3600)
    @State private var busy = false
    @State private var error = ""
    @State private var added = false
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(added ? L10n.t("已加入日历") : L10n.t("安排这次会议")).font(Theme.title)
            Form { TextField(L10n.t("标题"), text: $title); TextField(L10n.t("地点"), text: $location); DatePicker(L10n.t("开始"), selection: $start); DatePicker(L10n.t("结束"), selection: $end); Text(L10n.t("保存到系统默认日历，可能由系统同步到你的日历账户。")).font(Theme.label).foregroundStyle(Theme.muted) }.formStyle(.grouped)
            if !error.isEmpty { Text(error).font(Theme.label).foregroundStyle(Theme.error) }
            HStack { Button(added ? L10n.t("关闭") : L10n.t("取消")) { dismiss() }.buttonStyle(QuietButtonStyle()); Spacer(); if !added { Button(busy ? L10n.t("添加中…") : L10n.t("添加到日历")) {
                guard end > start else { error = L10n.t("结束时间需要晚于开始时间。"); return }; busy = true
                Task {
                    do {
                        let eventStore = EKEventStore(); guard try await eventStore.requestWriteOnlyAccessToEvents() else { throw MailError.message(L10n.t("未获得日历写入权限。")) }
                        guard let calendar = eventStore.defaultCalendarForNewEvents else { throw MailError.message(L10n.t("系统没有可写入的默认日历，请先在日历应用中配置。")) }
                        let event = EKEvent(eventStore: eventStore); event.title = title; event.location = location; event.startDate = start; event.endDate = end; event.isAllDay = invitation.allDay; event.calendar = calendar; event.notes = invitation.detail; event.addAlarm(EKAlarm(relativeOffset: -900))
                        try eventStore.save(event, span: .thisEvent, commit: true); added = true
                        await model.log(L10n.t("会议已加入系统日历"), detail: title + "，" + start.uiFormatted(), kind: "calendar")
                    } catch { self.error = error.localizedDescription }; busy = false
                }
            }.buttonStyle(PrimaryButtonStyle()).disabled(busy) } }
        }.padding(28).frame(width: 580, height: 450).background(Theme.paper).onAppear { title = invitation.title; location = invitation.location; start = invitation.start; end = invitation.end }
    }
}
