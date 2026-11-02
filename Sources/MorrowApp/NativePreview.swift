import AppKit
import SwiftUI
import MorrowCore

@MainActor enum NativePreview {
    /// Renders our own SwiftUI trees with local synthetic data. These artifacts
    /// are not OS screenshots and do not prove keyboard or pointer interaction.
    static func renderIfRequested(model: AppModel) {
        let args = ProcessInfo.processInfo.arguments
        if let flag = args.firstIndex(of: "--quality-gallery"), flag + 1 < args.count, model.isQualityPreview {
            Task {
                do { try await gallery(model: model, root: URL(fileURLWithPath: args[flag + 1])) }
                catch { fputs("Native quality gallery failed: \(error.localizedDescription)\n", stderr) }
                if args.contains("--quality-exit") { NSApp.terminate(nil) }
            }
            return
        }
        guard let flag = args.firstIndex(of: "--render-preview"), flag + 1 < args.count, model.isDemo || model.accounts.isEmpty else { return }
        let screen = args.firstIndex(of: "--preview-screen").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "work"
        Task {
            do {
                if model.isQualityPreview { try await UIQualityFixture.install(in: model) }
                let view = select(screen, model: model)
                try await capture(view, size: NSSize(width: 1440, height: 900), path: URL(fileURLWithPath: args[flag + 1]), dark: Theme.current == .dark)
            } catch { fputs("Native preview failed: \(error.localizedDescription)\n", stderr) }
        }
    }
    private static func gallery(model: AppModel, root: URL) async throws {
        guard Bundle.main.bundleIdentifier != "app.smail.desktop" else { throw MailError.message("Use a separate QA bundle for the quality gallery.") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await UIQualityFixture.install(in: model)
        let scenarios = ["work", "work-document", "inspector", "calendar", "memory-editor", "responder-editor", "inbox", "sent", "outbox", "drafts", "composer", "composer-readonly", "people", "person", "attachments", "attachment-image", "attachment-pdf", "briefs", "brief", "library", "history", "memory", "responders", "settings-accounts", "settings-appearance", "settings-sync", "settings-notifications", "settings-models", "settings-automation", "settings-budget", "settings-data", "account", "budget"]
        PresentationPreferences.shared.language = .simplifiedChinese
        var manifest: [[String: String]] = []
        for (mode, theme) in [("light", MorrowTheme.slate), ("dark", MorrowTheme.dark)] {
            PresentationPreferences.shared.theme = theme
            for (sizeName, size) in [("small", NSSize(width: 1040, height: 700)), ("normal", NSSize(width: 1440, height: 900))] {
                for screen in scenarios {
                    let filename = mode + "-" + sizeName + "-" + screen + ".png"
                    let view = select(screen, model: model)
                    try await capture(view, size: size, path: root.appendingPathComponent(filename), dark: theme == .dark)
                    manifest.append(["file": filename, "screen": screen, "appearance": mode, "viewport": "\(Int(size.width))x\(Int(size.height))", "evidence": "Native view content render; not OS interaction"])
                }
            }
        }
        PresentationPreferences.shared.theme = .slate
        PresentationPreferences.shared.language = .english
        for screen in ["work", "inbox", "composer", "people", "settings-models"] {
            let filename = "english-normal-" + screen + ".png"
            try await capture(select(screen, model: model), size: NSSize(width: 1440, height: 900), path: root.appendingPathComponent(filename), dark: false)
            manifest.append(["file": filename, "screen": screen, "language": "en", "evidence": "Native view content render"])
        }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
    }
    private static func select(_ screen: String, model: AppModel) -> AnyView {
        model.composer = nil; model.attachmentTextPreview = nil; model.selectedBriefID = nil; model.selectedID = nil; model.chatExpanded = true
        if screen.hasPrefix("settings-") {
            let category: SettingsCategory
            switch String(screen.dropFirst(9)) { case "appearance": category = .appearance; case "sync": category = .sync; case "notifications": category = .notifications; case "models": category = .models; case "automation": category = .automation; case "budget": category = .budget; case "data": category = .data; default: category = .accounts }
            model.navigate(.settings)
            return themed(RootView(previewSettingsCategory: category), model: model)
        }
        switch screen {
        case "work-document": if let run = model.agentRuns.first { model.selectRun(run) }
        case "inspector": if let run = model.agentRuns.first { model.selectRun(run) }; return themed(AgentInspectorView(), model: model)
        case "calendar": return themed(CalendarEditor(invitation: CalendarInvitation(title: "[示例] 项目评审", start: Date().addingTimeInterval(86400), end: Date().addingTimeInterval(90000), location: "示例会议室", detail: "界面验收资料，不会写入系统日历。")), model: model)
        case "memory-editor": if let memory = model.memories.first { return themed(MemoryEditor(initial: memory), model: model) }
        case "responder-editor": if let rule = model.responders.first { return themed(ResponderEditor(initial: rule), model: model) }
        case "inbox": model.navigate(.inbox); model.selectedID = model.mails.first { $0.id == "quality-source-0" }?.id
        case "sent": model.navigate(.sent)
        case "outbox": model.navigate(.outbox)
        case "drafts": model.navigate(.drafts)
        case "composer", "composer-readonly":
            model.navigate(.drafts)
            model.composer = model.drafts.first(where: { $0.id == (screen == "composer-readonly" ? "quality-sent" : "quality-draft") })
        case "people", "person":
            model.openWorkspace(.people); model.selectedContactEmail = screen == "person" ? model.contactProfiles.first?.email : nil
        case "attachments": model.openWorkspace(.attachments)
        case "attachment-image", "attachment-pdf":
            if let attachment = model.mails.first { $0.id == "quality-source-0" }?.attachments.first(where: { screen == "attachment-pdf" ? $0.mimeType == "application/pdf" : $0.mimeType.hasPrefix("image/") }) { return themed(AttachmentPreviewView(attachment: attachment), model: model) }
        case "briefs", "brief": model.openBriefs(); if screen == "brief" { model.selectedBriefID = model.briefArtifacts.first?.id }
        case "library": model.openWorkspace(.library)
        case "history": model.openWorkspace(.history)
        case "memory": model.openWorkspace(.memory)
        case "responders": model.openWorkspace(.responders)
        case "account": return themed(AccountSetupView(), model: model)
        case "budget": return themed(AgentBudgetSettingsSheet(), model: model)
        default: model.openWorkspace(.desk)
        }
        return themed(RootView(), model: model)
    }
    private static func themed<V: View>(_ view: V, model: AppModel) -> AnyView {
        AnyView(view.environmentObject(model).environmentObject(PresentationPreferences.shared).environment(\.locale, PresentationPreferences.shared.locale).tint(Theme.accent2).preferredColorScheme(PresentationPreferences.shared.colorScheme))
    }
    private static func capture(_ content: AnyView, size: NSSize, path: URL, dark: Bool) async throws {
        let view = NSHostingView(rootView: content)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isExcludedFromWindowsMenu = true; window.contentView = view
        window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw MailError.message("Native view could not render") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw MailError.message("Native view could not export") }
        try data.write(to: path, options: .atomic)
    }
}
