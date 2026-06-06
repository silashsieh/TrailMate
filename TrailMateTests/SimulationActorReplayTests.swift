import CoreLocation
import Foundation
import Testing
@testable import TrailMate

// Records every emitted coordinate; no device, no process.
private final class RecordingBackend: SimulationBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [CLLocationCoordinate2D] = []

    var coordinates: [CLLocationCoordinate2D] {
        lock.withLock { recorded }
    }

    func start(rsdAddress: String, rsdPort: String) async throws {}
    func stop() async {}
    @discardableResult
    func sendCommand(_ command: String) async throws -> String { "OK" }
    nonisolated func setLocationQuiet(latitude: Double, longitude: Double) {
        lock.withLock {
            recorded.append(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        }
    }
    var events: AsyncStream<SimulationBackendEvent> {
        AsyncStream { _ in }
    }
}

// Engine-level loop tests can't see the integrator, which owns the on-screen
// position — this exercises the actor seam those tests miss.
struct SimulationActorReplayTests {
    // Regression: after a route ran to completion the integrator stayed parked
    // at the far end, so a second Play re-armed the engine at distance 0 but
    // drove the marker along a route-shaped ghost path offset from the
    // polyline. Play from idle must teleport the integrator back to A.
    @MainActor
    @Test func manualReplayRestartsFromRouteStart() async throws {
        let bridge = SimulationStateBridge()
        let recorder = RecorderService()
        let sim = SimulationActor(bridge: bridge, recorder: recorder)
        let backend = RecordingBackend()

        let start = CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654)
        let end = CLLocationCoordinate2D(latitude: 25.0330 + 100.0 / 111_320.0, longitude: 121.5654)

        await sim.updateNoiseSigma(0)
        await sim.attach(backend: backend)
        // ~100 m at 50 m/s — completes in ~2 s of real aggregator ticks.
        await sim.loadRoute(coordinates: [start, end], baseSpeed: 50, resetStart: true)
        await sim.play(multiplier: 1)
        try await Task.sleep(for: .seconds(3))
        #expect(await sim.isPlaybackIdle)

        let countBefore = backend.coordinates.count
        await sim.play(multiplier: 1)
        try await Task.sleep(for: .milliseconds(600))

        // Within the first ~0.6 s of the replay the marker can only be near A
        // (≤ ~30 m in). A ghost path from B would keep every emission ≥ ~70 m
        // away; a raced idle-jitter emission at B doesn't qualify either.
        let startLoc = CLLocation(latitude: start.latitude, longitude: start.longitude)
        let replayEmissions = backend.coordinates.dropFirst(countBefore)
        let nearStart = replayEmissions.contains { coord in
            CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                .distance(from: startLoc) < 40
        }
        #expect(!replayEmissions.isEmpty)
        #expect(nearStart)

        await sim.detach()
    }
}
