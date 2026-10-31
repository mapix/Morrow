import Foundation

/// App-owned registration metadata. Credentials deliberately do not conform to this type.
public struct ChatGPTProfile: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var issuer: String
    public var subject: String
    public var clientID: String
    public var email: String?
    public var name: String?
    public var planEnabled: Bool
    public var signedIn: Bool
    public var welcomed: Bool
    public var updatedAt: Date
    public var label: String { name ?? email ?? "ChatGPT" }
    public var detail: String { email ?? "ChatGPT account" }
    public init(identity: ChatGPTVerifiedIdentity, clientID: String, planEnabled: Bool) {
        self.id = ChatGPTCrypto.digest(identity.issuer + "\n" + clientID + "\n" + identity.subject)
        self.issuer = identity.issuer; self.subject = identity.subject; self.clientID = clientID
        self.email = identity.email; self.name = identity.name; self.planEnabled = planEnabled
        self.signedIn = true; self.welcomed = false; self.updatedAt = Date()
    }
}
public struct ChatGPTVerifiedIdentity: Sendable, Equatable {
    public var issuer: String
    public var subject: String
    public var email: String?
    public var name: String?
}
public struct ChatGPTModel: Decodable, Identifiable, Sendable, Equatable {
    public var slug: String
    public var displayName: String
    public var visibility: String
    public var id: String { slug }
    enum CodingKeys: String, CodingKey { case slug, displayName = "display_name", visibility }
}
public struct ChatGPTCredentials: Codable, Sendable {
    public var clientID: String
    public var subject: String
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String
    public var scopes: [String]
    public var expiresAt: Date
    public var earliestRefreshAt: Date?
    public var revision: String
    public var planEnabled: Bool { scopes.contains("chatgpt.tokens.use.direct") }
}
public struct ChatGPTServiceError: LocalizedError, Sendable {
    public var code: String
    public var status: Int?
    public var requestID: String?
    public var errorDescription: String? {
        let message: String
        switch code {
        case "not_signed_in": message = "请先使用 Continue with ChatGPT 登录。"
        case "plan_permission_missing": message = "已登录，但没有授权 Morrow 使用 ChatGPT 计划。请重新登录并允许计划使用。"
        case "subscription_sharing_usage_limit_exceeded": message = "ChatGPT 用量已达限制。请打开 Manage usage 查看计划或应用限额。"
        case "subscription_sharing_usage_unavailable": message = "ChatGPT 计划使用暂不可用，请查看 Manage usage。"
        case "user_not_eligible": message = "这个账户目前不符合 ChatGPT 计划接入资格。"
        case "invalid_grant", "refresh_token_reused", "token_expired", "invalid_token": message = "ChatGPT 授权已失效，请重新登录。"
        case "access_denied": message = "ChatGPT 授权已取消，原有账户保持不变。"
        case "identity_invalid": message = "ChatGPT 身份验证未通过，本次凭据未保存。"
        case "callback_invalid": message = "ChatGPT 登录回调无法核验，请重新登录。"
        case "login_timeout": message = "ChatGPT 登录等待已超时，请重新登录。"
        case "stream_incomplete": message = "ChatGPT 响应未完成，本次没有记录为成功。"
        case "signed_out": message = "这个 ChatGPT 账户已经退出。"
        case "native_callback_unavailable": message = "ChatGPT 当前公开的原生授权契约未确认支持 iPhone 回调；请先使用 API 服务或在 Mac 登录。"
        default: message = "ChatGPT 请求失败，请检查账户授权和服务状态。"
        }
        let diagnostic = [status.map { "HTTP \($0)" }, code, requestID.map { "request \($0)" }].compactMap { $0 }.joined(separator: ", ")
        return message + " (" + diagnostic + ")"
    }
    public init(_ code: String, status: Int? = nil, requestID: String? = nil) { self.code = code; self.status = status; self.requestID = requestID }
    static func http(_ data: Data, response: HTTPURLResponse) -> ChatGPTServiceError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let error = object?["error"] as? [String: Any]
        let raw = error?["code"] as? String ?? object?["error"] as? String ?? "http_error"
        let safe = raw.range(of: "^[a-zA-Z0-9_]{1,90}$", options: .regularExpression) == nil ? "http_error" : raw
        let request = response.value(forHTTPHeaderField: "x-request-id") ?? response.value(forHTTPHeaderField: "openai-request-id")
        return ChatGPTServiceError(safe, status: response.statusCode, requestID: request.flatMap { $0.range(of: "^[a-zA-Z0-9_-]{1,120}$", options: .regularExpression) != nil ? $0 : nil })
    }
}
