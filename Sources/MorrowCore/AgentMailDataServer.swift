import Foundation
#if os(macOS)
import Darwin

/// The sandbox sees one private query socket, never a database path or handle.
final class AgentMailDataServer: @unchecked Sendable {
    private let listener: Int32
    private let path: String
    private let data: AgentMailData
    private let lock = NSLock()
    private var stopped = false
    init(path: URL, data: AgentMailData) throws {
        self.path = path.path; self.data = data
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw MailError.message("无法启动邮件数据接口。") }
        listener = descriptor
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { Darwin.close(descriptor); throw MailError.message("数据接口路径过长。") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, Darwin.listen(descriptor, 4) == 0 else { Darwin.close(descriptor); throw MailError.message("无法绑定邮件数据接口。") }
        DispatchQueue.global(qos: .utility).async { [self] in
            while !isStopped {
                let client = Darwin.accept(listener, nil, nil)
                if client < 0 { if errno == EINTR { continue }; break }
                var timeout = timeval(tv_sec: 6, tv_usec: 0), noSignal: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
                serve(client); Darwin.close(client)
            }
        }
    }
    private var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func stop() {
        lock.lock(); let close = !stopped; stopped = true; lock.unlock()
        if close { Darwin.shutdown(listener, SHUT_RDWR); Darwin.close(listener); unlink(path) }
    }
    deinit { stop() }
    private func serve(_ client: Int32) {
        var request = Data(), block = [UInt8](repeating: 0, count: 4096)
        while request.count <= 65536 {
            let count = Darwin.read(client, &block, block.count)
            if count <= 0 { return }
            request.append(contentsOf: block.prefix(count))
            if request.contains(10) { break }
        }
        guard request.count <= 65536, let end = request.firstIndex(of: 10) else { return }
        let response: OpenUIJSON
        do {
            let fields = try JSONDecoder().decode(OpenUIJSON.self, from: request[..<end]).object
            response = try data.query(fields["sql"]?.text ?? "", maximumRows: Int(fields["max_rows"]?.text ?? "1000") ?? 1000)
        } catch { response = .object(["error": .string(String(error.localizedDescription.prefix(500)))]) }
        guard var encoded = try? JSONEncoder().encode(response) else { return }
        encoded.append(10)
        encoded.withUnsafeBytes { pointer in
            var offset = 0
            while offset < encoded.count {
                let count = Darwin.write(client, pointer.baseAddress!.advanced(by: offset), encoded.count - offset)
                if count <= 0 { break }; offset += count
            }
        }
    }
}
#endif
