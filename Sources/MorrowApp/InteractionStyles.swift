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
        switch kind { case .primary: return compact ? 30 : 32; case .quiet: return 30; case .compact: return compact ? 28 : 30; case .icon: return 28; case .disclosure: return 28 }
    }
    private var filled: Bool { kind == .primary }
    private var outlined: Bool { [.quiet, .compact].contains(kind) }
    var body: some View {
        label
            .font(kind == .primary ? Theme.body.weight(.medium) : kind == .quiet ? Theme.body : Theme.label.weight(.medium))
            .foregroundStyle(filled ? Theme.onAccent : Theme.ink)
            .padding(.horizontal, kind == .icon ? 0 : kind == .disclosure ? 4 : 10)
            .frame(minWidth: kind == .icon ? 28 : nil, minHeight: height)
            .background(filled ? Theme.accent2.opacity(pressed ? 0.80 : hovering ? 0.92 : 1) : pressed ? Theme.selected : hovering ? Theme.hover : outlined ? Theme.sheet : Theme.clear, in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).stroke(focused ? Theme.focus : outlined ? Theme.fieldEdge : Theme.clear, lineWidth: focused ? 1.5 : 1))
            .contentShape(Rectangle()).opacity(enabled ? 1 : 0.45)
            .onHover { hovering = enabled && $0 }
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
        label.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).padding(.horizontal, 6)
            .foregroundStyle(accent ? Theme.accent2 : Theme.ink).background(pressed ? Theme.selected : hovered ? Theme.hover : Theme.clear, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(focused ? Theme.focus : Theme.clear, lineWidth: 1.5)).contentShape(Rectangle()).onHover { hovered = $0 }
    }
}
