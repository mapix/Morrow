import XCTest
import AppKit
import SwiftUI
@testable import MorrowApp

final class PresentationTests: XCTestCase {
    @MainActor func testPresentationChoicesPersistWithCoralAsDefault() throws {
        let suite = "MorrowPresentationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = PresentationPreferences(defaults: defaults)
        XCTAssertEqual(first.theme, .coral)
        XCTAssertEqual(first.language, .system)
        first.theme = .dark; first.language = .japanese
        let reopened = PresentationPreferences(defaults: defaults)
        XCTAssertEqual(reopened.theme, .dark)
        XCTAssertEqual(reopened.language, .japanese)
        XCTAssertEqual(reopened.replyLanguageName, "Japanese")
        defaults.set("unknown-theme", forKey: PresentationPreferences.themeKey)
        XCTAssertEqual(PresentationPreferences(defaults: defaults).theme, .coral)
    }

    func testLocalizedTemplatePreservesUntrustedUserTextVerbatim() {
        let user = "Contract {1} / 合同 / \"don't replace\""
        let template = L10n.localized("往来{0}封，收到{1}封，发给对方{2}封", code: "en")
        XCTAssertEqual(L10n.substitute(template, values: [user, "3", "4"]), user + " exchanged, 3 received, 4 sent")
        XCTAssertEqual(L10n.localized(user, code: "ja"), user)
        XCTAssertEqual(L10n.status("正在读：" + user, code: "en"), "Reading: " + user)
        XCTAssertEqual(L10n.status("正在同步 My personal mailbox / Inbox", code: "ja"), "My personal mailbox / Inboxを同期中")
    }

    func testAllCatalogLanguagesKeepTheSameTemplateArguments() throws {
        let expression = try NSRegularExpression(pattern: "\\{[0-9]+\\}")
        func arguments(_ text: String) -> [String] {
            expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }.sorted()
        }
        for (source, translations) in L10n.catalog {
            XCTAssertFalse(translations.0.isEmpty, source)
            XCTAssertFalse(translations.1.isEmpty, source)
            XCTAssertEqual(arguments(source), arguments(translations.0), source)
            XCTAssertEqual(arguments(source), arguments(translations.1), source)
        }
    }

    @MainActor func testThemeTextAndUnreadStateHaveAccessibleContrast() throws {
        func luminance(_ color: Color) throws -> Double {
            let rgb = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
            func linear(_ value: CGFloat) -> Double { value <= 0.04045 ? Double(value) / 12.92 : pow((Double(value) + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
        }
        func contrast(_ foreground: Color, _ background: Color) throws -> Double {
            let a = try luminance(foreground), b = try luminance(background)
            return (max(a,b) + 0.05) / (min(a,b) + 0.05)
        }
        for theme in MorrowTheme.allCases {
            let palette = Theme.palette(for: theme)
            XCTAssertGreaterThanOrEqual(try contrast(palette.ink, palette.sheet), 4.5, theme.rawValue)
            XCTAssertGreaterThanOrEqual(try contrast(palette.muted, palette.paper), 4.5, theme.rawValue)
            XCTAssertGreaterThanOrEqual(try contrast(palette.ink, palette.unreadPaper), 4.5, theme.rawValue)
            XCTAssertGreaterThanOrEqual(try contrast(palette.accent2, palette.sheet), 4.5, theme.rawValue)
        }
    }
}
