import CoreLocation
import Foundation
import Testing
@testable import TrailMate

// Epic 037 — the telemetry/bridge cadence split. Unlike the other actor tests
// (deterministic, no aggregator), this one drives the real 10 Hz loop for a
// short window because the split lives entirely in the per-tick push path.
//
// Property under test: during playback the telemetry stream flows at the
// aggregator cadence (10 Hz), decoupled from the structural bridge push, which
// stays throttled to 2 Hz. Before the split, telemetry was dual-published on the
// same 2 Hz throttle, so a ~1 s playback window would have surfaced ~2 frames;
// the split raises that to ~10. A comfortable lower bound keeps it robust to
// scheduler jitter while still failing on the pre-split behavior.
@MainActor
struct SimulationActorCadenceTests {

    private final class Counter { var value = 0 }

    private static func freshDefaults() -> UserDefaults {
        let suiteName = "com.sh.TrailMateTests.Cadence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func telemetryFlowsAtLoopCadenceDuringPlaybackWhileBridgeStaysThrottled() async throws {
        let bridge = SimulationStateBridge(defaults: Self.freshDefaults())
        let sim = SimulationActor(bridge: bridge, recorder: RecorderService())

        // A long route at a slow speed so playback runs for the whole sample
        // window without completing (≈ 2.2 km at 5 m/s ≈ 440 s).
        let start = CLLocationCoordinate2D(latitude: 25.0, longitude: 121.0)
        let end = CLLocationCoordinate2D(latitude: 25.02, longitude: 121.0)
        await sim.loadRoute(coordinates: [start, end], baseSpeed: 5, resetStart: true)

        let stream = await sim.telemetryStream()
        await sim.startEngine()
        await sim.play(multiplier: 1)

        // Sole consumer of the single-consumer stream, counting frames delivered
        // over a ~1 s window of playback.
        let counter = Counter()
        let consumer = Task { @MainActor in
            for await _ in stream {
                counter.value += 1
                if counter.value >= 100 { break }
            }
        }

        try await Task.sleep(for: .milliseconds(1000))
        consumer.cancel()
        await sim.stopEngine()

        // 10 Hz over ~1 s clears the old 2 Hz playback-telemetry ceiling by a wide
        // margin; ≥ 5 tolerates scheduler jitter and never passes on 2 Hz.
        #expect(counter.value >= 5)
    }
}
