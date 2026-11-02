import Foundation
import Security

public struct MCPServerSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var port = 8765
    public var allowLAN = false
    public init() {}
    public var endpoint: String { "http://127.0.0.1:\(port)/mcp" }
    public func validate() throws {
        guard (1024...65535).contains(port) else { throw MailError.message("MCP 端口必须在 1024 到 65535 之间。") }
    }
}

public protocol MCPTokenStorage: Sendable {
    func read() throws -> String?
    func write(_ token: String) throws
}

public struct MCPKeychainTokenStorage: MCPTokenStorage {
    private let key: String
    private let allowInteraction: Bool
    public init(root: URL, allowInteraction: Bool = false) {
        key = "mcp-server:" + MailStore.hash(root.standardizedFileURL.path)
        self.allowInteraction = allowInteraction
    }
    public func read() throws -> String? { try SecretStore.readOptional(accountID: key, allowInteraction: allowInteraction) }
    public func write(_ token: String) throws { try SecretStore.save(token, accountID: key, allowInteraction: allowInteraction) }
}

/// Shared by all connections so rotation also revokes already-open requests.
public final class MCPAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String
    public init(token: String) { self.token = token }
    public static func generateToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MailError.message("无法生成 MCP 认证 token。")
        }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public func rotate(to token: String) { lock.lock(); self.token = token; lock.unlock() }
    public func accepts(_ header: String?) -> Bool {
        guard let header else { return false }
        let parts = header.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
        lock.lock(); let expected = Array(token.utf8); lock.unlock()
        let supplied = Array(parts[1].utf8)
        guard !expected.isEmpty, expected.count == supplied.count else { return false }
        var difference: UInt8 = 0
        for index in expected.indices { difference |= expected[index] ^ supplied[index] }
        return difference == 0
    }
}
