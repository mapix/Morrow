import Foundation
import MorrowCore

struct ChatStatisticsPresentation: Sendable {
    var summary: String
    var chartSource: String
    static func requested(_ text: String) -> Bool { ["图表", "柱状", "折线", "饼图", "趋势", "分布", "chart", "plot", "graph", "distribution", "trend"].contains { text.localizedCaseInsensitiveContains($0) } }
    static func make(mails: [MailMessage], mode: String, scope: String) -> ChatStatisticsPresentation {
        var categories: [String: Int] = [:], months: [String: Int] = [:]
        let calendar = Calendar.current
        for mail in mails {
            categories[mail.analysis?.category.rawValue ?? "未分类", default: 0] += 1
            let c = calendar.dateComponents([.year, .month], from: mail.date)
            months[String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0), default: 0] += 1
        }
        let monthly = ["monthly", "timeline", "trend"].contains(mode)
        let rows: [[String: Any]] = monthly ? months.keys.sorted().suffix(24).map { ["label": $0, "value": months[$0]!] } : categories.keys.sorted().map { ["label": $0, "value": categories[$0]!] }
        func json(_ value: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]), as: UTF8.self) }
        let title = monthly ? "本机邮件月度趋势" : "本机邮件分类分布"
        let note = scope + "；只统计已同步的实际数据，不代表服务器全部邮件。"
        let source = rows.isEmpty ? "root = TextContent(\(json("本轮范围没有邮件数据。")))" : "root = \(monthly ? "LineChart" : "BarChart")(\(json(title)), \(json(rows)), \(json(note)))"
        let summary = "本轮实际统计：" + json(["mailCount": mails.count, "unread": mails.filter { !$0.isRead }.count, "categories": categories, "monthlyCounts": months]) + "\n图表可直接复用以下真实数据的OpenUI：\n" + source
        return .init(summary: summary, chartSource: source)
    }
}
