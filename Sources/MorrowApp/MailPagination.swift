import Foundation
import MorrowCore

struct MailPageWindow: Equatable {
    static let preferenceKey = "MorrowMailPageSize"
    static var preferredSize: Int { let value = UserDefaults.standard.integer(forKey: preferenceKey); return [25, 50, 100].contains(value) ? value : 50 }
    let total: Int
    let size: Int
    let index: Int
    var pageCount: Int { total == 0 ? 0 : (total - 1) / size + 1 }
    var start: Int { index * size }
    var end: Int { min(total, start + size) }
    var hasPrevious: Bool { index > 0 }
    var hasNext: Bool { end < total }
    var range: Range<Int> { start..<end }
    init(total: Int, index: Int, size: Int = 50) {
        self.total = max(0, total); self.size = [25, 50, 100].contains(size) ? size : 50
        self.index = min(max(0, index), self.total == 0 ? 0 : (self.total - 1) / self.size)
    }
}

extension AppModel {
    var mailPageWindow: MailPageWindow { .init(total: visibleMails.count, index: mailPageIndex, size: mailPageSize) }
    var pagedMails: [MailMessage] { let all = visibleMails; let page = MailPageWindow(total: all.count, index: mailPageIndex, size: mailPageSize); return Array(all[page.range]) }
    func turnMailPage(_ offset: Int) {
        let page = mailPageWindow
        mailPageIndex = MailPageWindow(total: page.total, index: page.index + offset, size: page.size).index
        selectedID = nil
    }
    func setMailPageSize(_ value: Int, persist: Bool = true) { mailPageSize = [25, 50, 100].contains(value) ? value : 50; mailPageIndex = 0; selectedID = nil; if persist { UserDefaults.standard.set(mailPageSize, forKey: MailPageWindow.preferenceKey) } }
    func revealSelectedMailPage() {
        guard let id = selectedID, let position = visibleMails.firstIndex(where: { $0.id == id }) else { return }
        mailPageIndex = position / mailPageSize
    }
}
