import Foundation

public enum ModelEndpoint {
    public static func url(_ base: String, path: String) throws -> URL {
        guard let url = URL(string: base.trimmingCharacters(in: .whitespacesAndNewlines)), let host = url.host, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else { throw MailError.message("模型地址须为HTTPS；本机服务可以用HTTP，不要把密钥放在地址中。") }
        return url.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }
    public static func credentialID(_ base: String) -> String { "model-api:" + MailStore.hash(base.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }
}
