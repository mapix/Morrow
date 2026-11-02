import Foundation
import MorrowCore

@MainActor final class MCPServerModel: ObservableObject {
    @Published private(set) var settings = MCPServerSettings()
    @Published private(set) var token = ""
    @Published private(set) var running = false
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private let store: MailStore
    private let tokenStorage: any MCPTokenStorage
    private let foregroundTokenStorage: any MCPTokenStorage
    private let preview: Bool
    private var prepared = false
    private var server: MCPHTTPServer?
    private let authorization = MCPAuthorization(token: "")
    var endpoint: String { settings.endpoint }
    var clientConfiguration: String {
        let config: [String: Any] = ["mcpServers": ["morrow": ["url": endpoint, "headers": ["Authorization": "Bearer \(token)"]]]]
        return (try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    init(store: MailStore, tokenStorage: (any MCPTokenStorage)? = nil, preview: Bool = false) {
        self.store = store; self.preview = preview
        self.tokenStorage = tokenStorage ?? MCPKeychainTokenStorage(root: store.root)
        foregroundTokenStorage = tokenStorage ?? MCPKeychainTokenStorage(root: store.root, allowInteraction: true)
    }
    func restore() async {
        guard !prepared, !busy, !preview else { return }
        busy = true; defer { busy = false }
        do {
            let saved = try await store.load(MCPServerSettings.self, kind: "mcp-server-settings").first ?? MCPServerSettings()
            try saved.validate(); settings = saved
            try loadToken(); prepared = true; error = nil
            if settings.enabled { try await startServer() }
        } catch { self.error = error.localizedDescription }
    }
    private func loadToken() throws {
        if let existing = try tokenStorage.read(), !existing.isEmpty { token = existing }
        else { let value = try MCPAuthorization.generateToken(); try tokenStorage.write(value); token = value }
        authorization.rotate(to: token)
    }
    func retry() async {
        guard !busy, !preview else { return }
        // This explicit foreground action can authorize Keychain access.
        do {
            if let existing = try foregroundTokenStorage.read(), !existing.isEmpty { token = existing }
            else { let value = try MCPAuthorization.generateToken(); try foregroundTokenStorage.write(value); token = value }
            authorization.rotate(to: token)
        } catch { self.error = error.localizedDescription; return }
        if !prepared { await restore() }
        else if settings.enabled { await update(settings) }
    }
    func update(_ value: MCPServerSettings) async {
        guard !busy, !preview else { return }
        busy = true; defer { busy = false }
        do {
            try value.validate()
            if token.isEmpty { try loadToken() }
            try await store.save(value, kind: "mcp-server-settings", id: "current")
            prepared = true
            let previous = server; server = nil; running = false
            await previous?.stopAndWait(); settings = value; error = nil
            if value.enabled { try await startServer() }
        } catch { self.error = error.localizedDescription }
    }
    private func startServer() async throws {
        let listener = try MCPHTTPServer(port: UInt16(settings.port), allowLAN: settings.allowLAN, authorization: authorization, store: store)
        listener.onFailure = { [weak self, weak listener] in Task { @MainActor in
            guard let self, self.server === listener else { return }
            self.running = false; self.error = "MCP 服务启动失败，请检查端口是否已被占用。"
        } }
        server = listener
        _ = try await listener.start()
        guard server === listener else { listener.stop(); throw CancellationError() }
        running = true
    }
    func resetToken() {
        guard !busy, !preview else { return }
        do {
            let value = try MCPAuthorization.generateToken()
            try foregroundTokenStorage.write(value)
            authorization.rotate(to: value); token = value
            if running || !settings.enabled { error = nil }
        } catch { self.error = error.localizedDescription }
    }
    func stop() { server?.stop(); server = nil; running = false }
    deinit { server?.stop() }
}
