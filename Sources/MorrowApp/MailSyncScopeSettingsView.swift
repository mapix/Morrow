import SwiftUI
import MorrowCore

struct MailSyncScopeSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var saving = false
    @State private var status: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L10n.t("同步范围"), selection: Binding(get: { model.settings.effectiveMailSyncScope }, set: { scope in
                saving = true; status = nil
                Task {
                    defer { saving = false }
                    do { try await model.saveMailSyncScope(scope); status = L10n.t("同步范围已保存") }
                    catch { status = error.localizedDescription }
                }
            })) {
                ForEach(MailSyncScope.allCases, id: \.self) { scope in Text(L10n.t(scope.title)).tag(scope) }
            }.disabled(saving).accessibilityIdentifier("settings.mail-sync.scope")
            Text(L10n.t("排除的文件夹停止下载和新的自动分析；已有本地邮件与索引保留，仍可搜索。")).font(Theme.label).foregroundStyle(Theme.secondary)
            Text(L10n.t("同步只处理邮箱数据，不使用模型 API Token。自动摘要和联系人整理使用“自动邮件分析模型”；聊天和委托使用伙伴模型。")).font(Theme.small).foregroundStyle(Theme.muted)
            if let status { Text(status).font(Theme.label).foregroundStyle(Theme.secondary) }
        }
    }
}

extension AppModel {
    func isInAutomaticMailScope(_ mail: MailMessage) -> Bool {
        let folder = folders.first(where: { $0.accountID == mail.accountID && $0.path == mail.folder })
            ?? MailFolder(accountID: mail.accountID, path: mail.folder, role: MailFolder.inferredRole(path: mail.folder))
        return settings.effectiveMailSyncScope.includes(folder)
    }
    func saveMailSyncScope(_ scope: MailSyncScope) async throws {
        let analysis = analysisTask, profiles = profileTask
        var next = settings; next.mailSyncScope = scope
        try await store.save(next, kind: "settings", id: "main")
        settings = next
        if syncBusy { stopMailSynchronization() }
        analysis?.cancel(); profiles?.cancel()
        await analysis?.value; await profiles?.value
        await refreshMailRealtimeMonitoring()
        process()
    }
}
