import Foundation
import Network

struct MCPHTTPRequest {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
    static let maximumHeaderBytes = 16384
    static let maximumBodyBytes = 1024 * 1024

    /// Returns nil until a complete request arrives. Ambiguous framing is
    /// rejected; one connection carries exactly one request.
    static func parse(_ bytes: Data) throws -> MCPHTTPRequest? {
        guard let separator = bytes.range(of: Data("\r\n\r\n".utf8)) else {
            if bytes.count > maximumHeaderBytes { throw MCPHTTPError(status: 431) }
            return nil
        }
        guard separator.lowerBound <= maximumHeaderBytes,
              let header = String(data: bytes[..<separator.lowerBound], encoding: .utf8) else { throw MCPHTTPError(status: 400) }
        let lines = header.components(separatedBy: "\r\n"), words = lines[0].split(separator: " ")
        guard words.count == 3, words[2] == "HTTP/1.1", words[1].hasPrefix("/") else { throw MCPHTTPError(status: 400) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { throw MCPHTTPError(status: 400) }
            let name = String(line[..<colon]).lowercased(), value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }), headers[name] == nil,
                  !value.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 9 }) else { throw MCPHTTPError(status: 400) }
            headers[name] = value
        }
        guard headers["host"] != nil, headers["transfer-encoding"] == nil else { throw MCPHTTPError(status: 400) }
        if words[0] == "POST", headers["content-length"] == nil { throw MCPHTTPError(status: 411) }
        let lengthText = headers["content-length"] ?? "0"
        guard !lengthText.isEmpty, lengthText.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(lengthText) else { throw MCPHTTPError(status: 400) }
        guard length <= maximumBodyBytes else { throw MCPHTTPError(status: 413) }
        let end = separator.upperBound + length
        guard bytes.count >= end else { return nil }
        guard bytes.count == end else { throw MCPHTTPError(status: 400) }
        return MCPHTTPRequest(method: String(words[0]), target: String(words[1]), headers: headers, body: bytes[separator.upperBound..<end])
    }
}
struct MCPHTTPError: Error { let status: Int }

