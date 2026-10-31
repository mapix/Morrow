import Foundation
import Network

actor MailSocket {
    private var connection: NWConnection?
    private var buffer = Data()
    private var bufferOffset = 0
    var connected: Bool { connection != nil }
    func connect(host: String, port: Int, tls: Bool) async throws {
        close(); try Task.checkCancellation(); guard (1...65535).contains(port), let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw MailError.message("邮件端口无效。") }
        let parameters: NWParameters
        if tls { let options = NWProtocolTLS.Options(); sec_protocol_options_set_tls_server_name(options.securityProtocolOptions, host); parameters = NWParameters(tls: options, tcp: NWProtocolTCP.Options()) }
        else { guard ["127.0.0.1", "localhost"].contains(host) else { throw MailError.message("邮件连接必须使用TLS。") }; parameters = .tcp }
        let c = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters); connection = c
        do { try await MailNetworkIO.connect(c) } catch { close(); throw error }
    }
    func close() { connection?.cancel(); connection = nil; buffer = Data(); bufferOffset = 0 }
    func write(_ data: Data) async throws {
        guard let c = connection else { throw MailError.message("邮件连接未建立。") }
        do { try await MailNetworkIO.write(data, to: c) } catch { close(); throw error }
    }
    func lineData() async throws -> Data {
        try Task.checkCancellation()
        var searchOffset = bufferOffset
        while true {
            if let range = buffer.range(of: Data([13, 10]), in: searchOffset..<buffer.count) {
                guard range.lowerBound - bufferOffset <= 4 * 1024 * 1024 else { close(); throw MailError.message("邮件响应行过长。") }
                let line = Data(buffer[bufferOffset..<range.lowerBound]); bufferOffset = range.upperBound
                if bufferOffset == buffer.count { buffer = Data(); bufferOffset = 0 }
                else if bufferOffset >= 256 * 1024 { buffer = Data(buffer[bufferOffset...]); bufferOffset = 0 }
                return line
            }
            guard buffer.count - bufferOffset <= 4 * 1024 * 1024 else { close(); throw MailError.message("邮件响应行过长。") }
            searchOffset = max(bufferOffset, buffer.count - 1); try await receive()
        }
    }
    func line() async throws -> String { let data = try await lineData(); return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? "" }
    private func receive() async throws {
        guard let c = connection else { throw MailError.message("邮件连接未建立。") }
        do {
            let data = try await MailNetworkIO.receive(c)
            guard connection === c else { throw CancellationError() }; buffer.append(data)
        } catch { close(); throw error }
    }
}
