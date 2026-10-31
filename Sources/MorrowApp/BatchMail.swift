import Foundation
import MorrowCore

enum BatchMailAction {
    case read(Bool), star(Bool), label(String), move(String)
    var name: String { switch self { case .read(let value): return value ? "标记已读" : "标记未读"; case .star(let value): return value ? "添加星标" : "取消星标"; case .label: return "添加标签"; case .move(let role): return role == "trash" ? "移到废纸篓" : "归档" } }
}
