import SwiftUI
import MorrowCore

extension MobileModel {
    func acceptGmailConnection(_ connection: GmailMobileConnection) async throws {
        try await connection.commit(to: store)
        accounts = try await store.load(MailAccount.self, kind: "account")
        folders = try await store.load(MailFolder.self, kind: "folder")
        accountID = connection.account.id
        await reload()
        try await navigateNative("邮件", mailbox: connection.account.id)
        Task { await sync() }
    }
}

struct MobileMailboxConnectionScreen: View {
    @EnvironmentObject var model: MobileModel
    let hint: String
    var body: some View {
        if MailProvider.infer(hint) == .gmail {
            ScrollView {
                GmailMobileConnectView(emailHint: MailProvider.email(in: hint) ?? "", existingAccounts: model.accounts, automaticStart: true) { connection in
                    try await model.acceptGmailConnection(connection)
                }.padding(22)
            }.navigationTitle("Gmail").accessibilityIdentifier("mailbox.gmail.screen")
        } else {
            MobileAccountSetup(hint: hint).environmentObject(model)
        }
    }
}
