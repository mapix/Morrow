// Hallmark v2.0.0: Coral by user request. Native app scope, no top navigation bar; ongoing work and contextual OpenUI.
// Pre-emit critique: P5 H4 E3 S5 R4 V5. Weakest: execution; live native states must be verified after recomposition.
import SwiftUI
import AppKit

enum Theme {
    static var current: MorrowTheme { MorrowTheme(rawValue: UserDefaults.standard.string(forKey: "SmailPresentationTheme") ?? "coral") ?? .coral }
    static var active: ThemePalette { palette(for: current) }
    static func palette(for theme: MorrowTheme) -> ThemePalette {
        switch theme {
        case .coral: return ThemePalette(paper: 0xF8F4F1, sheet: 0xFDFBF8, sidebar: 0xF1ECE8, ink: 0x1D1714, secondary: 0x312926, muted: 0x625955, rule: 0xD9D3CF, accent: 0xEF8B7B, accent2: 0xBB3D31, focus: 0xBD3A2B, unreadPaper: 0xFBE3DC, selected: 0xE8E1DD, green: 0x465639, error: 0xBA2B28)
        case .slate: return ThemePalette(paper: 0xF4F6F8, sheet: 0xFFFFFF, sidebar: 0xE8EDF2, ink: 0x202F3A, secondary: 0x344B5D, muted: 0x586B78, rule: 0xCAD4DB, accent: 0x96BAD1, accent2: 0x32647F, focus: 0x246B94, unreadPaper: 0xE4EEF6, selected: 0xD5E2EA, green: 0x326249, error: 0xB23737)
        case .forest: return ThemePalette(paper: 0xF2F5F1, sheet: 0xFBFCF8, sidebar: 0xE5EBE1, ink: 0x24362B, secondary: 0x394D3D, muted: 0x596B5B, rule: 0xCAD4C7, accent: 0x97B39A, accent2: 0x326447, focus: 0x297143, unreadPaper: 0xE0ECDA, selected: 0xD8E2D3, green: 0x326447, error: 0xB33D2C)
        case .dark: return ThemePalette(paper: 0x1C242A, sheet: 0x242F36, sidebar: 0x172026, ink: 0xE9F0F3, secondary: 0xCDDAE2, muted: 0xA8B9C4, rule: 0x43525D, accent: 0xED9E89, accent2: 0xFFB29C, focus: 0xFFB29C, unreadPaper: 0x34323A, selected: 0x35424C, green: 0x9BCFA6, error: 0xFFACA5)
        }
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
    static var fieldEdge: Color { active.muted }
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
    static let title = Font.system(size: 30, weight: .semibold)
    static let heading = Font.system(size: 19, weight: .semibold)
    static let body = Font.system(size: 15)
    static let reader = Font.system(size: 15)
    static let label = Font.system(size: 12)
    static let small = Font.system(size: 11)
    static let wordmark = Font.system(size: 25, weight: .semibold, design: .rounded)
    static let navigation = Font.system(size: 14, weight: .medium)
    static let context = Font.system(size: 12, weight: .medium)
    static let sidebarWidth: CGFloat = 210
    static let compactControlHeight: CGFloat = 34
    static let readerTitle = Font.system(size: 25, weight: .semibold)
    static let actionIcon = Font.system(size: 18)
    static let emptyIcon = Font.system(size: 32, weight: .light)
    static let editorFont = NSFont.systemFont(ofSize: 15)
    static let radius: CGFloat = 8
    static let controlRadius: CGFloat = 8
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
        configuration.label.font(Theme.label.weight(.medium)).foregroundStyle(Theme.ink)
            .padding(.horizontal, 12).frame(minHeight: Theme.compactControlHeight)
            .background(configuration.isPressed ? Theme.selected : Theme.sheet, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(focused ? Theme.focus : Theme.rule, lineWidth: focused ? 1.5 : 1))
            .contentShape(Rectangle()).opacity(enabled ? 1 : 0.45)
    }
}

struct ChatSendButtonStyle: ButtonStyle {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Theme.body.weight(.semibold)).foregroundStyle(Theme.sheet)
            .frame(width: 36, height: 36)
            .background(Theme.ink.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(focused ? Theme.focus : Theme.clear, lineWidth: 2))
            .contentShape(Rectangle()).opacity(enabled ? 1 : 0.4)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Theme.body.weight(.medium)).foregroundStyle(Theme.paper).padding(.horizontal, 16).frame(minHeight: 48).background(Theme.ink.opacity(configuration.isPressed ? 0.86 : 1), in: RoundedRectangle(cornerRadius: Theme.controlRadius)).shadow(color: Theme.shadow.opacity(0.10), radius: 2, x: 2, y: 2).contentShape(Rectangle()).opacity(enabled ? 1 : 0.55)
    }
}
struct QuietButtonStyle: ButtonStyle {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(Theme.body).foregroundStyle(Theme.ink).padding(.horizontal, 12).frame(minHeight: 44).background(configuration.isPressed ? Theme.selected : Theme.sheet, in: RoundedRectangle(cornerRadius: Theme.radius)).overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.rule, lineWidth: 1)).shadow(color: Theme.shadow.opacity(0.08), radius: 2, x: 2, y: 1).contentShape(Rectangle()).opacity(enabled ? 1 : 0.55)
    }
}
struct IconButtonStyle: ButtonStyle {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle()).foregroundStyle(configuration.isPressed ? Theme.muted : Theme.ink).opacity(enabled ? 1 : 0.55)
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
        content.focused($focused).font(Theme.body).foregroundStyle(Theme.ink).padding(.horizontal, 8).frame(minHeight: 44).background(Theme.sheet, in: RoundedRectangle(cornerRadius: Theme.radius)).overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(focused ? Theme.focus : Theme.fieldEdge, lineWidth: 1)).opacity(enabled ? 1 : 0.55)
    }
}
struct EmptyRegion: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    var icon: String; var title: String; var detail: String; var action: String?; var perform: (() -> Void)?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: icon).font(Theme.emptyIcon).foregroundStyle(Theme.muted).accessibilityHidden(true)
            Text(title).font(Theme.heading).foregroundStyle(Theme.ink)
            Text(detail).font(Theme.body).foregroundStyle(Theme.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            if let action { Button(action) { perform?() }.buttonStyle(PrimaryButtonStyle()) }
        }.frame(maxWidth: 340, alignment: .leading).padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
