import Foundation

public enum MailProvider: String, CaseIterable, Identifiable, Sendable {
    case netease163 = "网易 163", netease126 = "网易 126", qq = "QQ 邮箱", iCloud = "iCloud", gmail = "Gmail", outlook = "Outlook", other = "其他 IMAP 邮箱"
    public var id: String { rawValue }
    public static func infer(_ suggestion: String) -> MailProvider? {
        let text = suggestion.lowercased()
        if text.contains("gmail") || text.contains("googlemail") || text.contains("google") || text.contains("谷歌") { return .gmail }
        if ["outlook", "hotmail", "@live.", "office365", "microsoft", "微软"].contains(where: text.contains) { return .outlook }
        if text.contains("126") { return .netease126 }
        if text.contains("163") || text.contains("网易") { return .netease163 }
        if text.contains("qq") { return .qq }
        if ["icloud", "@me.com", "@mac.com"].contains(where: text.contains) { return .iCloud }
        return email(in: suggestion) == nil ? nil : .other
    }
    public static func email(in suggestion: String) -> String? {
        let pattern = #"[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9.-]*[A-Z0-9])?\.[A-Z]{2,}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive), let match = regex.firstMatch(in: suggestion, range: NSRange(suggestion.startIndex..., in: suggestion)), let range = Range(match.range, in: suggestion) else { return nil }
        let value = String(suggestion[range]); return MailAddress.isValid(value) ? value : nil
    }
    public static func forAccount(_ account: MailAccount) -> MailProvider {
        infer(account.imapHost + " " + account.email) ?? .other
    }
    public static func connectionDraft(_ suggestion: String, clientID: String? = nil) -> MailAccount {
        let provider = infer(suggestion) ?? .other
        var draft = MailAccount.preset(provider.rawValue)
        draft.email = email(in: suggestion) ?? ""
        if let clientID { draft.oauthClientID = clientID }
        return draft
    }
    public static func switching(_ account: MailAccount, from previous: String, to provider: String, clientID: String = "") -> MailAccount {
        var next = MailAccount.preset(provider)
        next.id = account.id; next.email = account.email; next.signature = account.signature
        if !account.name.isEmpty && account.name != previous && !allCases.contains(where: { $0.rawValue == account.name }) { next.name = account.name }
        next.oauthClientID = clientID
        return next
    }
}

public enum OAuthApplicationClients {
    public static func secretAccountID(provider: String, clientID: String) -> String { "oauth-application:" + provider + ":" + MailStore.hash(clientID) }
    public static func clientSecret(provider: String, clientID: String) throws -> String { try SecretStore.readOptional(accountID: secretAccountID(provider: provider, clientID: clientID)) ?? "" }
    public static func clientID(provider: String, bundle: Bundle = .main) -> String {
        let environment = provider == "google" ? "MORROW_GOOGLE_OAUTH_CLIENT_ID" : "MORROW_MICROSOFT_OAUTH_CLIENT_ID"
        if let value = ProcessInfo.processInfo.environment[environment], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        #if os(macOS)
        let local = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("Morrow/oauth-clients.json")
        if let local, let data = try? Data(contentsOf: local), let values = try? JSONDecoder().decode([String: String].self, from: data), let value = values[provider], !value.isEmpty { return value }
        #endif
        guard let url = bundle.url(forResource: "oauth-clients", withExtension: "json"), let data = try? Data(contentsOf: url), let values = try? JSONDecoder().decode([String: String].self, from: data) else { return "" }
        return values[provider] ?? ""
    }
}
