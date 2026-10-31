import Foundation

public enum DeadlineEvidence {
    public static func validated(_ date: Date?, quote: String?, original: String) -> Date? {
        guard let date, let quote, !quote.isEmpty else { return nil }
        let compact: (String) -> String = { $0.components(separatedBy: .whitespacesAndNewlines).joined() }
        guard compact(original).contains(compact(quote)) else { return nil }
        // A date-only phrase does not justify choosing a working hour.
        let exactClock = #"(?:\d{1,2}[:：]\d{2}|[零一二三四五六七八九十两\d]+\s*点|\d{1,2}\s*(?:am|pm|AM|PM))"#
        guard quote.range(of: exactClock, options: .regularExpression) != nil else { return nil }
        var clock: (Int, Int)?
        if let hour = MIMEParser.capture(#"(\d{1,2})[:：]\d{2}"#, quote).flatMap(Int.init), let minute = MIMEParser.capture(#"\d{1,2}[:：](\d{2})"#, quote).flatMap(Int.init) { clock = (hour, minute) }
        else if let hour = MIMEParser.capture(#"(\d{1,2})\s*(?:am|pm)"#, quote).flatMap(Int.init), let meridiem = MIMEParser.capture(#"\d{1,2}\s*(am|pm)"#, quote) { clock = (hour % 12 + (meridiem.lowercased() == "pm" ? 12 : 0), 0) }
        else if let value = MIMEParser.capture(#"([零一二三四五六七八九十两\d]+)\s*点"#, quote), let h = chineseNumber(value) {
            var hour = h
            if ["下午", "晚上", "傍晚", "中午"].contains(where: quote.contains), hour < 12 { hour += 12 }
            if ["凌晨", "上午", "早上"].contains(where: quote.contains), hour == 12 { hour = 0 }
            clock = (hour, quote.contains("点半") ? 30 : 0)
        }
        guard let (hour, minute) = clock, (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = quote.range(of: #"\b(?:UTC|GMT)\b|\d{2}:\d{2}Z"#, options: .regularExpression) != nil ? TimeZone(secondsFromGMT: 0)! : .current
        let parts = calendar.dateComponents([.hour, .minute, .year, .month, .day], from: date)
        guard parts.hour == hour, parts.minute == minute else { return nil }
        if let year = MIMEParser.capture(#"(\d{4})[-/年]\d{1,2}[-/月]\d{1,2}"#, quote).flatMap(Int.init) { guard parts.year == year else { return nil } }
        if let month = MIMEParser.capture(#"\d{4}[-/年](\d{1,2})[-/月]\d{1,2}"#, quote).flatMap(Int.init), let day = MIMEParser.capture(#"\d{4}[-/年]\d{1,2}[-/月](\d{1,2})"#, quote).flatMap(Int.init) { guard parts.month == month && parts.day == day else { return nil } }
        else if let month = MIMEParser.capture(#"(\d{1,2})月\d{1,2}日"#, quote).flatMap(Int.init), let day = MIMEParser.capture(#"\d{1,2}月(\d{1,2})日"#, quote).flatMap(Int.init) { guard parts.month == month && parts.day == day else { return nil } }
        return date
    }
    private static func chineseNumber(_ value: String) -> Int? {
        if let number = Int(value) { return number }
        let digits: [String: Int] = ["零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        if let digit = digits[value] { return digit }
        if value.contains("十") { let parts = value.components(separatedBy: "十"); if parts.count == 2 { return (parts[0].isEmpty ? 1 : digits[parts[0]] ?? 0) * 10 + (parts[1].isEmpty ? 0 : digits[parts[1]] ?? 0) } }
        return nil
    }
}
