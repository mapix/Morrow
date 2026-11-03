import Foundation

/// Explicit media permission for an automatic responder; absent on old rules.
public struct ResponderImageReply: Codable, Sendable, Equatable {
    public var model: String?
    public var size = "1024x1024"
    public var quality = "auto"
    public init(model: String? = nil, size: String = "1024x1024", quality: String = "auto") {
        self.model = model; self.size = size; self.quality = quality
    }
    public func validate() throws {
        guard model.map({ !$0.isEmpty && $0.utf8.count <= 512 }) ?? true,
              ["auto", "1024x1024", "1536x1024", "1024x1536"].contains(size),
              ["auto", "low", "medium", "high", "xhigh", "max"].contains(quality) else {
            throw MailError.message("响应器图片模型、尺寸或质量无效。")
        }
    }
}

public struct ResponderImageReceipt: Codable, Identifiable, Sendable {
    public var id: String
    public var responderID: String
    public var canonicalID: String
    public var ruleFingerprint: String
    public var sourceBodyVersion: String
    public var model: String
    public var state = "submitting"
    public var createdAt: Date? = Date()
    public var mimeType: String?
    public var contentHash: String?
    public var bytes: Int?
    public var costUSD: Double?
    public init(rule: MailResponder, mail: MailMessage, model: String) {
        responderID = rule.id; canonicalID = mail.canonicalID
        ruleFingerprint = rule.configurationFingerprint; sourceBodyVersion = mail.bodyVersion; self.model = model
        id = MailStore.hash("responder-image:" + rule.id + ":" + canonicalID + ":" + ruleFingerprint + ":" + sourceBodyVersion)
    }
}
