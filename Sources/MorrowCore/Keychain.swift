import Foundation
import Security

public struct CredentialStoreError: LocalizedError, Sendable {
    public let status: OSStatus
    public init(status: OSStatus) { self.status = status }
    public var requiresInteraction: Bool { [errSecUserCanceled, errSecInteractionNotAllowed, errSecAuthFailed].contains(status) }
    public var errorDescription: String? {
        requiresInteraction ? "钥匙串凭据需要授权。请在设置中点击“授权读取已存凭据”；后台已停止弹出密码框。"
            : "无法访问钥匙串凭据（\(status)）。"
    }
}

/// One decrypted value per process, with serialized reads and a permission
/// failure latch. Cache state is never written outside the system Keychain.
final class SessionCredentialCache: @unchecked Sendable {
    private let lock = NSLock(), operation = NSLock()
    private var values: [String: String] = [:]
    private var blocked: [String: CredentialStoreError] = [:]
    func read(_ id: String, allowInteraction: Bool, force: Bool = false,
              load: (Bool) throws -> String?) throws -> String? {
        func cached() throws -> String? {
            lock.lock(); defer { lock.unlock() }
            if !allowInteraction, let error = blocked[id] { throw error }
            return force ? nil : values[id]
        }
        if let value = try cached() { return value }
        operation.lock(); defer { operation.unlock() }
        if let value = try cached() { return value }
        do {
            let value = try load(allowInteraction)
            lock.lock(); values[id] = value; blocked[id] = nil; lock.unlock()
            return value
        } catch {
            record(error, id: id); throw error
        }
    }
    func write(_ id: String, value: String, allowInteraction: Bool, persist: () throws -> Void) throws {
        operation.lock(); defer { operation.unlock() }
        lock.lock(); let failure = blocked[id]; lock.unlock()
        if !allowInteraction, let failure { throw failure }
        do {
            try persist()
            lock.lock(); values[id] = value; blocked[id] = nil; lock.unlock()
        } catch { record(error, id: id); throw error }
    }
    func invalidate(_ id: String) { lock.lock(); values[id] = nil; blocked[id] = nil; lock.unlock() }
    private func record(_ error: Error, id: String) {
        guard let error = error as? CredentialStoreError, error.requiresInteraction else { return }
        lock.lock(); values[id] = nil; blocked[id] = error; lock.unlock()
    }
}

public enum SecretStore {
    private static let cache = SessionCredentialCache()
    private static func query(_ id: String, allowInteraction: Bool) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.smail.credentials", kSecAttrAccount as String: id]
        if !allowInteraction { query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        return query
    }
    public static func save(_ secret: String, accountID: String, allowInteraction: Bool = true) throws {
        try cache.write(accountID, value: secret, allowInteraction: allowInteraction) {
            let query = query(accountID, allowInteraction: allowInteraction)
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(secret.utf8)] as CFDictionary)
            if status == errSecItemNotFound {
                var create = query; create[kSecValueData as String] = Data(secret.utf8); create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                let result = SecItemAdd(create as CFDictionary, nil); guard result == errSecSuccess else { throw CredentialStoreError(status: result) }
            } else if status != errSecSuccess { throw CredentialStoreError(status: status) }
        }
    }
    public static func read(accountID: String, allowInteraction: Bool = false, forceReload: Bool = false) throws -> String {
        guard let secret = try readOptional(accountID: accountID, allowInteraction: allowInteraction, forceReload: forceReload) else { throw MailError.message("邮箱授权码不可用，请在设置中重新填写。") }
        return secret
    }
    public static func readOptional(accountID: String, allowInteraction: Bool = false, forceReload: Bool = false) throws -> String? {
        try cache.read(accountID, allowInteraction: allowInteraction, force: forceReload) { allowed in
            var query = query(accountID, allowInteraction: allowed)
            query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data, let secret = String(data: data, encoding: .utf8) else { throw CredentialStoreError(status: status) }
            return secret
        }
    }
    public static func invalidateMemory(accountID: String) { cache.invalidate(accountID) }
    public static func delete(accountID: String) {
        SecItemDelete(query(accountID, allowInteraction: true) as CFDictionary)
        cache.invalidate(accountID)
    }
}
