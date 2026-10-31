import Foundation
import Network

actor MailSocket {
    private var connection: NWConnection?
    private var buffer = Data()
    var connected: Bool { connection != nil }
    func connect(host: String, port: Int, tls: Bool) async throws {
        close(); guard (1...65535).contains(port), let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw MailError.message("邮件端口无效。") }
        let parameters: NWParameters
        if tls { let options = NWProtocolTLS.Options(); sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, host); parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options()) }
        else { guard ["127.0.0.1", "localhost"].contains(host) else { throw MailError.message("邮件连接必须使用TLS。") }; parameters = .tcp }
        let c = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters); connection = c
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = SocketGate<Void>(continuation)
            c.stateUpdateHandler = { state in switch state { case .ready: gate.finish(.success(())); case .failed(let error): gate.finish(.failure(error)); case .cancelled: gate.finish(.failure(MailError.message("邮件连接已关闭。"))); default: break } }
            c.start(queue: DispatchQueue.global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { if gate.finish(.failure(MailError.message("连接邮件服务器超时。"))) { c.cancel() } }
        }
    }
    func close() { connection?.cancel(); connection = nil; buffer = Data() }
    func write(_ data: Data) async throws {
        guard let c = connection else { throw MailError.message("邮件连接未建立。") }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in c.send(content: data, completion: .contentProcessed { error in if let error { cont.resume(throwing: error) } else { cont.resume() } }) }
    }
    func lineData() async throws -> Data {
        while buffer.range(of: Data([13, 10])) == nil { try await receive(); guard buffer.count <= 4 * 1024 * 1024 else { throw MailError.message("邮件响应行过长。") } }
        let range = buffer.range(of: Data([13, 10]))!; let line = Data(buffer[..<range.lowerBound]); buffer.removeSubrange(..<range.upperBound); return line
    }
    func line() async throws -> String { let data = try await lineData(); return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? "" }
    private func receive() async throws {
        guard let c = connection else { throw MailError.message("邮件连接未建立。") }
        let data: Data = try await withCheckedThrowingContinuation { cont in
            let gate = SocketGate<Data>(cont)
            c.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, _, error in
                if let error { gate.finish(.failure(error)) } else if let data, !data.isEmpty { gate.finish(.success(data)) } else { gate.finish(.failure(MailError.message("邮件服务器关闭了连接。"))) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 90) { if gate.finish(.failure(MailError.message("邮件读取超时。"))) { c.cancel() } }
        }; buffer.append(data)
    }
}
private final class SocketGate<T>: @unchecked Sendable {
    private let lock = NSLock(); private var continuation: CheckedContinuation<T, Error>?
    init(_ c: CheckedContinuation<T, Error>) { continuation = c }
    @discardableResult func finish(_ result: Result<T, Error>) -> Bool { lock.lock(); let c = continuation; continuation = nil; lock.unlock(); guard let c else { return false }; c.resume(with: result); return true }
}
