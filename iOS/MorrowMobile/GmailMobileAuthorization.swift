import Foundation

/// Google's iOS client uses its reversed client ID as the custom URI scheme.
/// The official GoogleSignIn-iOS GIDSignIn implementation appends /oauth2callback.
/// https://developers.google.com/identity/sign-in/ios/start-integrating
/// https://github.com/google/GoogleSignIn-iOS/blob/main/GoogleSignIn/Sources/GIDSignIn.m
struct GmailMobileOAuthClient: Sendable {
    static let bundleID = "app.smail.mobile"
    let clientID: String
    let callbackScheme: String
    var redirectURI: String { callbackScheme + ":/oauth2callback" }

    init(clientID: String, bundleID: String?, registeredSchemes: [String]) throws {
        let value = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = ".apps.googleusercontent.com"
        guard bundleID == Self.bundleID, value.hasSuffix(suffix), value.count > suffix.count,
              !value.dropLast(suffix.count).contains("."),
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-.").contains($0) }) else {
            throw GmailMobileAuthorizationError.configuration
        }
        let scheme = value.split(separator: ".").reversed().joined(separator: ".").lowercased()
        guard registeredSchemes.contains(where: { $0.lowercased() == scheme }) else {
            throw GmailMobileAuthorizationError.configuration
        }
        self.clientID = value
        self.callbackScheme = scheme
    }

    static func load(bundle: Bundle = .main) throws -> Self {
        guard let url = bundle.url(forResource: "oauth-clients", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data),
              let clientID = values["google_ios"] else {
            throw GmailMobileAuthorizationError.configuration
        }
        let types = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        return try Self(clientID: clientID, bundleID: bundle.bundleIdentifier, registeredSchemes: schemes)
    }
}

struct GmailMobileOAuthAttempt: Sendable {
    let client: GmailMobileOAuthClient
    let state: String
    let verifier: String

    func authorizationCode(from callback: URL) throws -> String {
        guard let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == client.callbackScheme,
              parts.host == nil, parts.user == nil, parts.password == nil, parts.port == nil,
              parts.percentEncodedPath == "/oauth2callback", parts.fragment == nil else {
            throw GmailMobileAuthorizationError.invalidCallback
        }
        var fields: [String: String] = [:]
        for item in parts.queryItems ?? [] {
            guard fields[item.name] == nil, let value = item.value else {
                throw GmailMobileAuthorizationError.invalidCallback
            }
            fields[item.name] = value
        }
        guard fields["state"] == state else { throw GmailMobileAuthorizationError.invalidCallback }
        if fields["error"] != nil {
            if fields["error"] == "access_denied" { throw GmailMobileAuthorizationError.cancelled }
            throw GmailMobileAuthorizationError.authorizationFailed
        }
        guard let code = fields["code"], !code.isEmpty, code.utf8.count <= 8192,
              !code.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw GmailMobileAuthorizationError.invalidCallback
        }
        return code
    }

    static func hasFullMailScope(_ scope: String?) -> Bool {
        Set((scope ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init)).contains("https://mail.google.com/")
    }
}

enum GmailMobileAuthorizationError: LocalizedError {
    case configuration, foregroundRequired, browserUnavailable, cancelled, timedOut
    case invalidCallback, authorizationFailed, missingMailScope, missingRefreshToken
    case noPendingGrant, pendingExpired, identityFailed, wrongAccount, verificationFailed, secureStorage
    case secureStorageStatus(Int32)

