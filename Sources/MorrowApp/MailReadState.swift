import SwiftUI
struct MailReadState: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    var read: Bool
    var body: some View {
        Text(read ? "已读" : "未读").font(Theme.small.weight(read ? .regular : .semibold))
            .foregroundStyle(read ? Theme.muted : Theme.unreadInk)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(read ? Theme.clear : Theme.unreadPaper, in: RoundedRectangle(cornerRadius: 4))
            .accessibilityLabel(read ? "已读邮件" : "未读邮件")
    }
}
