import Foundation

public enum MailboxCodec {
    public static func decode(_ text: String) -> String {
        var output = ""; var encoded = ""; var collecting = false
        for character in text {
            if collecting {
                if character == "-" {
                    if encoded.isEmpty { output.append("&") }
                    else { var base64 = encoded.replacingOccurrences(of: ",", with: "/"); while base64.count % 4 != 0 { base64.append("=") }; output += Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf16BigEndian) } ?? "&" + encoded + "-" }
                    collecting = false; encoded = ""
                } else { encoded.append(character) }
            } else if character == "&" { collecting = true } else { output.append(character) }
        }
        if collecting { output += "&" + encoded }; return output
    }
    public static func encode(_ text: String) -> String {
        var output = ""; var unicode = ""
        func flush() { if !unicode.isEmpty { output += "&" + (unicode.data(using: .utf16BigEndian)?.base64EncodedString().replacingOccurrences(of: "/", with: ",").replacingOccurrences(of: "=", with: "") ?? "") + "-"; unicode = "" } }
        for character in text {
            if character.unicodeScalars.allSatisfy({ (32...126).contains($0.value) }) { flush(); output += character == "&" ? "&-" : String(character) }
            else { unicode.append(character) }
        }; flush(); return output
    }
}