    var errorDescription: String? {
        switch self {
        case .configuration:
            return GmailMobileText.text("此安装尚未配置 iPhone Gmail 登录。", "This installation is not configured for iPhone Gmail sign-in.", "このインストールには iPhone の Gmail ログインが設定されていません。")
        case .foregroundRequired:
            return GmailMobileText.text("请在前台打开 Morrow 后连接 Gmail。", "Open Morrow in the foreground to connect Gmail.", "Morrow を前面に開いてから Gmail に接続してください。")
        case .browserUnavailable:
            return GmailMobileText.text("系统登录窗口无法打开，请重试。", "The system sign-in window could not open. Please try again.", "システムのログイン画面を開けませんでした。再試行してください。")
        case .cancelled:
            return GmailMobileText.text("Gmail 连接已取消。", "Gmail connection cancelled.", "Gmail の接続をキャンセルしました。")
        case .timedOut:
            return GmailMobileText.text("Gmail 登录已超时，请重新连接。", "Gmail sign-in timed out. Please connect again.", "Gmail ログインがタイムアウトしました。再接続してください。")
        case .invalidCallback, .authorizationFailed:
            return GmailMobileText.text("未能验证 Google 授权回调，请重新登录。", "Google's authorization callback could not be verified. Please sign in again.", "Google の認証応答を検証できませんでした。再度ログインしてください。")
        case .missingMailScope:
            return GmailMobileText.text("Google 登录已完成，但未授予完整 Gmail 邮件权限。请重新授权并允许邮件访问。", "Google sign-in completed without full Gmail permission. Authorize again and allow mail access.", "Google ログインは完了しましたが、Gmail の完全な権限がありません。再認証してメールへのアクセスを許可してください。")
        case .missingRefreshToken:
            return GmailMobileText.text("Google 未提供长期访问授权，请重新授权。", "Google did not provide ongoing access. Please authorize again.", "Google から継続的なアクセス権限を取得できませんでした。再認証してください。")
        case .noPendingGrant, .pendingExpired:
            return GmailMobileText.text("已保存的授权无法继续，请重新连接 Google。", "The saved authorization cannot continue. Please reconnect to Google.", "保存済みの認証では続行できません。Google に再接続してください。")
        case .identityFailed:
            return GmailMobileText.text("Google 邮箱身份尚未核验；授权已安全保存，可重试。", "Google mailbox identity is not verified yet. Authorization is saved securely for retry.", "Google のメール本人情報は未検証です。認証は安全に保存されており、再試行できます。")
        case .wrongAccount:
            return GmailMobileText.text("Google 授权账户与填写的邮箱不同，未保存邮箱连接。请重新选择账户。", "The Google account differs from the entered address. No mailbox connection was saved. Choose the account again.", "Google アカウントが入力したメールと異なります。メール接続は保存していません。アカウントを選び直してください。")
        case .verificationFailed:
            return GmailMobileText.text("Gmail 连接验证未完成；授权已安全保存，可重试。", "Gmail connection verification did not finish. Authorization is saved securely for retry.", "Gmail の接続検証が完了しませんでした。認証は安全に保存されており、再試行できます。")
        case .secureStorage:
            return GmailMobileText.text("Gmail 授权存储不可用，请重新授权。", "The Gmail credential record is unavailable. Authorize again.", "Gmail の認証記録を利用できません。再認証してください。")
        case .secureStorageStatus(let code):
            if code == -34018 {
                return GmailMobileText.text("此构建缺少钥匙串签名能力。请在已签名设备上使用 Gmail 登录。", "This build lacks signed Keychain access. Use Gmail sign-in on a signed device.", "このビルドには署名済みキーチェーンのアクセス権がありません。署名済み端末で Gmail にログインしてください。")
            }
            return GmailMobileText.text("无法访问 Gmail 授权存储，请解锁设备并核对应用权限。", "Gmail credential storage is unavailable. Unlock the device and check app permissions.", "Gmail の認証ストレージを利用できません。端末をロック解除し、アプリの権限を確認してください。") + " (\(code))"
        }
    }
}

enum GmailMobileText {
    static func text(_ chinese: String, _ english: String, _ japanese: String) -> String {
        switch UserDefaults.standard.string(forKey: "SmailMobileLanguage") ?? "zh-Hans" {
        case "en": return english
        case "ja": return japanese
        default: return chinese
        }
    }
}
