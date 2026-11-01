import SwiftUI

private struct CompactInteractionKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var compactInteraction: Bool {
        get { self[CompactInteractionKey.self] }
        set { self[CompactInteractionKey.self] = newValue }
    }
}

/// The complete heading is one native button; its text, chevron and remaining
/// row space share the same action and keyboard/accessibility behavior.
struct MorrowDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                        .frame(width: 12).accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(DisclosureHeadingStyle())
                .accessibilityValue(configuration.isExpanded ? L10n.t("已展开") : L10n.t("已收起"))
                .accessibilityHint(L10n.t("点击标题展开或收起"))
            if configuration.isExpanded {
                configuration.content.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 21).padding(.top, 8).padding(.bottom, 6)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
private struct DisclosureHeadingStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        InteractiveControlBody(label: configuration.label, pressed: configuration.isPressed, kind: .disclosure)
    }
}

enum InteractiveControlKind: Equatable { case primary, quiet, compact, icon, disclosure }
struct InteractiveControlBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    let kind: InteractiveControlKind
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.compactInteraction) private var compact
    private var height: CGFloat {
        switch kind { case .primary: return compact ? 34 : 42; case .quiet: return compact ? 30 : 36; case .compact: return compact ? 30 : 34; case .icon: return 32; case .disclosure: return compact ? 30 : 34 }
    }
    private var filled: Bool { kind == .primary }
    private var outlined: Bool { [.quiet, .compact].contains(kind) }
    var body: some View {
        label
            .font(kind == .primary ? Theme.body.weight(.medium) : kind == .quiet ? Theme.body : Theme.label.weight(.medium))
            .foregroundStyle(filled ? Theme.sheet : Theme.ink)
            .padding(.horizontal, kind == .icon ? 0 : kind == .disclosure ? 7 : 12)
            .frame(minWidth: kind == .icon ? 32 : nil, minHeight: height)
            .background(filled ? Theme.ink.opacity(pressed ? 0.80 : hovering ? 0.92 : 1) : pressed ? Theme.selected : hovering ? Theme.selected.opacity(0.55) : outlined ? Theme.sheet : Theme.clear, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).stroke(focused ? Theme.focus : outlined ? Theme.rule : Theme.clear, lineWidth: focused ? 1.5 : 1))
            .contentShape(Rectangle()).opacity(enabled ? 1 : 0.45)
            .onHover { hovering = $0 }
    }
}

struct ToolbarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        InteractiveControlBody(label: configuration.label, pressed: configuration.isPressed, kind: .icon)
    }
}
struct ReferenceRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ReferenceRowBody(label: configuration.label, pressed: configuration.isPressed)
    }
}
struct ListRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { ReferenceRowBody(label: configuration.label, pressed: configuration.isPressed, accent: false) }
}
private struct ReferenceRowBody<Label: View>: View {
    let label: Label
    let pressed: Bool
    var accent = true
    @State private var hovered = false
    @Environment(\.isFocused) private var focused
    var body: some View {
        label.frame(maxWidth: .infinity, minHeight: 32, alignment: .leading).padding(.horizontal, 7)
            .foregroundStyle(accent ? Theme.accent2 : Theme.ink).background(pressed || hovered ? Theme.selected.opacity(0.55) : Theme.clear, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(focused ? Theme.focus : Theme.clear, lineWidth: 1.5)).contentShape(Rectangle()).onHover { hovered = $0 }
    }
}
