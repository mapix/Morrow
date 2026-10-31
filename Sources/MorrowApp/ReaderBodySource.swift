import Foundation
import MorrowCore

struct ReaderBodyRequest: Equatable, Sendable {
    var id: String
    var version: String
    var retry: Int = 0
}

struct ReaderBodyTicket: Equatable, Sendable {
    var request: ReaderBodyRequest
    var sequence: Int
}

struct ReaderBodySelection {
    private(set) var ticket: ReaderBodyTicket?
    private var sequence = 0
    mutating func begin(_ request: ReaderBodyRequest) -> ReaderBodyTicket {
        sequence += 1
        let ticket = ReaderBodyTicket(request: request, sequence: sequence)
        self.ticket = ticket; return ticket
    }
    func accepts(_ ticket: ReaderBodyTicket) -> Bool { self.ticket == ticket }
    mutating func cancel() { sequence += 1; ticket = nil }
}

/// Only one selected message's content is retained by the reader. The mailbox
/// list may contain preview-only rows and must never stand in for this source.
struct ReaderBodySource: Sendable {
    var id: String
    var version: String
    var text: String
    var html: String
    var attachments: [MailAttachment]
    init(_ mail: MailMessage) throws {
        guard mail.contentAvailability == nil || mail.contentAvailability == .complete else { throw MailError.message("Complete message content is required for reading.") }
        id = mail.id; version = mail.bodyVersion; text = mail.text; html = mail.html; attachments = mail.attachments
    }
    static func load(id: String, store: MailStore) async throws -> Self {
        try Task.checkCancellation()
        guard let mail = try await store.message(id) else { throw MailError.message("The message is no longer available locally.") }
        try Task.checkCancellation()
        return try Self(mail)
    }
}
