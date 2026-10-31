import Foundation

struct MailViewProjectionKey: Equatable {
    var revision: Int
    var metadata: Int
    var destination: String
    var account: String?
    var folder: String?
    var category: String?
    var unread: Bool
    var search: Bool
    var query: String
    var strategy: String
    var scope: String
    var results: Int
    var clockBucket: Int
}