public final class MCPHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "app.smail.mcp.http")
    private let authorization: MCPAuthorization
    private let rpc: MCPProtocol
    private let allowLAN: Bool
    private let readiness = MCPListenerReadiness()
    // Accessed only on queue.
    private var clients: [UUID: MCPHTTPPeer] = [:]
    private var stopped = false
    private var boundPort: UInt16 = 0
    private var cancelled = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    public var onFailure: (@Sendable () -> Void)?

    public init(port: UInt16, allowLAN: Bool, authorization: MCPAuthorization, store: MailStore) throws {
        self.authorization = authorization; self.allowLAN = allowLAN; rpc = MCPProtocol(store: store)
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(allowLAN ? "0.0.0.0" : "127.0.0.1"), port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: parameters)
    }
    public func start() async throws -> UInt16 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                readiness.install(continuation)
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard !self.stopped, let port = self.listener.port else { self.readiness.finish(.failure(CancellationError())); return }
                        self.boundPort = port.rawValue; self.readiness.finish(.success(port.rawValue))
                    case .failed:
                        self.readiness.finish(.failure(MailError.message("MCP 服务启动失败，请检查端口是否已被占用。")))
                        if !self.stopped { self.onFailure?() }; self.close()
                    case .cancelled:
                        self.cancelled = true; self.readiness.finish(.failure(CancellationError()))
                        let waiters = self.stopWaiters; self.stopWaiters.removeAll(); waiters.forEach { $0.resume() }
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self, !self.stopped, self.clients.count < 32 else { connection.cancel(); return }
                    let peer = MCPHTTPPeer(connection: connection), id = UUID()
                    self.clients[id] = peer
                    connection.start(queue: self.queue)
                    let timeout = DispatchWorkItem { [weak self] in self?.finish(id) }
                    peer.timeout = timeout; self.queue.asyncAfter(deadline: .now() + 15, execute: timeout)
                    self.receive(id, buffer: Data())
                }
                listener.start(queue: queue)
            }
        } onCancel: { self.stop() }
    }
    public func stop() { queue.async { [self] in close() } }
    deinit { listener.cancel() }
    public func stopAndWait() async {
        await withCheckedContinuation { continuation in queue.async { [self] in
            if cancelled { continuation.resume(); return }
            stopWaiters.append(continuation); close()
        } }
    }
    private func close() {
        guard !stopped else { return }; stopped = true
        listener.cancel(); readiness.finish(.failure(CancellationError()))
        for id in Array(clients.keys) { finish(id) }
    }
    private func finish(_ id: UUID) {
        guard let peer = clients.removeValue(forKey: id) else { return }
        peer.timeout?.cancel(); peer.task?.cancel(); peer.connection.cancel()
    }
    private func receive(_ id: UUID, buffer: Data) {
        guard let peer = clients[id] else { return }
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self, self.clients[id] != nil else { return }
            var buffer = buffer; if let data { buffer.append(data) }
            guard error == nil else { self.finish(id); return }
            do {
                if let request = try MCPHTTPRequest.parse(buffer) { self.serve(id, request: request) }
                else if complete { self.respond(id, status: 400) }
                else { self.receive(id, buffer: buffer) }
            } catch let failure as MCPHTTPError { self.respond(id, status: failure.status) }
            catch { self.respond(id, status: 400) }
        }
    }
    private func serve(_ id: UUID, request: MCPHTTPRequest) {
        // Browsers are not clients of this endpoint; rejecting Origin prevents
        // cross-origin access and DNS rebinding on the loopback listener.
        guard request.headers["origin"] == nil else { respond(id, status: 403); return }
        if !allowLAN {
            let hosts = ["127.0.0.1:\(boundPort)", "localhost:\(boundPort)"]
            guard hosts.contains(request.headers["host"]?.lowercased() ?? "") else { respond(id, status: 403); return }
        }
        guard request.target == "/mcp" else { respond(id, status: 404); return }
        guard authorization.accepts(request.headers["authorization"]) else { respond(id, status: 401); return }
        guard request.method == "POST" else { respond(id, status: 405); return }
        guard request.headers["content-type"]?.components(separatedBy: ";").first?.lowercased().trimmingCharacters(in: .whitespaces) == "application/json" else { respond(id, status: 415); return }
        let accepted = (request.headers["accept"] ?? "").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard accepted.contains("application/json"), accepted.contains("text/event-stream") else { respond(id, status: 406); return }
        if let version = request.headers["mcp-protocol-version"], !MCPProtocol.versions.contains(version) { respond(id, status: 400); return }
        clients[id]?.task = Task { [weak self, rpc] in
            let result = await rpc.handle(request.body)
            guard !Task.isCancelled, let self else { return }
            self.queue.async {
                // A reset must invalidate work that was waiting for the store.
                guard self.authorization.accepts(request.headers["authorization"]) else { self.respond(id, status: 401); return }
                if let result, let data = try? JSONEncoder().encode(result) { self.respond(id, status: 200, body: data) }
                else { self.respond(id, status: 202) }
            }
        }
    }
    private func respond(_ id: UUID, status: Int, body: Data = Data()) {
        guard let peer = clients[id] else { return }
        let reasons = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable", 411: "Length Required", 413: "Content Too Large", 415: "Unsupported Media Type", 431: "Request Header Fields Too Large"]
        var header = "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n"
        if status == 401 { header += "WWW-Authenticate: Bearer realm=\"Morrow MCP\"\r\n" }
        if status == 405 { header += "Allow: POST\r\n" }
        header += "\r\n"
        peer.connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { [weak self] _ in self?.finish(id) })
    }
}
private final class MCPHTTPPeer {
    let connection: NWConnection
    var task: Task<Void, Never>?
    var timeout: DispatchWorkItem?
    init(connection: NWConnection) { self.connection = connection }
}
private final class MCPListenerReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UInt16, Error>?
    private var result: Result<UInt16, Error>?
    func install(_ continuation: CheckedContinuation<UInt16, Error>) {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result) }
        else { self.continuation = continuation; lock.unlock() }
    }
    func finish(_ result: Result<UInt16, Error>) {
        lock.lock(); guard self.result == nil else { lock.unlock(); return }
        self.result = result; let continuation = self.continuation; self.continuation = nil
        lock.unlock(); continuation?.resume(with: result)
    }
}
