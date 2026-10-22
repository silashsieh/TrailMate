import Foundation
@testable import TrailMate

// A controllable device backend for session-level tests: accepts every command,
// counts start()/stop() calls, lets a test publish one connection loss on demand
// (the trigger auto-reconnect recovers from), and offers two deterministic
// interleaving hooks for lifecycle-race tests — a parkable stop() and a gate on
// the first mirrored emit, which is the only synchronous point inside the
// actor's attach that a test can hold.
nonisolated final class FakeSimulationBackend: SimulationBackend, @unchecked Sendable {
    let events: AsyncStream<SimulationBackendEvent>
    private let continuation: AsyncStream<SimulationBackendEvent>.Continuation
    private let lock = NSLock()
    private var startCalls = 0
    private var stopCalls = 0
    private var quietLocations: [(Double, Double)] = []
    private var sentCommands: [String] = []

    private var holdingStops = false
    private var heldStops: [CheckedContinuation<Void, Never>] = []

    private var gateNextQuietLocation = false
    private var blockedInQuietLocation = false
    private let quietLocationRelease = DispatchSemaphore(value: 0)

    init() {
        var c: AsyncStream<SimulationBackendEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .unbounded) { c = $0 }
        continuation = c
    }

    var startCount: Int { lock.withLock { startCalls } }
    var stopCount: Int { lock.withLock { stopCalls } }
    var quietLocationCount: Int { lock.withLock { quietLocations.count } }
    var lastQuietLocation: (latitude: Double, longitude: Double)? { lock.withLock { quietLocations.last } }
    var locations: [(Double, Double)] { lock.withLock { quietLocations } }
    var commands: [String] { lock.withLock { sentCommands } }

    func start(rsdAddress: String, rsdPort: String) async throws {
        lock.withLock { startCalls += 1 }
    }

    // Counts on entry; parks until releaseHeldStops() while holdStops() is on,
    // standing in for a daemon whose QUIT/EXIT handshake is still in progress.
    func stop() async {
        lock.withLock { stopCalls += 1 }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let parked: Bool = lock.withLock {
                guard holdingStops else { return false }
                heldStops.append(c)
                return true
            }
            if !parked { c.resume() }
        }
        continuation.finish()
    }

    @discardableResult
    func sendCommand(_ command: String) async throws -> String {
        lock.withLock { sentCommands.append(command) }
        return "OK"
    }

    // Synchronous, as on the hot path. With blockNextQuietLocation() armed, the
    // first call blocks the calling actor thread until releaseQuietLocation():
    // attach() emits the current red dot synchronously, so this parks a commit
    // with the mirror wired but nothing published yet.
    nonisolated func setLocationQuiet(latitude: Double, longitude: Double) {
        let shouldBlock: Bool = lock.withLock {
            quietLocations.append((latitude, longitude))
            guard gateNextQuietLocation else { return false }
            gateNextQuietLocation = false
            blockedInQuietLocation = true
            return true
        }
        if shouldBlock { quietLocationRelease.wait() }
    }

    // Publish the single loss event a live backend would report.
    func fail(_ failure: SimulationBackendFailure) {
        continuation.yield(.connectionLost(failure))
    }

    // MARK: - Interleaving hooks

    func holdStops() {
        lock.withLock { holdingStops = true }
    }

    func releaseHeldStops() {
        let waiting: [CheckedContinuation<Void, Never>] = lock.withLock {
            holdingStops = false
            let w = heldStops
            heldStops = []
            return w
        }
        waiting.forEach { $0.resume() }
    }

    func blockNextQuietLocation() {
        lock.withLock { gateNextQuietLocation = true }
    }

    var isBlockedInQuietLocation: Bool {
        lock.withLock { blockedInQuietLocation }
    }

    func releaseQuietLocation() {
        let wasBlocked: Bool = lock.withLock {
            gateNextQuietLocation = false
            let b = blockedInQuietLocation
            blockedInQuietLocation = false
            return b
        }
        if wasBlocked { quietLocationRelease.signal() }
    }
}
