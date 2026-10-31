import Foundation
import SwiftUI

enum MorrowLanguage: String, CaseIterable, Identifiable {
    case system, simplifiedChinese = "zh-Hans", english = "en", japanese = "ja"
    var id: String { rawValue }
    var nativeName: String {
        switch self { case .system: return L10n.t("跟随系统"); case .simplifiedChinese: return "简体中文"; case .english: return "English"; case .japanese: return "日本語" }
    }
    var resolvedCode: String {
        guard self == .system else { return rawValue }
        let preferred = Locale.preferredLanguages.first ?? "en"
        if preferred.hasPrefix("zh") { return "zh-Hans" }
        if preferred.hasPrefix("ja") { return "ja" }
        return "en"
    }
}

enum MorrowTheme: String, CaseIterable, Identifiable {
    case coral, slate, forest, dark
    var id: String { rawValue }
    var title: String {
        switch self { case .coral: return "Coral"; case .slate: return L10n.t("雾蓝"); case .forest: return L10n.t("青苔"); case .dark: return L10n.t("夜色") }
    }
    var colorScheme: ColorScheme { self == .dark ? .dark : .light }
}

/// Presentation choices are local to this device. Changing them never recreates
/// the workspace, clears a working draft, or changes stored operation identifiers.
enum MailReadingPreferences {
    static let externalImagesKey = "SmailLoadExternalImagesByDefault"
    static func loadsExternalImages(defaults: UserDefaults = .standard) -> Bool { (defaults.object(forKey: externalImagesKey) as? Bool) ?? true }
}

@MainActor final class PresentationPreferences: ObservableObject {
    static let shared = PresentationPreferences()
    static let languageKey = "SmailPresentationLanguage"
    static let themeKey = "SmailPresentationTheme"
    @Published var language: MorrowLanguage { didSet { defaults.set(language.rawValue, forKey: Self.languageKey) } }
    @Published var theme: MorrowTheme { didSet { defaults.set(theme.rawValue, forKey: Self.themeKey) } }
    @Published var loadExternalImagesByDefault: Bool { didSet { defaults.set(loadExternalImagesByDefault, forKey: MailReadingPreferences.externalImagesKey) } }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = MorrowLanguage(rawValue: defaults.string(forKey: Self.languageKey) ?? "system") ?? .system
        theme = MorrowTheme(rawValue: defaults.string(forKey: Self.themeKey) ?? "coral") ?? .coral
        loadExternalImagesByDefault = MailReadingPreferences.loadsExternalImages(defaults: defaults)
    }
    var locale: Locale { Locale(identifier: language.resolvedCode) }
    var colorScheme: ColorScheme { theme.colorScheme }
    var replyLanguageName: String {
        switch language.resolvedCode { case "zh-Hans": return "Simplified Chinese"; case "ja": return "Japanese"; default: return "English" }
    }
}

struct PresentationSettingsView: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.t("语言与外观")).font(Theme.heading)
            Divider().overlay(Theme.rule)
            Picker(L10n.t("界面语言"), selection: $presentationState.language) {
                ForEach(MorrowLanguage.allCases) { Text($0.nativeName).tag($0) }
            }.frame(maxWidth: 360)
            Toggle(L10n.t("默认加载邮件外部图片"), isOn: $presentationState.loadExternalImagesByDefault)
            HStack(alignment: .top, spacing: 12) {
                ForEach(MorrowTheme.allCases) { theme in
                    Button { presentationState.theme = theme } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 0) {
                                Rectangle().fill(Theme.palette(for: theme).sidebar).frame(width: 22)
                                VStack(alignment: .leading, spacing: 5) {
                                    RoundedRectangle(cornerRadius: 2).fill(Theme.palette(for: theme).ink).frame(width: 46, height: 4)
                                    RoundedRectangle(cornerRadius: 2).fill(Theme.palette(for: theme).accent).frame(width: 34, height: 4)
                                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading).padding(9).background(Theme.palette(for: theme).sheet)
                            }.frame(height: 42).clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                            HStack { Text(theme.title).font(Theme.label.weight(.medium)); Spacer(minLength: 0); if theme == presentationState.theme { Image(systemName: "checkmark").font(Theme.label).foregroundStyle(Theme.accent2) } }
                        }.padding(10).frame(width: 112).background(Theme.sheet, in: RoundedRectangle(cornerRadius: Theme.radius))
                            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(theme == presentationState.theme ? Theme.focus : Theme.rule, lineWidth: theme == presentationState.theme ? 1.5 : 1))
                    }.buttonStyle(.plain).accessibilityLabel(theme.title).accessibilityAddTraits(theme == presentationState.theme ? .isSelected : [])
                }
            }
            Text(L10n.t("立即生效，当前输入和工作范围会保留。")).font(Theme.label).foregroundStyle(Theme.muted)
        }
    }
}
