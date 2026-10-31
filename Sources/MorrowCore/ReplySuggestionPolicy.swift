import Foundation

public enum ReplySuggestionPolicy {
    public static func containsUnverifiedConfirmation(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["我可以参加", "我能参加", "我将参加", "我同意", "我接受", "已完成审核", "我已审核", "我已经审核", "已付款", "已经付款", "已签署", "抬头正确", "信息无误", "已附上", "i can attend", "i will attend", "i agree", "i accept", "i have reviewed", "i have paid", "i've paid", "i have completed", "attached is", "please find attached"].contains(where: lower.contains)
    }
    public static func neutralReply(subject: String, original: String) -> String {
        if original.range(of: #"[\u4e00-\u9fff]"#, options: .regularExpression) != nil {
            return "收到关于“\(subject)”的邮件。我会先核对相关信息，再回复具体意见。谢谢。"
        }
        return "Thank you for your email about \(subject). I'll check the relevant details before confirming."
    }
}
