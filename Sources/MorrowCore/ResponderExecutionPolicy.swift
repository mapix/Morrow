import Foundation

public struct ResponderExecutionPolicy: Codable, Sendable, Equatable {
    public var allowedTools = ["read", "attachments", "readAttachment", "sandbox"]
    public var networkDomains: [String] = []
    public var maximumTurns = 6
    public var maximumTools = 10
    public var maximumSeconds = 180
    public var commandSeconds = 15
    public var failureAction = "stop"
    public init() {}
    public func validate() throws {
        guard allowedTools.contains("read"), !allowedTools.isEmpty, Set(allowedTools).count == allowedTools.count,
              Set(allowedTools).isSubset(of: ["read", "attachments", "readAttachment", "sandbox", "generateImage"]),
              (2...8).contains(maximumTurns), (1...20).contains(maximumTools), (1...600).contains(maximumSeconds),
              (1...60).contains(commandSeconds), commandSeconds <= maximumSeconds, failureAction == "stop" else {
            throw MailError.message("响应器策略无效：读取必须保留，工具和执行预算须在允许范围内；失败后必须停止投递。")
        }
        guard networkDomains.count <= 20, networkDomains.allSatisfy({ MailResponder.validAuthService($0) && !$0.contains("*") && !["localhost", "local", "internal"].contains($0) && !$0.hasSuffix(".localhost") }) else {
            throw MailError.message("工具网络白名单只接受明确的公网域名，不能使用通配符、IP或本机地址。")
        }
    }
}

public struct ResponderSourceMatcher: Sendable {
    private let configured: Bool
    private let account: String
    private let folder: String
    private let addresses: Set<String>
    public init(_ rule: MailResponder) { configured = rule.hasBoundSource; account = rule.accountID; folder = rule.folderPath ?? ""; addresses = Set(rule.allowedSenders.map { $0.lowercased() }) }
    public func contains(_ mail: MailMessage) -> Bool { configured && mail.accountID == account && mail.folder == folder && addresses.contains(mail.from.email.lowercased()) }
}
