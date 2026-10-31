import Foundation

/// Only endpoint/credential digests and model names are retained. Short-lived
/// failures avoid repeated slow catalog probes during background analysis.
actor AIModelCatalogCache {
    static let shared = AIModelCatalogCache()
    private struct Entry { var result: Result<[String], Error>; var expires: Date; var used: Date }
    private struct Flight { let id: UUID; let task: Task<[String], Error> }
    private var entries: [String: Entry] = [:]
    private var flights: [String: Flight] = [:]
    func models(endpoint: String, credential: String, loader: @Sendable @escaping () async throws -> [String]) async throws -> [String] {
        try Task.checkCancellation()
        let key = MailStore.hash(endpoint + ":" + MailStore.hash(credential))
        if var entry = entries[key], entry.expires > Date() { entry.used = Date(); entries[key] = entry; return try entry.result.get() }
        let flight: Flight
        if let existing = flights[key] { flight = existing }
        else {
            guard flights.count < 16 else { throw MailError.message("模型目录请求过多，请稍后重试。") }
            flight = Flight(id: UUID(), task: Task { try await loader() }); flights[key] = flight
            Task { [flight] in let result = await flight.task.result; self.finished(key, id: flight.id, result: result) }
        }
        let gate = CatalogWaitGate()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.begin(continuation)
                Task { let result = await flight.task.result; gate.finish(result) }
            }
        } onCancel: { gate.finish(.failure(CancellationError())) }
    }
    private func finished(_ key: String, id: UUID, result: Result<[String], Error>) {
        guard flights[key]?.id == id else { return }; flights[key] = nil
        let ttl: TimeInterval
        switch result { case .success: ttl = 30; case .failure: ttl = 5 }
        entries[key] = Entry(result: result, expires: Date().addingTimeInterval(ttl), used: Date())
        if entries.count > 16, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key { entries[oldest] = nil }
    }
}

private final class CatalogWaitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String], Error>?
    private var completed: Result<[String], Error>?
    func begin(_ value: CheckedContinuation<[String], Error>) {
        lock.lock()
        if let result = completed { lock.unlock(); value.resume(with: result); return }
        continuation = value; lock.unlock()
    }
    func finish(_ result: Result<[String], Error>) {
        lock.lock(); guard completed == nil else { lock.unlock(); return }; completed = result
        let value = continuation; continuation = nil; lock.unlock(); value?.resume(with: result)
    }
}

enum AIInputBounds {
    static let textBytes = 256 * 1024
    static func validate(system: String, prompt: String, images: [Data], maxTokens: Int) throws {
        guard maxTokens > 0 && maxTokens <= 16_384 else { throw MailError.message("模型输出长度设置超过限制。") }
        guard system.utf8.count <= textBytes && prompt.utf8.count <= textBytes - system.utf8.count else { throw MailError.message("本轮资料超过模型请求大小限制，请分批处理。") }
        guard images.count <= 8, images.allSatisfy({ $0.count <= 8 * 1024 * 1024 }), images.reduce(0, { $0 + $1.count }) <= 16 * 1024 * 1024 else { throw MailError.message("本轮图片超过模型请求大小限制，请减少图片。") }
    }
}
