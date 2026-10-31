import Foundation
import OSLog

enum MailReaderMetrics {
    private static let logger = Logger(subsystem: "app.smail.desktop", category: "MailReaderPerformance")
    static func record(_ stage: String, since started: TimeInterval) {
        let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
        logger.notice("\(stage, privacy: .public) milliseconds=\(milliseconds, privacy: .public)")
    }
}
