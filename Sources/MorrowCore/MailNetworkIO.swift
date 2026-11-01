import Foundation
import Network

/// One callback/continuation boundary shared by IMAP, POP and native SMTP.
/// Completed operations release their timeout capture immediately. Cancelling
/// a caller cancels the underlying socket, including a pending connect/write.
enum MailNetworkIO {
    static func connect(_ connection: NWConnection) async throws {
        defer { connection.stateUpdateHandler = nil }
        let _: Void = try await perform(connection, timeout: 20, timeoutMessage: "连接邮件服务器超时。") { gate in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.finish(.success(()))
                case .failed(let error): gate.finish(.failure(error))
                case .cancelled: gate.finish(.failure(MailError.message("邮件连接已关闭。")))
                default: break
                }
            }
            connection.start(queue: DispatchQueue.global(qos: .utility))
        }
    }
    static func receive(_ connection: NWConnection, timeout: TimeInterval = 90) async throws -> Data {
        try await perform(connection, timeout: timeout, timeoutMessage: "读取邮件服务器超时。") { gate in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, done, error in
                if let error { gate.finish(.failure(error)) }
                else if let data, !data.isEmpty { gate.finish(.success(data)) }
                else { gate.finish(.failure(MailError.message(done ? "邮件服务器已关闭连接。" : "邮件服务器返回了空响应。"))) }
            }
        }
    }
    static func write(_ data: Data, to connection: NWConnection) async throws {
        let _: Void = try await perform(connection, timeout: 90, timeoutMessage: "写入邮件服务器超时。") { gate in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { gate.finish(.failure(error)) } else { gate.finish(.success(())) }
            })
        }
    }
    private static func perform<T>(_ connection: NWConnection, timeout: TimeInterval, timeoutMessage: String, begin: @escaping (MailIOGate<T>) -> Void) async throws -> T {
        let gate = MailIOGate<T>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard gate.install(continuation) else { return }
                gate.schedule(timeout: timeout, connection: connection, message: timeoutMessage)
                begin(gate)
            }
        } onCancel: { gate.finish(.failure(CancellationError())); connection.cancel() }
    }
}

private final class MailIOGate<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var completed: Result<T, Error>?
    private var timer: DispatchWorkItem?
    func install(_ value: CheckedContinuation<T, Error>) -> Bool {
        lock.lock()
        if let result = completed { lock.unlock(); value.resume(with: result); return false }
        continuation = value; lock.unlock(); return true
    }
    func schedule(timeout: TimeInterval, connection: NWConnection, message: String) {
        let item = DispatchWorkItem { [weak self, weak connection] in
            if self?.finish(.failure(MailError.message(message))) == true { connection?.cancel() }
        }
        lock.lock()
        if completed != nil { lock.unlock(); item.cancel(); return }
        timer = item; lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: item)
    }
    @discardableResult func finish(_ result: Result<T, Error>) -> Bool {
        lock.lock(); guard completed == nil else { lock.unlock(); return false }
        completed = result
        let caller = continuation, timeout = timer; continuation = nil; timer = nil; lock.unlock()
        timeout?.cancel(); caller?.resume(with: result); return true
    }
}
