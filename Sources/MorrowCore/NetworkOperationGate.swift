import Foundation

public enum AIRequestPriority: Sendable, Equatable { case interactive, background }

/// A bounded, cancellation-aware FIFO with an interactive reserve. It owns
/// permits, never network connections or user data.
public actor NetworkOperationGate {
    public static let inference = NetworkOperationGate(capacity: 2, maximumBackground: 1, maximumWaiters: 32)
    private struct Waiter { let id: UUID; let priority: AIRequestPriority; let continuation: CheckedContinuation<UUID, Error> }
    private let capacity: Int
    private let maximumBackground: Int
    private let maximumWaiters: Int
    private var active: [UUID: AIRequestPriority] = [:]
    private var waiters: [Waiter] = []
    private var foregroundGrants = 0
    private var closed = false
    public init(capacity: Int = 1, maximumBackground: Int = 1, maximumWaiters: Int = 64) {
        self.capacity = max(1, capacity); self.maximumBackground = max(1, min(capacity, maximumBackground)); self.maximumWaiters = max(1, maximumWaiters)
    }
    public func acquire(priority: AIRequestPriority = .interactive) async throws -> UUID {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                guard !closed else { continuation.resume(throwing: CancellationError()); return }
                let canUseIdlePermit = active.count < capacity && (priority == .interactive || active.values.filter { $0 == .background }.count < maximumBackground)
                guard waiters.count < maximumWaiters || canUseIdlePermit else { continuation.resume(throwing: MailError.message("请求队列已满，请稍后重试。")); return }
                waiters.append(Waiter(id: id, priority: priority, continuation: continuation)); grantWaiting()
            }
        } onCancel: { Task { await self.cancelWaiting(id) } }
    }
    public func release(_ id: UUID) { active[id] = nil; grantWaiting() }
    func invalidate() {
        closed = true
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.continuation.resume(throwing: CancellationError()) }
    }
    public func withPermit<T>(priority: AIRequestPriority = .interactive, operation: @Sendable () async throws -> T) async throws -> T {
        let id = try await acquire(priority: priority)
        do { try Task.checkCancellation(); let value = try await operation(); release(id); return value }
        catch { release(id); throw error }
    }
    public func counts() -> (active: Int, waiting: Int) { (active.count, waiters.count) }
    private func cancelWaiting(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    private func grantWaiting() {
        guard !closed else { return }
        while active.count < capacity {
            let backgroundCount = active.values.filter { $0 == .background }.count
            let foreground = waiters.firstIndex { $0.priority == .interactive }
            let background = backgroundCount < maximumBackground ? waiters.firstIndex { $0.priority == .background } : nil
            // Foreground work gets prompt access; a background waiter still
            // gets a turn after three foreground grants rather than starving.
            guard let index = foregroundGrants >= 3 ? (background ?? foreground) : (foreground ?? background) else { return }
            let next = waiters.remove(at: index); active[next.id] = next.priority
            if next.priority == .interactive { foregroundGrants += 1 } else { foregroundGrants = 0 }
            next.continuation.resume(returning: next.id)
        }
    }
}
