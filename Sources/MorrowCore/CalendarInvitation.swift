import Foundation

public struct CalendarInvitation: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var start: Date
    public var end: Date
    public var location: String
    public var detail: String
    public var organizer: String
    public var attendees: [String]
    public var method: String
    public var allDay: Bool
    public init(id: String = UUID().uuidString, title: String, start: Date, end: Date, location: String = "", detail: String = "", organizer: String = "", attendees: [String] = [], method: String = "PUBLISH", allDay: Bool = false) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.location = location; self.detail = detail; self.organizer = organizer; self.attendees = attendees; self.method = method; self.allDay = allDay
    }
    public static func parse(_ data: Data) -> [CalendarInvitation] {
        let text = MIMEParser.decode(data, charset: "utf-8").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n[ \t]", with: "", options: .regularExpression)
        var events: [CalendarInvitation] = []; var fields: [String: [(String, String)]]?; var method = "REQUEST"
        for line in text.components(separatedBy: "\n") {
            if line == "BEGIN:VEVENT" { fields = [:]; continue }
            if line == "END:VEVENT" {
                if let f = fields, let startField = f["DTSTART"]?.first, let start = date(startField.1, attributes: startField.0) {
                    let allDay = startField.0.contains("VALUE=DATE") || startField.1.count == 8
                    let end = f["DTEND"]?.first.flatMap { date($0.1, attributes: $0.0) } ?? start.addingTimeInterval(allDay ? 86400 : 3600)
                    events.append(.init(id: f["UID"]?.first?.1 ?? UUID().uuidString, title: unescape(f["SUMMARY"]?.first?.1 ?? "会议"), start: start, end: end, location: unescape(f["LOCATION"]?.first?.1 ?? ""), detail: unescape(f["DESCRIPTION"]?.first?.1 ?? ""), organizer: email(f["ORGANIZER"]?.first?.1 ?? ""), attendees: (f["ATTENDEE"] ?? []).map { email($0.1) }, method: method, allDay: allDay))
                }; fields = nil; continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let attributes = String(line[..<colon]); let key = attributes.components(separatedBy: ";")[0].uppercased(); let value = String(line[line.index(after: colon)...])
            if key == "METHOD" { method = value }
            if fields != nil { fields![key, default: []].append((attributes, value)) }
        }; return events
    }
    private static func date(_ text: String, attributes: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        if text.hasSuffix("Z") { f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'" }
        else {
            let zone = MIMEParser.capture(#"TZID=([^;:]+)"#, attributes)
            f.timeZone = zone.flatMap { TimeZone(identifier: $0.trimmingCharacters(in: CharacterSet(charactersIn: "\""))) } ?? .current
            f.dateFormat = text.count == 8 ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss"
        }; return f.date(from: text)
    }
    private static func email(_ text: String) -> String { text.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive) }
    private static func unescape(_ text: String) -> String { text.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";").replacingOccurrences(of: "\\\\", with: "\\") }
    public func reply(from email: String, accepted: Bool) throws -> MailAttachment {
        guard MailAddress.isValid(email), MailAddress.isValid(organizer), attendees.contains(where: { $0.caseInsensitiveCompare(email) == .orderedSame }) else { throw MailError.message("当前邮箱不在邀请参会人中，请核对邀请和账户。") }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        func safe(_ value: String) -> String { value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: ";", with: "\\;") }
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyyMMdd"
        let startLine = allDay ? "DTSTART;VALUE=DATE:" + day.string(from: start) : "DTSTART:" + f.string(from: start)
        let endLine = allDay ? "DTEND;VALUE=DATE:" + day.string(from: end) : "DTEND:" + f.string(from: end)
        let text = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Morrow//Mail Partner//EN", "METHOD:REPLY", "BEGIN:VEVENT", "UID:" + safe(id), "DTSTAMP:" + f.string(from: Date()), startLine, endLine, "SUMMARY:" + safe(title), "ORGANIZER:mailto:" + organizer, "ATTENDEE;PARTSTAT=\(accepted ? "ACCEPTED" : "DECLINED"):mailto:" + email, "END:VEVENT", "END:VCALENDAR", ""].joined(separator: "\r\n")
        return .init(name: "reply.ics", mimeType: "text/calendar", data: Data(text.utf8))
    }
}
