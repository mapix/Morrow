import SwiftUI
import AppKit
import MorrowCore

struct MCPServerSettingsView: View {
    @ObservedObject var server: MCPServerModel
    @State private var port = ""
    @State private var revealToken = false
    @State private var copied: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(L10n.t("启用 MCP Server"), isOn: Binding(get: { server.settings.enabled }, set: { enabled in
                    var value = server.settings; value.enabled = enabled; Task { await server.update(value) }
                })).accessibilityIdentifier("settings.mcp.enabled")
                HStack(spacing: 8) {
                    Circle().fill(server.running ? Theme.accent2 : Theme.secondary).frame(width: 7, height: 7)
                    Text(L10n.t(server.busy ? "MCP 服务正在更新…" : server.running ? "MCP 服务运行中" : "MCP 服务已停止")).font(Theme.label).foregroundStyle(Theme.secondary)
                    if server.busy { ProgressView().controlSize(.small) }
                }
                Text(L10n.t("允许 MCP 客户端查询本机邮件、联系人和简报。邮件发送与修改不通过此接口开放。")).font(Theme.label).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(Theme.rule)
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.t("HTTP 连接")).font(Theme.heading)
                HStack {
                    Text(L10n.t("监听端口")).font(Theme.body)
                    TextField(L10n.t("监听端口"), text: $port).textFieldStyle(PaperFieldStyle()).frame(width: 110).accessibilityIdentifier("settings.mcp.port")
                    Button(L10n.t("应用端口")) { guard let number = Int(port) else { return }; var value = server.settings; value.port = number; Task { await server.update(value) } }
                        .buttonStyle(QuietButtonStyle()).disabled(Int(port).map { !(1024...65535).contains($0) || $0 == server.settings.port } ?? true)
                    Text(L10n.t("1024–65535")).font(Theme.label).foregroundStyle(Theme.secondary)
                }
                Toggle(L10n.t("允许局域网连接"), isOn: Binding(get: { server.settings.allowLAN }, set: { enabled in
                    var value = server.settings; value.allowLAN = enabled; Task { await server.update(value) }
                })).accessibilityIdentifier("settings.mcp.lan")
                Text(L10n.t(server.settings.allowLAN ? "局域网客户端请将地址中的 127.0.0.1 换成此 Mac 的局域网 IP。HTTP 连接适用于可信网络；远程访问请通过 HTTPS 代理。" : "仅此 Mac 上的客户端可以连接。关闭窗口后服务继续运行，退出 Morrow 后停止。")).font(Theme.label).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(server.endpoint).font(.system(.body, design: .monospaced)).textSelection(.enabled).accessibilityIdentifier("settings.mcp.endpoint")
                    Spacer()
                    Button(L10n.t("复制地址")) { copy(server.endpoint, label: "地址已复制") }.buttonStyle(QuietButtonStyle())
                }
            }
            Divider().overlay(Theme.rule)
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.t("认证 token")).font(Theme.heading)
                HStack {
                    Group {
                        if revealToken { Text(server.token).textSelection(.enabled) }
                        else { Text(server.token.isEmpty ? "—" : String(repeating: "•", count: 24)) }
                    }.font(.system(.body, design: .monospaced)).lineLimit(2).accessibilityIdentifier("settings.mcp.token")
                    Spacer()
                    Button { revealToken.toggle() } label: { Image(systemName: revealToken ? "eye.slash" : "eye") }.buttonStyle(.plain).help(L10n.t(revealToken ? "隐藏 token" : "显示 token"))
                    Button(L10n.t("复制 token")) { copy(server.token, label: "token 已复制") }.buttonStyle(QuietButtonStyle()).disabled(server.token.isEmpty).accessibilityIdentifier("settings.mcp.copy-token")
                }
                Text(L10n.t("token 自动生成并保存在本机钥匙串。客户端使用 Authorization: Bearer <token>；重置会立即使旧 token 失效。")).font(Theme.label).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L10n.t("重置 token")) { server.resetToken(); copied = server.error == nil ? "token 已重置" : nil }.buttonStyle(QuietButtonStyle()).accessibilityIdentifier("settings.mcp.reset-token")
                    Button(L10n.t("复制 MCP 配置")) { copy(server.clientConfiguration, label: "MCP 配置已复制") }.buttonStyle(QuietButtonStyle()).disabled(server.token.isEmpty).accessibilityIdentifier("settings.mcp.copy-config")
                }
                Text(L10n.t("将复制的配置添加到支持 HTTP 的 MCP 客户端。配置包含 token，请妥善保存。")).font(Theme.label).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                if let copied { Text(L10n.t(copied)).font(Theme.label).foregroundStyle(Theme.accent2).accessibilityIdentifier("settings.mcp.feedback") }
            }
            if let error = server.error {
                Text(L10n.t(error)).font(Theme.label).foregroundStyle(Theme.error).textSelection(.enabled)
                Button(L10n.t("重试 MCP 服务")) { Task { await server.retry() } }.buttonStyle(QuietButtonStyle())
            }
        }.disabled(server.busy).task { await server.restore(); port = String(server.settings.port) }
            .onChange(of: server.settings.port) { _, value in port = String(value) }
    }
    private func copy(_ text: String, label: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string); copied = label
    }
}
