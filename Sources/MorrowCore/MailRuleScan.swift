import Foundation

/// Rule hints walk the source in small overlapping blocks. No lowercase copy
/// of the whole message or array of every source line is created.
enum MailRuleScan {
    struct Signals {
        var finance = false, newsletter = false, notification = false, travel = false, reply = false, urgent = false
        mutating func include(_ text: String) {
            let value = text.lowercased()
            finance = finance || ["invoice", "账单", "发票", "付款", "payment", "receipt"].contains(where: value.contains)
            newsletter = newsletter || ["unsubscribe", "退订", "newsletter", "周刊"].contains(where: value.contains)
            notification = notification || ["验证码", "verification code", "security alert", "登录提醒"].contains(where: value.contains)
            travel = travel || ["航班", "机票", "登机", "itinerary", "酒店"].contains(where: value.contains)
            reply = reply || ["请确认", "请回复", "回复我", "请审核", "麻烦", "please confirm", "please reply", "could you", "can you", "需要你"].contains(where: value.contains)
            urgent = urgent || ["紧急", "urgent", "逾期", "overdue", "今天", "today"].contains(where: value.contains)
        }
    }
    static func signals(subject: String, text: String) -> Signals {
        var result = Signals()
        for source in [subject, text] {
            var start = source.startIndex
            while start < source.endIndex {
                let end = source.index(start, offsetBy: 4096, limitedBy: source.endIndex) ?? source.endIndex
                result.include(String(source[start..<end]))
                if end == source.endIndex { break }; start = source.index(end, offsetBy: -64)
            }
        }
        result.include(String(subject.suffix(64)) + " " + String(text.prefix(64)))
        return result
    }
    static func preview(_ text: String, maximumCharacters: Int = 140) -> String {
        guard maximumCharacters > 0 else { return "" }
        var result = "", line = "", lines = 0, length = 0
        for character in text {
            if character.isNewline {
                if !line.isEmpty {
                    if !result.isEmpty { result += " " }; result += line; line = ""; lines += 1
                    if lines == 2 { break }
                }
            } else { line.append(character); length += 1 }
            if length >= maximumCharacters { break }
        }
        if !line.isEmpty { if !result.isEmpty { result += " " }; result += line }
        return String(result.prefix(maximumCharacters))
    }
}
