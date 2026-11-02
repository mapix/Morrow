import Foundation

public enum MailSyncScope: String, Codable, CaseIterable, Sendable {
    case active, inbox, withArchive, all
    public var title: String {
        switch self {
        case .active: return "收件箱、已发送、草稿"
        case .inbox: return "仅收件箱"
        case .withArchive: return "包含归档，排除废纸篓和垃圾邮件"
        case .all: return "全部文件夹"
        }
    }
    public func includes(_ folder: MailFolder) -> Bool {
        let role = folder.role == "custom" ? MailFolder.inferredRole(path: folder.path) : folder.role
        switch self {
        case .active: return ["inbox", "sent", "drafts"].contains(role)
        case .inbox: return role == "inbox"
        case .withArchive: return role != "trash" && role != "junk"
        case .all: return true
        }
    }
}

public extension AgentSettings {
    var effectiveMailSyncScope: MailSyncScope { mailSyncScope ?? .active }
}

public extension MailFolder {
    /// Some servers omit SPECIAL-USE flags or prefix folders with [Gmail].
    /// Infer only known leaf names; custom labels retain their own role.
    static func inferredRole(path: String) -> String {
        let leaf = (MailboxCodec.decode(path).components(separatedBy: "/").last ?? path).lowercased()
        if leaf == "inbox" { return "inbox" }
        if ["sent", "sent mail", "sent messages", "sent items", "已发送", "已发送邮件", "送信済みメール"].contains(leaf) { return "sent" }
        if ["draft", "drafts", "草稿", "草稿箱", "下書き"].contains(leaf) { return "drafts" }
        if ["trash", "deleted messages", "deleted items", "已删除", "已删除邮件", "废纸篓", "ゴミ箱"].contains(leaf) { return "trash" }
        if ["junk", "spam", "垃圾邮件", "垃圾箱", "迷惑メール"].contains(leaf) { return "junk" }
        if ["archive", "all mail", "归档", "所有邮件", "すべてのメール"].contains(leaf) { return "archive" }
        return "custom"
    }
}
