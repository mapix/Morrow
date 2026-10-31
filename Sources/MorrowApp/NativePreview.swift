import AppKit
import SwiftUI
import MorrowCore

@MainActor enum NativePreview {
    /// Renders our own view tree into an artifact. It does not capture the screen or operate OS UI.
    static func renderIfRequested(model: AppModel) {
        let args = ProcessInfo.processInfo.arguments
        guard let flag = args.firstIndex(of: "--render-preview"), flag + 1 < args.count else { return }
        guard model.isDemo || model.accounts.isEmpty else { return }
        let screen = args.firstIndex(of: "--preview-screen").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "partner"
        if screen == "inbox" { model.navigate(.inbox); model.selectedID = model.mails.first?.id }
        if screen == "settings" { model.navigate(.settings) }
        let content: AnyView
        let size: NSSize
        if screen == "account" {
            content = AnyView(AccountSetupView().environmentObject(model).tint(Theme.accent2).preferredColorScheme(.dark)); size = NSSize(width: 640, height: 760)
        } else if screen == "composer" {
            var draft = ComposeDraft(); draft.accountID = model.accounts.first?.id ?? "demo"; draft.to = "team@example.com"; draft.subject = "[示例] Re: 项目评审"; draft.body = "收到项目评审邀请。我会先确认日程，再回复是否参加。\n\n请提前发送评审材料，谢谢。"
            content = AnyView(ComposerView(initial: draft).environmentObject(model).tint(Theme.accent2).preferredColorScheme(.dark)); size = NSSize(width: 820, height: 720)
        } else {
            content = AnyView(RootView().environmentObject(model).tint(Theme.accent2).preferredColorScheme(.dark)); size = NSSize(width: 1440, height: 900)
        }
        let view = NSHostingView(rootView: content)
        view.appearance = NSAppearance(named: .darkAqua)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: args[flag + 1])) }
    }
}
