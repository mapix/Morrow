import Foundation
import UserNotifications

@MainActor protocol MailNotificationManaging {
    func removePending(_ ids: [String])
    func requestAuthorization() async throws -> Bool
    func add(id: String, title: String, body: String, at date: Date?) async throws
}
@MainActor final class NativeMailNotifications: MailNotificationManaging {
    func removePending(_ ids: [String]) { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids) }
    func requestAuthorization() async throws -> Bool { try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
    func add(id: String, title: String, body: String, at date: Date?) async throws {
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
        let trigger = date.map { UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0.timeIntervalSinceNow), repeats: false) }
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
