import MorrowCore

enum DraftPresentationState: String {
    case draft, queued, sending, sent, uncertain
    init(_ value: String) { self = Self(rawValue: value) ?? .draft }
    var editable: Bool { self == .draft }
    var title: String {
        switch self {
        case .draft: return L10n.t("新邮件")
        case .queued: return L10n.t("待发送邮件")
        case .sending: return L10n.t("正在发送")
        case .sent: return L10n.t("已发送邮件")
        case .uncertain: return L10n.t("投递结果待核对")
        }
    }
    var receipt: String {
        switch self {
        case .draft: return L10n.t("草稿已保存")
        case .queued: return L10n.t("已加入发件箱，可在投递前撤回")
        case .sending: return L10n.t("正在投递，原稿暂不可修改")
        case .sent: return L10n.t("邮件已发送，原稿只读")
        case .uncertain: return L10n.t("请先核对已发送邮箱，原稿不会自动重发")
        }
    }
    var linkLabel: String {
        switch self {
        case .draft: return L10n.t("打开草稿")
        case .queued: return L10n.t("查看待发送邮件")
        case .sending: return L10n.t("查看投递记录")
        case .sent: return L10n.t("查看已发送邮件")
        case .uncertain: return L10n.t("核对投递结果")
        }
    }
    var symbol: String { self == .sent ? "paperplane" : self == .uncertain ? "exclamationmark.circle" : "doc.text" }
}
