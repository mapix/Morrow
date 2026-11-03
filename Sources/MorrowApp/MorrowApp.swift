import SwiftUI
import MorrowCore
import AppKit
import UserNotifications

@MainActor enum AppState { static let shared = AppModel() }

@main
struct MorrowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var model = AppState.shared
    @ObservedObject private var presentationState = PresentationPreferences.shared
    var body: some Scene {
        Window("Morrow", id: "main") {
            RootView(registerWindowAction: { action in delegate.openMainWindow = { action(id: "main") } }).environmentObject(model).environmentObject(presentationState).environment(\.locale, presentationState.locale).frame(minWidth: 1040, minHeight: 700).tint(Theme.accent2).preferredColorScheme(presentationState.colorScheme).task { await model.start(); delegate.model = model; if model.ready { delegate.drainPendingURLs() } }
                .onChange(of: presentationState.language) { model.settings.replyLanguage = presentationState.replyLanguageName }
        }.windowStyle(.hiddenTitleBar).windowBackgroundDragBehavior(.enabled).defaultSize(width: 1440, height: 900).commands {
            CommandMenu(L10n.t("伙伴")) { Button(L10n.t("给伙伴新要求")) { NotificationCenter.default.post(name: Notification.Name("MorrowFocusMission"), object: nil) }.keyboardShortcut("k") }
            CommandGroup(replacing: .newItem) {
                Button(L10n.t("新邮件")) { Task { await model.compose() } }.keyboardShortcut("n")
                Button(L10n.t("导入邮件与资料…")) { model.importFiles() }.keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandMenu(L10n.t("邮件")) {
                Button(L10n.t("搜索邮件")) { NotificationCenter.default.post(name: Notification.Name("MorrowFocusSearch"), object: nil) }.keyboardShortcut("f")
                Button(L10n.t("同步所有邮箱")) { Task { await model.sync(userInitiated: true) } }.keyboardShortcut("r")
                Button(L10n.t("回复")) { if let mail = model.selected { Task { await model.compose(replyTo: mail) } } }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button(L10n.t("归档")) { if let mail = model.selected { Task { await model.move(mail, role: "archive") } } }.keyboardShortcut("e")
                Button(L10n.t("移到废纸篓")) { if let mail = model.selected { Task { await model.move(mail, role: "trash") } } }.keyboardShortcut(.delete, modifiers: .command)
                Button(L10n.t("撤销上次操作")) { Task { await model.undo() } }.keyboardShortcut("z").disabled(model.undoLabel == nil)
            }
            CommandGroup(replacing: .appSettings) { Button(L10n.t("设置…")) { model.openSettings() }.keyboardShortcut(",") }
        }
        MenuBarExtra("Morrow", systemImage: "envelope") {
            MenuBarContent().environmentObject(model)
        }
    }
}

private struct MenuBarContent: View {
    @ObservedObject private var presentationState = PresentationPreferences.shared
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button(L10n.t("打开 Morrow")) { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Text(L10n.format("{0} 件待处理事项", "\(model.actionCount)"))
        Button(L10n.t("写邮件")) { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true); Task { await model.compose() } }
        Button(L10n.t("同步邮件")) { Task { await model.sync(userInitiated: true) } }
        Divider(); Button(L10n.t("退出 Morrow")) { NSApp.terminate(nil) }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var model: AppModel?
    var pendingURLs: [URL] = []
    private var pendingNotificationMailID: String?
    var openMainWindow: (() -> Void)?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); UNUserNotificationCenter.current().delegate = self
        model = AppState.shared
        Task { await AppState.shared.start(); drainPendingURLs(); NativePreview.renderIfRequested(model: AppState.shared) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.ready else { return .terminateNow }
        finishFocusedChatComposition()
        Task {
            do { try await model.flushCurrentSessionDraft(); model.stopBackgroundWork(); sender.reply(toApplicationShouldTerminate: true) }
            catch { model.error = "未发送输入尚未保存：" + error.localizedDescription; sender.reply(toApplicationShouldTerminate: false) }
        }
        return .terminateLater
    }
    func application(_ application: NSApplication, open urls: [URL]) { pendingURLs += urls; drainPendingURLs() }
    func drainPendingURLs() {
        guard let model, model.ready else { return }; let urls = pendingURLs; pendingURLs = []
        drainPendingNotification()
        Task { for url in urls {
            if url.scheme == "mailto", let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                await model.compose(); model.composer?.to = components.path.removingPercentEncoding ?? components.path
                model.composer?.subject = components.queryItems?.first { $0.name == "subject" }?.value ?? ""; model.composer?.body = components.queryItems?.first { $0.name == "body" }?.value ?? ""
            } else { await model.importFile(url) }
        }; await model.reload(); model.process() }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .list, .sound] }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let mailID = response.notification.request.content.userInfo["mailID"] as? String else { return }
        await openNotificationMail(mailID)
    }
    private func openNotificationMail(_ id: String) async {
        let model = model ?? AppState.shared
        pendingNotificationMailID = id
        if !model.ready { await model.start() }
        drainPendingNotification()
    }
    private func drainPendingNotification() {
        guard let model, model.ready, let id = pendingNotificationMailID else { return }
        pendingNotificationMailID = nil
        Task {
            guard await model.openArrivalNotificationMail(id: id) else { return }
            openMainWindow?(); NSApp.activate(ignoringOtherApps: true)
        }
    }
}
