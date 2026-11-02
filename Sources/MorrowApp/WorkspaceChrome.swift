import SwiftUI

struct WorkspacePageHeader<Actions: View>: View {
    let title: String
    var subtitle: String?
    let actions: Actions
    init(_ title: String, subtitle: String? = nil, @ViewBuilder actions: () -> Actions) { self.title = title; self.subtitle = subtitle; self.actions = actions() }
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.t(title)).font(Theme.title).foregroundStyle(Theme.ink)
                if let subtitle, !subtitle.isEmpty { Text(L10n.t(subtitle)).font(Theme.label).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 12)
            actions
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
extension WorkspacePageHeader where Actions == EmptyView {
    init(_ title: String, subtitle: String? = nil) { self.title = title; self.subtitle = subtitle; actions = EmptyView() }
}

struct WorkspaceSectionHeading<Actions: View>: View {
    let title: String
    let actions: Actions
    init(_ title: String, @ViewBuilder actions: () -> Actions) { self.title = title; self.actions = actions() }
    var body: some View {
        HStack(spacing: 12) { Text(L10n.t(title)).font(Theme.heading); Spacer(minLength: 0); actions }.frame(minHeight: 28)
    }
}
extension WorkspaceSectionHeading where Actions == EmptyView {
    init(_ title: String) { self.title = title; actions = EmptyView() }
}
