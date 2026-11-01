import Foundation
#if os(macOS)
import Darwin
#endif

public struct AgentSDKResult: Codable, Sendable {
    public var text: String
    public var modelCalls: Int
    public var toolCalls: Int
    public var runtime: String
    public var todos: [OpenUIJSON]
    public var paused: Bool?
    public var interrupts: [OpenUIJSON]?
    public var pauseReason: String?
}

/// Runs the installed SDK through a private, bounded stdio protocol. Model and
/// application tool requests are handled by the native host, never shell code.
public final class AgentSDKRuntime: @unchecked Sendable {
    #if os(macOS)
    private let bridge: URL
    private let node: URL
    public init(runtimeDirectory: URL? = nil) throws {
        let files = FileManager.default
        let resources = Bundle.main.resourceURL
        let sourceRuntime = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Runtime/AgentRuntime")
        let candidates = [runtimeDirectory, resources?.appendingPathComponent("AgentRuntime"), URL(fileURLWithPath: files.currentDirectoryPath).appendingPathComponent("Runtime/AgentRuntime"), sourceRuntime].compactMap { $0 }
        guard let runtime = candidates.first(where: { files.fileExists(atPath: $0.appendingPathComponent("bridge.mjs").path) && files.fileExists(atPath: $0.appendingPathComponent("node_modules/@openai/agents/package.json").path) }) else { throw MailError.message("OpenAI Agents SDK 尚未安装。") }
        bridge = runtime.appendingPathComponent("bridge.mjs")
        var nodes = [runtime.appendingPathComponent("node"), resources?.appendingPathComponent("SandboxRuntime/node"), URL(fileURLWithPath: "/usr/local/bin/node"), URL(fileURLWithPath: "/opt/homebrew/bin/node")].compactMap { $0 }
        let versions = files.homeDirectoryForCurrentUser.appendingPathComponent(".nvm/versions/node")
        if let entries = try? files.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil) { nodes += entries.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }.map { $0.appendingPathComponent("bin/node") } }
        guard let executable = nodes.first(where: { files.isExecutableFile(atPath: $0.path) }) else { throw MailError.message("OpenAI Agents SDK 的 Node.js 运行时不可用。") }
        node = executable.resolvingSymlinksInPath()
    }
    public func run(_ request: OpenUIJSON, maximumSeconds: Int = 3600,
        handle: @escaping @Sendable (String, OpenUIJSON, @escaping @Sendable (String) async throws -> Void) async throws -> OpenUIJSON,
        event: @escaping @Sendable (OpenUIJSON) async -> Void) async throws -> AgentSDKResult {
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("MorrowAgent-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { if process.isRunning { process.terminate() }; try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close(); try? FileManager.default.removeItem(at: workspace) }
        process.executableURL = node; process.arguments = ["--max-old-space-size=256", bridge.path]; process.currentDirectoryURL = workspace
        process.environment = ["PATH": node.deletingLastPathComponent().path + ":/usr/bin:/bin", "HOME": workspace.path, "TMPDIR": workspace.path, "LANG": "en_US.UTF-8", "LANGSMITH_TRACING": "false", "LANGCHAIN_TRACING_V2": "false"]
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        let writer = AgentProtocolWriter(input.fileHandleForWriting)
        try Task.checkCancellation(); try process.run()
        let lines = AgentProtocolLines.read(output.fileHandleForReading)
        let errorDescriptor = errors.fileHandleForReading.fileDescriptor
        DispatchQueue.global(qos: .utility).async { var buffer = [UInt8](repeating: 0, count: 4096); while Darwin.read(errorDescriptor, &buffer, buffer.count) > 0 {} }
        try await writer.send(request)
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: AgentSDKResult.self) { group in
                group.addTask {
                    try await withThrowingTaskGroup(of: Void.self) { requests in
                        var result: AgentSDKResult?
                        for try await bytes in lines {
                            try Task.checkCancellation()
                            let value = try JSONDecoder().decode(OpenUIJSON.self, from: bytes), fields = value.object
                            switch fields["type"]?.text {
                            case "request":
                                guard let id = fields["id"]?.text, let method = fields["method"]?.text, id.utf8.count <= 128 else { throw MailError.message("Agent 原生请求无效。") }
                                let params = fields["params"] ?? .null
                                requests.addTask {
                                    do {
                                        let reply = try await handle(method, params) { text in try await writer.send(.object(["type": .string("delta"), "id": .string(id), "text": .string(text)])) }
                                        try await writer.send(.object(["id": .string(id), "result": reply]))
                                    } catch {
                                        try Task.checkCancellation()
                                        try await writer.send(.object(["id": .string(id), "error": .string(String(error.localizedDescription.prefix(500)))]))
                                    }
                                }
                            case "complete":
                                result = try JSONDecoder().decode(AgentSDKResult.self, from: JSONEncoder().encode(fields["result"] ?? .null))
                            case "error": throw MailError.message("Agent SDK：" + String((fields["message"]?.text ?? "执行失败").prefix(500)))
                            default: await event(value)
                            }
                            if result != nil { break }
                        }
                        requests.cancelAll()
                        try Task.checkCancellation()
                        guard let result else { throw MailError.message("Agent SDK 运行已中断，已保存的会话状态可继续使用。") }
                        return result
                    }
                }
                group.addTask { try await Task.sleep(for: .seconds(min(14400, max(30, maximumSeconds)))); if process.isRunning { process.terminate() }; throw MailError.message("Agent 达到执行时间预算，已保存的会话状态可继续使用。") }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw CancellationError() }; return result
            }
        } onCancel: { if process.isRunning { process.terminate() } }
    }
    #else
    public init(runtimeDirectory: URL? = nil) throws { throw MailError.message("OpenAI Agents SDK 的本地工具引擎需要在 Mac 执行。") }
    public func run(_ request: OpenUIJSON, maximumSeconds: Int = 3600,
        handle: @escaping @Sendable (String, OpenUIJSON, @escaping @Sendable (String) async throws -> Void) async throws -> OpenUIJSON,
        event: @escaping @Sendable (OpenUIJSON) async -> Void) async throws -> AgentSDKResult { throw MailError.message("OpenAI Agents SDK 的本地工具引擎需要在 Mac 执行。") }
    #endif
}

