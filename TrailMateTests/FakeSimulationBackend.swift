import Foundation
@testable import TrailMate

// A controllable device backend for session-level tests: accepts every command,
// counts start()/stop() calls, and lets a test publish one connection loss on
// demand — the trigger auto-reconnect recovers from.
nonisolated final class FakeSimulationBackend: SimulationBackend, @unchecked Sendable {
    let events: AsyncStream<SimulationBackendEvent>
    private let continuation: AsyncStream<SimulationBackendEvent>.Continuation
    private let lock = NSLock()
    private var startCalls = 0
    private var stopCalls = 0
    private var quietLocations: [(Double, Double)] = []

    init() {
        var c: AsyncStream<SimulationBackendEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
    }

    var startCount: Int { lock.withLock { startCalls } }
    var stopCount: Int { lock.withLock { stopCalls } }
    var quietLocationCount: Int { lock.withLock { quietLocations.count } }

    func start(rsdAddress: String, rsdPort: String) async throws {
        lock.withLock { startCalls += 1 }
    }

    func stop() async {
        lock.withLock { stopCalls += 1 }
        continuation.finish()
    }

    @discardableResult
    func sendCommand(_ command: String) async throws -> String { "OK" }

    nonisolated func setLocationQuiet(latitude: Double, longitude: Double) {
        lock.withLock { quietLocations.append((latitude, longitude)) }
    }

    // Publish the single loss event a live backend would report.
    func fail(_ failure: SimulationBackendFailure) {
        continuation.yield(.connectionLost(failure))
    }
}
