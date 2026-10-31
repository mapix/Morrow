import Foundation
import Dispatch
import Darwin

public enum IndexSystemMemoryPressure: String, Codable, Sendable {
    case normal, warning, critical
}

/// Decisions are independent of RSS: reusable malloc pages and clean library
/// mappings can raise RSS even while the OS still has sufficient memory.
public enum IndexMemoryPolicy {
    public static func shouldPause(pressure: IndexSystemMemoryPressure, activeGPUBytes: Int, workingBudget: Int, processFootprint: UInt64, processBudget: UInt64? = nil) -> Bool {
        pressure != .normal || activeGPUBytes > workingBudget || processBudget.map { processFootprint >= $0 } == true
    }
}

final class IndexMemoryPressureMonitor: @unchecked Sendable {
    static let shared = IndexMemoryPressureMonitor()
    private let lock = NSLock()
    private var pressure: IndexSystemMemoryPressure = .normal
    private let source: DispatchSourceMemoryPressure
    private init() {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: DispatchQueue(label: "app.morrow.index-memory-pressure"))
        pressure = Self.readSystemPressure() ?? .normal
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = self.source.data
            let value: IndexSystemMemoryPressure = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
            self.lock.lock(); self.pressure = value; self.lock.unlock()
        }
        source.resume()
    }
    private static func readSystemPressure() -> IndexSystemMemoryPressure? {
        var value: Int32 = 0, size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else { return nil }
        return value >= 4 ? .critical : value >= 2 ? .warning : .normal
    }
    var current: IndexSystemMemoryPressure {
        // The initial warning may predate source registration. The macOS
        // kernel level supplies the current state; iOS uses source events.
        if let current = Self.readSystemPressure() { return current }
        lock.lock(); defer { lock.unlock() }; return pressure
    }
}
