import SwiftUI
import UIKit
import MorrowCore

/// Native controls for a system-browser Google authorization session. Mail remains in native views.
struct GmailMobileConnectView: View {
    var emailHint = ""
    var existingAccounts: [MailAccount] = []
    var automaticStart = false
    var onConnect: @MainActor (GmailMobileConnection) async throws -> Void
    @StateObject private var authorization = GmailMobileAuthorizationModel()
    @State private var window: UIWindow?
    @State private var startedAutomatically = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(GmailMobileText.text("连接 Gmail 后，可同步、检索、整理和发送邮件。Google 会让你选择账户并确认邮件权限。", "Connect Gmail to sync, search, organize, and send mail. Google will ask you to choose an account and confirm mail permission.", "Gmail に接続すると、メールの同期、検索、整理、送信ができます。Google でアカウントを選び、メールの権限を確認します。"))
                .font(.subheadline).foregroundStyle(.secondary)
            Button {
                authorization.signIn(in: window, emailHint: emailHint, existingAccounts: existingAccounts, onConnect: onConnect)
            } label: {
                Label(GmailMobileText.text("使用 Google 连接 Gmail", "Connect Gmail with Google", "Google で Gmail に接続"), systemImage: "envelope.badge.shield.half.filled")
            }
            .disabled(authorization.busy || window == nil)
            .accessibilityIdentifier("mailbox.gmail.authorize")
            if authorization.hasPendingGrant {
                Button(GmailMobileText.text("重试已授权的邮箱连接", "Retry the authorized mailbox connection", "認証済みのメール接続を再試行")) {
                    authorization.retry(emailHint: emailHint, existingAccounts: existingAccounts, onConnect: onConnect)
                }.disabled(authorization.busy).accessibilityIdentifier("mailbox.gmail.retry")
            }
            if authorization.busy {
                HStack {
                    ProgressView()
                    if !authorization.committing {
                        Button(GmailMobileText.text("取消", "Cancel", "キャンセル")) { authorization.cancel() }
                            .accessibilityIdentifier("mailbox.gmail.cancel")
                    }
                }
            }
            if let status = authorization.status {
                Text(status).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("mailbox.gmail.status")
            }
            Text(GmailMobileText.text("授权保存在这台 iPhone 的钥匙串。邮箱通过验证后才会添加。", "Authorization stays in this iPhone's Keychain. The mailbox is added after verification.", "認証はこの iPhone のキーチェーンに保存します。メールボックスは検証後に追加します。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .background(GmailMobileAuthorizationAnchor { window = $0 }.frame(width: 0, height: 0))
        .onAppear { authorization.loadPending() }
        .onChange(of: window) { _, available in
            guard automaticStart, available != nil, !startedAutomatically else { return }
            startedAutomatically = true
            if authorization.hasPendingGrant { authorization.retry(emailHint: emailHint, existingAccounts: existingAccounts, onConnect: onConnect) }
            else { authorization.signIn(in: available, emailHint: emailHint, existingAccounts: existingAccounts, onConnect: onConnect) }
        }
        .onDisappear { authorization.cancel() }
    }
}
