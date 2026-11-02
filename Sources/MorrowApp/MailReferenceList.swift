import SwiftUI
import MorrowCore

/// Retains every reference in source order while bounding the rendered page.
struct MailReferencePages: Equatable, Sendable {
    let ids: [String]
    let pageSize: Int
    init(ids: [String], pageSize: Int = 50) {
        var seen = Set<String>()
        self.ids = ids.filter { seen.insert($0).inserted }
        self.pageSize = min(50, max(1, pageSize))
    }
    var count: Int { ids.count }
    var pageCount: Int { (count + pageSize - 1) / pageSize }
    func clampedPage(_ page: Int) -> Int { max(0, min(page, pageCount - 1)) }
    func range(_ page: Int) -> Range<Int> {
        let start = clampedPage(page) * pageSize
        return start..<min(count, start + pageSize)
    }
    func visibleIDs(_ page: Int, expanded: Bool) -> [String] {
        expanded ? Array(ids[range(page)]) : []
    }
}

struct MailReferenceList: View {
    @EnvironmentObject private var model: AppModel
    let ids: [String]
    var title: String? = nil
    var collapsible = true
    var showsDetails = false
    let open: (MailMessage) -> Void
    @State private var expanded = false
    @State private var page = 0
    private var pages: MailReferencePages { .init(ids: ids) }
    var body: some View {
        let pages = pages
        Group {
            if pages.count > 0 {
                if collapsible {
                    DisclosureGroup(isExpanded: $expanded) {
                        // DisclosureGroup can build hidden content. Do not
                        // resolve any mail metadata until the user expands it.
                        if expanded { pageContent(pages) }
                    } label: { Text(title ?? L10n.format("依据邮件（{0}）", String(pages.count))) }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        if let title { Text(title).foregroundStyle(Theme.secondary) }
                        pageContent(pages)
                    }
                }
            }
        }.font(Theme.label).onChange(of: ids) { page = 0; expanded = false }
    }
    private func pageContent(_ pages: MailReferencePages) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if pages.pageCount > 1 { pageControls(pages) }
            ForEach(pages.visibleIDs(page, expanded: !collapsible || expanded), id: \.self) { id in
                referenceRow(id)
            }
            if pages.pageCount > 1 { pageControls(pages) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func pageControls(_ pages: MailReferencePages) -> some View {
        let range = pages.range(page), current = pages.clampedPage(page)
        return HStack(spacing: 12) {
            Text("\(range.lowerBound + 1)–\(range.upperBound) / \(pages.count)").monospacedDigit().foregroundStyle(Theme.secondary)
                .accessibilityIdentifier("mail.references.range")
            Spacer(minLength: 0)
            Button(L10n.t("上一页")) { page = current - 1 }.disabled(current == 0)
                .accessibilityIdentifier("mail.references.previous")
            Button(L10n.t("下一页")) { page = current + 1 }.disabled(current + 1 >= pages.pageCount)
                .accessibilityIdentifier("mail.references.next")
        }.buttonStyle(CompactButtonStyle()).padding(.vertical, 8)
    }
    @ViewBuilder private func referenceRow(_ id: String) -> some View {
        // The cache is indexed by ID; do not scan the complete mailbox or load
        // raw MIME/body data while building a reference list.
        if let mail = model.mailByID(id) {
            Button {
                if let current = model.mailByID(id) { open(current) }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Label(mail.subject.isEmpty ? L10n.t("打开无主题原邮件") : mail.subject, systemImage: "envelope.open")
                        .lineLimit(2).multilineTextAlignment(.leading)
                    if showsDetails {
                        HStack { Text(mail.from.display).lineLimit(1); Spacer(); Text(mail.date.uiFormatted(date: .abbreviated, time: .omitted)) }
                            .font(Theme.small).foregroundStyle(Theme.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(ReferenceRowButtonStyle()).accessibilityIdentifier("mail.references.open")
                .accessibilityLabel(L10n.t("查看原邮件：") + mail.subject)
        } else {
            Text(L10n.t("一封引用的原邮件暂不可用。")).foregroundStyle(Theme.secondary).padding(.vertical, 12)
                .accessibilityIdentifier("mail.references.unavailable")
        }
    }
}
