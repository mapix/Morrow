import Foundation

public struct ContactEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: String = UUID().uuidString
    public var name: String = ""
    public var email: String = ""
    public var phone: String = ""
    public var company: String = ""
    public var note: String = ""
    public init() {}
    public var address: MailAddress { .init(name: name, email: email) }
}

public enum VCardCodec {
    public static func decode(_ text: String) -> [ContactEntry] {
        let unfolded = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n[ \t]", with: "", options: .regularExpression)
        var out: [ContactEntry] = []; var contact: ContactEntry?
        for line in unfolded.components(separatedBy: "\n") {
            if line.uppercased() == "BEGIN:VCARD" { contact = ContactEntry(); continue }
            if line.uppercased() == "END:VCARD" { if let c = contact, MailAddress.isValid(c.email) { out.append(c) }; contact = nil; continue }
            guard let colon = line.firstIndex(of: ":"), contact != nil else { continue }
            let key = line[..<colon].components(separatedBy: ";")[0].components(separatedBy: ".").last?.uppercased() ?? ""
            let raw = String(line[line.index(after: colon)...]); let value = raw.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";").replacingOccurrences(of: "\\\\", with: "\\")
            switch key { case "FN": contact?.name = value; case "EMAIL": if contact?.email.isEmpty == true { contact?.email = value }; case "TEL": if contact?.phone.isEmpty == true { contact?.phone = value }; case "ORG": contact?.company = value.replacingOccurrences(of: ";", with: " "); case "NOTE": contact?.note = value; default: break }
        }; return out
    }
    public static func encode(_ contact: ContactEntry) -> String {
        func escape(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: ",", with: "\\,") }
        return ["BEGIN:VCARD", "VERSION:3.0", "FN:" + escape(contact.name), "EMAIL;TYPE=INTERNET:" + escape(contact.email), "TEL:" + escape(contact.phone), "ORG:" + escape(contact.company), "NOTE:" + escape(contact.note), "END:VCARD", ""].joined(separator: "\r\n")
    }
}
