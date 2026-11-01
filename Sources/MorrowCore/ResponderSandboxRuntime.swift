import Foundation

public struct ResponderSandboxResult: Codable, Sendable {
    public var exitCode: Int
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public var truncated: Bool
    public var violations: Int
    public var runtime: String
    public var unavailable: Bool?
}

/// The bridge is trusted host code; commands only receive staged source text,
/// an empty environment, and the filesystem/network policy enforced by SRT.
public final class ResponderSandboxRuntime: @unchecked Sendable {
    public let workspace: URL
    private let node: URL
    private let bridge: URL
    public init() throws {
        #if os(macOS)
        let fm = FileManager.default
        let bundles = [Bundle.main.resourceURL?.appendingPathComponent("SandboxRuntime"), URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Runtime/SandboxRuntime")].compactMap { $0 }
        guard let runtime = bundles.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("bridge.mjs").path) && fm.fileExists(atPath: $0.appendingPathComponent("node_modules/@anthropic-ai/sandbox-runtime/package.json").path) }) else { throw MailError.message("Anthropic Sandbox Runtime 尚未安装，响应器已停止；不会降级为无沙箱执行。") }
        bridge = runtime.appendingPathComponent("bridge.mjs")
        var nodes = [runtime.appendingPathComponent("node"), URL(fileURLWithPath: "/opt/homebrew/bin/node"), URL(fileURLWithPath: "/usr/local/bin/node")]
        let versions = fm.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node")
        if let directories = try? fm.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil) { nodes += directories.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }.map { $0.appendingPathComponent("bin/node") } }
        guard let executable = nodes.first(where: { fm.isExecutableFile(atPath: $0.path) }) else { throw MailError.message("响应器需要 Node.js 22.12 或更新版本；沙箱不可用时不会执行工具。") }
        node = executable.resolvingSymlinksInPath()
        // SRT uses Unix sockets. macOS's per-user temporary path plus a UUID
        // exceeds sockaddr_un's limit; a short private workspace avoids it.
        workspace = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("MorrowResponder-" + String(UUID().uuidString.prefix(16)), isDirectory: true)
        try fm.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for directory in ["input", "output", "tmp"] { try fm.createDirectory(at: workspace.appendingPathComponent(directory), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        #else
        throw MailError.message("此设备不支持 Anthropic Sandbox Runtime；响应器工具需要在 Mac 执行。")
        #endif
    }
    deinit { try? FileManager.default.removeItem(at: workspace) }
    public func stageText(_ text: String, name: String) throws {
        guard ["mail.txt", "attachment.txt"].contains(name), text.utf8.count <= 256 * 1024 else { throw MailError.message("沙箱资料超过限制。") }
        let target = workspace.appendingPathComponent("input/" + name)
        // Only host-created fixed filenames are staged; model paths are never used.
        try Data(text.utf8).write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: target.path)
    }
    public func run(_ command: String, policy: ResponderExecutionPolicy) async throws -> ResponderSandboxResult {
        #if os(macOS)
        try policy.validate()
        let root = workspace, node = node, bridge = bridge
        let request = try JSONSerialization.data(withJSONObject: ["workspace": root.path, "allowedDomains": policy.networkDomains, "command": command, "timeoutSeconds": policy.commandSeconds])
        let process = Process()
        return try await withTaskCancellationHandler {
            let worker = Task.detached(priority: .utility) { () throws -> ResponderSandboxResult in
                try Task.checkCancellation()
                let input = Pipe(), output = Pipe(), errors = Pipe()
                process.executableURL = node; process.arguments = [bridge.path]; process.currentDirectoryURL = root
                process.environment = ["PATH": node.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "HOME": root.path, "TMPDIR": root.appendingPathComponent("tmp").path, "LANG": "en_US.UTF-8"]
                process.standardInput = input; process.standardOutput = output; process.standardError = errors
                try process.run(); try input.fileHandleForWriting.write(contentsOf: request); try input.fileHandleForWriting.close()
                if Task.isCancelled { process.terminate(); throw CancellationError() }
                // The bridge bounds its combined child output to128 KiB and
                // emits one JSON response; stderr is limited to startup errors.
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let error = errors.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                guard data.count <= 1024 * 1024, let result = try? JSONDecoder().decode(ResponderSandboxResult.self, from: data) else {
                    throw MailError.message("沙箱未能执行工具：" + String(String(decoding: error.prefix(1500), as: UTF8.self).suffix(500)))
                }
                if result.unavailable == true { throw MailError.message("沙箱不可用，未执行工具：" + String(result.stderr.prefix(1000))) }
                return result
            }
            return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel(); if process.isRunning { process.terminate() } }
        } onCancel: { if process.isRunning { process.terminate() } }
        #else
        throw MailError.message("Anthropic Sandbox Runtime 的响应器工具需要在 Mac 执行。")
        #endif
    }
}
