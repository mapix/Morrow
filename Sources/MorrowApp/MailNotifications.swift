import Foundation
import UserNotifications

enum MailNotificationPermission: String, Sendable {
    case unknown, notDetermined, denied, authorized, provisional
    var allowsDelivery: Bool { self == .authorized || self == .provisional }
}

@MainActor protocol MailNotificationManaging {
    func removePending(_ ids: [String])
    func requestAuthorization() async throws -> Bool
    func permission() async -> MailNotificationPermission
    func add(id: String, title: String, body: String, at date: Date?) async throws
    func addMail(id: String, title: String, body: String, mailID: String) async throws
}
extension MailNotificationManaging {
    func permission() async -> MailNotificationPermission { .unknown }
    func addMail(id: String, title: String, body: String, mailID: String) async throws { try await add(id: id, title: title, body: body, at: nil) }
}
@MainActor final class NativeMailNotifications: MailNotificationManaging {
    func removePending(_ ids: [String]) { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids) }
    func requestAuthorization() async throws -> Bool { try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
    func permission() async -> MailNotificationPermission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
        @unknown default: return .unknown
        }
    }
    func addMail(id: String, title: String, body: String, mailID: String) async throws {
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
        content.userInfo = ["mailID": mailID]
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
    func add(id: String, title: String, body: String, at date: Date?) async throws {
        let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
        let trigger = date.map { UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0.timeIntervalSinceNow), repeats: false) }
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
