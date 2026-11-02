import Foundation
import MorrowCore

/// UI acceptance is opt-in and cannot silently fall back to a remembered or
/// production mailbox. No credentials, models or network work are started.
struct QualityPreviewRequest: Equatable {
    let directory: URL
    static func parse(arguments: [String]) throws -> Self? {
        guard arguments.contains("--quality-preview") else { return nil }
        guard arguments.contains("--transient-workspace"), let index = arguments.firstIndex(of: "--data-dir"), arguments.indices.contains(index + 1),
              arguments[index + 1].hasPrefix("/"), !arguments[index + 1].hasPrefix("--") else { throw MailError.message("--quality-preview 需要显式绝对 --data-dir 与 --transient-workspace。") }
        return .init(directory: URL(fileURLWithPath: arguments[index + 1], isDirectory: true).standardizedFileURL)
    }
}
