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
    case system, coral, slate, forest, dark
    static var selectable: [Self] { [.system, .slate, .dark] }
    var id: String { rawValue }
    var title: String {
        switch self { case .system: return L10n.t("跟随系统"); case .coral, .slate, .forest: return L10n.t("浅色"); case .dark: return L10n.t("深色") }
    }
    var colorScheme: ColorScheme? { self == .system ? nil : self == .dark ? .dark : .light }
}

/// Presentation choices are local to this device. Changing them never recreates
/// the workspace, clears a working draft, or changes stored operation identifiers.
enum MailReadingPreferences {
    static let externalImagesKey = "SmailLoadExternalImagesByDefault"
    static func loadsExternalImages(defaults: UserDefaults = .standard) -> Bool { (defaults.object(forKey: externalImagesKey) as? Bool) ?? true }
}

@MainActor final class PresentationPreferences: ObservableObject {
    static let shared = PresentationPreferences()
    nonisolated static let languageKey = "SmailPresentationLanguage"
    nonisolated static let themeKey = "SmailPresentationTheme"
    @Published var language: MorrowLanguage { didSet { defaults.set(language.rawValue, forKey: Self.languageKey) } }
    @Published var theme: MorrowTheme { didSet { defaults.set(theme.rawValue, forKey: Self.themeKey) } }
    @Published var loadExternalImagesByDefault: Bool { didSet { defaults.set(loadExternalImagesByDefault, forKey: MailReadingPreferences.externalImagesKey) } }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        language = MorrowLanguage(rawValue: defaults.string(forKey: Self.languageKey) ?? "system") ?? .system
        let saved = MorrowTheme(rawValue: defaults.string(forKey: Self.themeKey) ?? "system") ?? .system
        let effective = [.coral, .forest].contains(saved) ? MorrowTheme.slate : saved
        theme = effective
        if effective != saved { defaults.set(effective.rawValue, forKey: Self.themeKey) }
        loadExternalImagesByDefault = MailReadingPreferences.loadsExternalImages(defaults: defaults)
    }
    var locale: Locale { Locale(identifier: language.resolvedCode) }
    var colorScheme: ColorScheme? { theme.colorScheme }
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
            Picker(L10n.t("外观"), selection: $presentationState.theme) {
                ForEach(MorrowTheme.selectable) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).frame(maxWidth: 360).accessibilityIdentifier("settings.appearance")
            Text(L10n.t("立即生效，当前输入和工作范围会保留。")).font(Theme.label).foregroundStyle(Theme.muted)
        }
    }
}
