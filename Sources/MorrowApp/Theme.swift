// Morrow native workbench: correspondence, delivery state and evidence define the hierarchy.
// Shared semantic tokens serve every page, control and embedded document.
import SwiftUI
import AppKit

enum Theme {
    static var current: MorrowTheme {
        let selected = MorrowTheme(rawValue: UserDefaults.standard.string(forKey: PresentationPreferences.themeKey) ?? "system") ?? .system
        if selected == .system { return NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .slate }
        return selected == .dark ? .dark : .slate
    }
    static var active: ThemePalette { palette(for: current) }
    private static let lightPalette = ThemePalette(paper: 0xF4F5F7, sheet: 0xFFFFFF, sidebar: 0xECEFF3, ink: 0x212A35, secondary: 0x4F5A68, muted: 0x667180, rule: 0xDDE1E7, accent: 0x2B61AF, accent2: 0x2B61AF, focus: 0x2B61AF, unreadPaper: 0xF4F7FC, selected: 0xDCE7F7, green: 0x327356, error: 0xBB3C3C)
    private static let darkPalette = ThemePalette(paper: 0x1B1E23, sheet: 0x22262D, sidebar: 0x181B20, ink: 0xE9EDF3, secondary: 0xC3CAD4, muted: 0x9BA6B5, rule: 0x383F49, accent: 0x8DBDFF, accent2: 0x8DBDFF, focus: 0x8DBDFF, unreadPaper: 0x252F3B, selected: 0x2C3D54, green: 0x83C7A4, error: 0xF19494)
    static func palette(for theme: MorrowTheme) -> ThemePalette {
        theme == .dark || (theme == .system && current == .dark) ? darkPalette : lightPalette
    }
    static var paper: Color { active.paper }
    static var sheet: Color { active.sheet }
    static var sidebar: Color { active.sidebar }
    static var ink: Color { active.ink }
    static var secondary: Color { active.secondary }
    static var muted: Color { active.muted }
    static var rule: Color { active.rule }
    static var accent: Color { active.accent }
    static var accent2: Color { active.accent2 }
    static var accentInk: Color { current == .dark ? active.paper : active.ink }
    static var unreadInk: Color { active.ink }
    static var focus: Color { active.focus }
    static var fieldEdge: Color { current == .dark ? Color(hex: 0x525C6B) : Color(hex: 0xC5CCD6) }
    static var onAccent: Color { current == .dark ? Color(hex: 0x172A43) : Color.white }
    static var hover: Color { active.ink.opacity(current == .dark ? 0.08 : 0.045) }
    static var chartPalette: [Color] { [accent2, Color(hex: 0x368080), Color(hex: 0x8A6AAA), Color(hex: 0xB07D36), Color(hex: 0x6B7C91), green] }
    static var unreadPaper: Color { active.unreadPaper }
    static var selected: Color { active.selected }
    static var green: Color { active.green }
    static var greenSoft: Color { active.sidebar }
    static var error: Color { active.error }
    static var documentPaper: Color { active.sheet }
    static var documentInk: Color { active.ink }
    static let documentExportInk = Color(red: 0.11524, green: 0.08817, blue: 0.07974)
    static let shadow = Color(red: 0, green: 0, blue: 0)
    static let clear = Color.clear
    static let title = Font.system(size: 22, weight: .semibold)
    static let heading = Font.system(size: 15, weight: .semibold)
    static let body = Font.system(size: 13)
    static let reader = Font.system(size: 15)
    static let label = Font.system(size: 12)
    static let small = Font.system(size: 11)
    static let wordmark = Font.system(size: 19, weight: .semibold)
    static let navigation = Font.system(size: 13, weight: .medium)
    static let context = Font.system(size: 12, weight: .medium)
    static let sidebarWidth: CGFloat = 200
    static let compactControlHeight: CGFloat = 30
    static let readerTitle = Font.system(size: 21, weight: .semibold)
    static let actionIcon = Font.system(size: 16)
    static let emptyIcon = Font.system(size: 24, weight: .regular)
    static let editorFont = NSFont.systemFont(ofSize: 15)
    static let radius: CGFloat = 6
    static let controlRadius: CGFloat = 5
    static var htmlTokens: String { active.htmlTokens }
    static var readerHTMLOverrides: String {
        current == .dark ? "body{color-scheme:dark;}body,body div,body p,body span,body td,body th,body table{color:var(--ink)!important;background-color:var(--paper)!important;}body a{color:var(--ink)!important;text-decoration:underline;}" : ""
    }
}

