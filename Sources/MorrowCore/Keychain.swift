import Foundation
import Security

public enum SecretStore {
    public static func save(_ secret: String, accountID: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.smail.credentials", kSecAttrAccount as String: accountID]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(secret.utf8)] as CFDictionary)
        if status == errSecItemNotFound {
            var create = query; create[kSecValueData as String] = Data(secret.utf8); create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(create as CFDictionary, nil); guard result == errSecSuccess else { throw MailError.message("无法保存到钥匙串 (\(result))。") }
        } else if status != errSecSuccess { throw MailError.message("无法更新钥匙串 (\(status))。") }
    }
    public static func read(accountID: String) throws -> String {
        guard let secret = try readOptional(accountID: accountID) else { throw MailError.message("邮箱授权码不可用，请在设置中重新填写。") }
        return secret
    }
    public static func readOptional(accountID: String) throws -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.smail.credentials", kSecAttrAccount as String: accountID, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed { throw MailError.message("钥匙串访问尚未允许。请解锁设备，并允许 Morrow 读取已保存凭据后重试。") }
        guard status == errSecSuccess, let data = result as? Data, let secret = String(data: data, encoding: .utf8) else { throw MailError.message("无法读取钥匙串凭据（\(status)）。") }
        return secret
    }
    public static func delete(accountID: String) { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.smail.credentials", kSecAttrAccount as String: accountID] as CFDictionary) }
}