#if os(macOS)
private actor AgentProtocolWriter {
    private let file: FileHandle
    init(_ file: FileHandle) { self.file = file }
    func send(_ value: OpenUIJSON) throws {
        var bytes = try JSONEncoder().encode(value)
        guard bytes.count <= 24 * 1024 * 1024 else { throw MailError.message("Agent 原生协议记录超过大小限制。") }
        bytes.append(10); try file.write(contentsOf: bytes)
    }
}
private enum AgentProtocolLines {
    static func read(_ file: FileHandle) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(256)) { continuation in
            let descriptor = file.fileDescriptor
            DispatchQueue.global(qos: .utility).async {
                do {
                    var buffer = Data(), offset = 0, total = 0
                    var block = [UInt8](repeating: 0, count: 8192)
                    while true {
                        let count = Darwin.read(descriptor, &block, block.count)
                        if count == 0 { break }
                        if count < 0 { if errno == EINTR { continue }; throw MailError.message("Agent 协议管道已关闭。") }
                        let next = Data(block.prefix(count)); total += count
                        guard total <= 128 * 1024 * 1024 else { throw MailError.message("Agent 运行输出达到大小预算。") }
                        buffer.append(next)
                        while let end = buffer[offset...].firstIndex(of: 10) {
                            let line = Data(buffer[offset..<end]); offset = end + 1
                            guard line.count <= 24 * 1024 * 1024 else { throw MailError.message("Agent 协议记录过大。") }
                            if case .dropped = continuation.yield(line) { throw MailError.message("Agent 事件队列已满。") }
                        }
                        if offset >= 65536 { buffer = Data(buffer[offset...]); offset = 0 }
                        guard buffer.count - offset <= 24 * 1024 * 1024 else { throw MailError.message("Agent 协议记录过大。") }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in try? file.close() }
        }
    }
}
#endif
