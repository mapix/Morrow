import Foundation

public enum GeneratedMailBody {
    public static func normalize(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        value = value.replacingOccurrences(of: #"(?im)^\s*(?:主题|subject)\s*[:：][^\r\n]*\r?\n?"#, with: "", options: .regularExpression)
        for placeholder in ["[您的姓名]", "[你的姓名]", "[姓名]", "[Your Name]", "[your name]", "[Sender Name]"] { value = value.replacingOccurrences(of: placeholder, with: "") }
        if value.hasPrefix("```") { value = value.replacingOccurrences(of: #"^```[^\n]*\n|\n```$"#, with: "", options: .regularExpression) }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
