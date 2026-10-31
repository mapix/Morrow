import Foundation
import MorrowCore

enum MailboxSearchScope: String, CaseIterable, Identifiable {
    case mailbox = "当前邮箱全部文件夹", currentView = "当前视图", allMailboxes = "全部邮箱"
    var id: String { rawValue }
}
extension MailSearchStrategy {
    var title: String { switch self { case .semantic: return L10n.t("语义"); case .keyword: return L10n.t("关键词"); case .hybrid: return L10n.t("混合") } }
}
extension AppModel {
    var searchScopeTitle: String {
        if searchScope == .currentView { return selectedFolder ?? L10n.t(destination.rawValue) }
        if searchScope == .allMailboxes { return L10n.t("全部邮箱") }
        return accounts.first { $0.id == selectedAccount }?.name ?? L10n.t("全部邮箱")
    }
    func matchesSearchScope(_ mail: MailMessage) -> Bool {
        if searchScope == .currentView { return matchesMailScope(mail) }
        if searchScope != .allMailboxes, let selectedAccount, mail.accountID != selectedAccount { return false }
        if unreadOnly && mail.isRead { return false }
        if let category, mail.analysis?.category != category { return false }
        let role = folders.first { $0.accountID == mail.accountID && $0.path == mail.folder }?.role
        return role != "trash" && role != "junk"
    }
}
