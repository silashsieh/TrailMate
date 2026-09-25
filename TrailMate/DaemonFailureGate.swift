import Foundation

// Serializes failure publication across the actor-owned stdout/process paths
// and the nonisolated 10 Hz write path. First reason wins; intentional stop
// suppresses publication before it writes QUIT.
nonisolated final class DaemonFailureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isSuppressed = false
    private var didAcceptFailure = false

    func reset() {
        lock.lock()
        isSuppressed = false
        didAcceptFailure = false
        lock.unlock()
    }

    func suppress() {
        lock.lock()
        isSuppressed = true
        lock.unlock()
    }

    func accept(_: SimulationBackendFailure) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isSuppressed, !didAcceptFailure else { return false }
        didAcceptFailure = true
        return true
    }
}
