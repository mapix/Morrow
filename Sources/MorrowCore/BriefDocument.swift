import Foundation

public struct BriefDocument: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case inProgress = "in_progress", needsReview = "needs_review", complete }
    public struct Table: Codable, Sendable {
        public var title: String
        public var columns: [String]
        public var rows: [[String]]
        public init(title: String, columns: [String], rows: [[String]]) { self.title = title; self.columns = columns; self.rows = rows }
    }
    public var summary: String = ""
    public var status: Status = .needsReview
    public var coverage: String = ""
    public var findings: [String] = []
    public var actions: [String] = []
    public var uncertainties: [String] = []
    public var tables: [Table] = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case summary, status, coverage, findings, actions, uncertainties, tables }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .needsReview
        coverage = try c.decodeIfPresent(String.self, forKey: .coverage) ?? ""
        findings = try c.decodeIfPresent([String].self, forKey: .findings) ?? []
        actions = try c.decodeIfPresent([String].self, forKey: .actions) ?? []
        uncertainties = try c.decodeIfPresent([String].self, forKey: .uncertainties) ?? []
        tables = try c.decodeIfPresent([Table].self, forKey: .tables) ?? []
    }
    public func validated() throws -> Self {
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, summary.count <= 2000, coverage.count <= 8000,
              [findings, actions, uncertainties].allSatisfy({ $0.count <= 40 && $0.allSatisfy { !$0.isEmpty && $0.count <= 8000 } }),
              tables.count <= 8, tables.allSatisfy({ table in !table.columns.isEmpty && table.columns.count <= 8 && table.rows.count <= 100 && table.rows.allSatisfy { $0.count == table.columns.count } }) else { throw MailError.message("简报结构无效：请提供摘要、有限条目和列数一致的数据表。") }
        guard try JSONEncoder().encode(self).count <= 128 * 1024 else { throw MailError.message("简报超过大小限制。") }
        return self
    }
    public var markdown: String {
        var sections = ["## 摘要\n\n" + summary]
        if !coverage.isEmpty { sections.append("## 覆盖范围与进度\n\n" + coverage) }
        for (title, items) in [("关键发现", findings), ("待办事项", actions), ("待核实", uncertainties)] where !items.isEmpty { sections.append("## " + title + "\n\n" + items.map { "- " + $0 }.joined(separator: "\n")) }
        for table in tables {
            let row = { (cells: [String]) in "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>") }.joined(separator: " | ") + " |" }
            sections.append("## " + table.title + "\n\n" + ([row(table.columns), row(table.columns.map { _ in "---" })] + table.rows.map(row)).joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }
    /// A display projection only: retain the original paragraphs, without inferring facts or completion.
    public static func legacy(_ text: String, title: String) -> Self {
        var result = Self()
        let paragraphs = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var section = "findings"
        for paragraph in paragraphs {
            let plain = paragraph.replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
            if plain == title { continue }
            if paragraph.hasPrefix("#"), !plain.contains("\n") {
                let categories = ["摘要":"summary", "结论":"summary", "覆盖范围与进度":"coverage", "关键发现":"findings", "待办事项":"actions", "待核实":"uncertainties"]
                if let category = categories[plain] { section = category; continue }
                section = "findings"
            }
            if plain.range(of: #"^(未完成|当前进度|当前状态|覆盖范围|已执行|范围)"#, options: .regularExpression) != nil { result.coverage += (result.coverage.isEmpty ? "" : "\n\n") + paragraph }
            else if plain.range(of: #"^(下一步|后续|待办|行动)"#, options: .regularExpression) != nil { result.actions.append(paragraph) }
            else if plain.range(of: #"^(待确认|待核实|未确认|不确定|风险)"#, options: .regularExpression) != nil { result.uncertainties.append(paragraph) }
            else if result.summary.isEmpty, plain.range(of: #"^(摘要|结论)"#, options: .regularExpression) != nil { result.summary = paragraph }
            else {
                switch section {
                case "summary": result.summary += (result.summary.isEmpty ? "" : "\n\n") + paragraph
                case "coverage": result.coverage += (result.coverage.isEmpty ? "" : "\n\n") + paragraph
                case "actions": result.actions.append(paragraph)
                case "uncertainties": result.uncertainties.append(paragraph)
                default: result.findings.append(paragraph)
                }
            }
        }
        return result
    }
}