struct ThemePalette {
    let paper, sheet, sidebar, ink, secondary, muted, rule, accent, accent2, focus, unreadPaper, selected, green, error: Color
    let htmlTokens: String
    init(paper: UInt32, sheet: UInt32, sidebar: UInt32, ink: UInt32, secondary: UInt32, muted: UInt32, rule: UInt32, accent: UInt32, accent2: UInt32, focus: UInt32, unreadPaper: UInt32, selected: UInt32, green: UInt32, error: UInt32) {
        func color(_ hex: UInt32) -> Color { Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255) }
        self.paper = color(paper); self.sheet = color(sheet); self.sidebar = color(sidebar); self.ink = color(ink); self.secondary = color(secondary); self.muted = color(muted); self.rule = color(rule); self.accent = color(accent); self.accent2 = color(accent2); self.focus = color(focus); self.unreadPaper = color(unreadPaper); self.selected = color(selected); self.green = color(green); self.error = color(error)
        htmlTokens = String(format: ":root{--paper:#%06x;--ink:#%06x;--muted:#%06x;--rule:#%06x;--font:system-ui,-apple-system,sans-serif;}", sheet, ink, muted, rule)
    }
}

struct CompactButtonStyle: ButtonStyle {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        InteractiveControlBody(label: configuration.label, pressed: configuration.isPressed, kind: .compact)
    }
}

struct ChatSendButtonStyle: ButtonStyle {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Theme.body.weight(.semibold)).foregroundStyle(Theme.onAccent)
            .frame(width: 30, height: 30)
            .background(Theme.accent2.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(focused ? Theme.focus : Theme.clear, lineWidth: 2))
            .contentShape(Rectangle()).opacity(enabled ? 1 : 0.4)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        InteractiveControlBody(label: configuration.label, pressed: configuration.isPressed, kind: .primary)
    }
}
struct QuietButtonStyle: ButtonStyle {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        InteractiveControlBody(label: configuration.label, pressed: configuration.isPressed, kind: .quiet)
    }
}
struct IconButtonStyle: ButtonStyle {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        InteractiveControlBody(label: configuration.label, pressed: configuration.isPressed, kind: .icon)
    }
}
struct PaperFieldStyle: TextFieldStyle {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    func _body(configuration: TextField<Self._Label>) -> some View {
        PaperFieldBody(content: configuration.textFieldStyle(.plain))
    }
}
private struct PaperFieldBody<Content: View>: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    let content: Content
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        content.focused($focused).font(Theme.body).foregroundStyle(Theme.ink).padding(.horizontal, 8).frame(minHeight: 30).background(Theme.sheet, in: RoundedRectangle(cornerRadius: Theme.radius)).overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(focused ? Theme.focus : Theme.fieldEdge, lineWidth: 1)).opacity(enabled ? 1 : 0.55)
    }
}
struct EmptyRegion: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    var icon: String; var title: String; var detail: String; var action: String?; var perform: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon).font(Theme.emptyIcon).foregroundStyle(Theme.muted).accessibilityHidden(true)
            Text(title).font(Theme.heading).foregroundStyle(Theme.ink)
            Text(detail).font(Theme.body).foregroundStyle(Theme.muted).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            if let action { Button(action) { perform?() }.buttonStyle(PrimaryButtonStyle()) }
        }.frame(maxWidth: 360, alignment: .leading).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255) }
}
