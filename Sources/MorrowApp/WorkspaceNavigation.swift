import Foundation

enum WorkspacePage: String, CaseIterable, Identifiable {
    case desk = "工作台", history = "工作记录", library = "资料", briefs = "简报", responders = "响应器", mail = "邮件", people = "联系人", attachments = "附件", memory = "记忆"
    var id: String { rawValue }
}
enum InspectorPage: String, CaseIterable, Identifiable {
    case artifacts = "产出", evidence = "证据", decisions = "决策"
    var id: String { rawValue }
}
