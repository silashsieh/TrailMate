import CoreLocation
import Foundation
import Testing
@testable import TrailMate

// Epic 037 — the telemetry/bridge cadence split AND the map-telemetry cap.
// Unlike the other actor tests (deterministic, no aggregator), this one drives
// the real loop for a short window because both properties live in the
// per-tick push path.
//
// Properties under test, during playback:
//  1. Telemetry flows from the tick path, decoupled from the 2 Hz structural
//     bridge throttle (pre-split, telemetry rode the same 2 Hz throttle).
//  2. Telemetry is CAPPED at `mapTelemetryInterval` (5 Hz in production) — the
//     2026-07-11 Release A/B showed every frame forces a MapKit render pass:
//     uncapped 10 Hz cost 21–22% CPU during playback (worse than the 15%
//     pre-migration map); capped 5 Hz cost 14.8/13.6% (better than every
//     pre-migration figure). The upper bound below fails if the cap is lost.
@MainActor
struct SimulationActorCadenceTests {

    private final class Counter { var value = 0 }

    private static func freshDefaults() -> UserDefaults {
        let suiteName = "com.sh.TrailMateTests.Cadence.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func mapTelemetryIsCappedAtFiveHzAndDecoupledFromBridgeThrottle() async throws {
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
        // over a ~2 s window of playback.
        let counter = Counter()
        let consumer = Task { @MainActor in
            for await _ in stream {
                counter.value += 1
                if counter.value >= 100 { break }
            }
        }

        try await Task.sleep(for: .milliseconds(2000))
        consumer.cancel()
        await sim.stopEngine()

        // 5 Hz over ~2 s ≈ 10 frames, plus the subscription seed and the play()
        // transition push. Lower bound: the old 2 Hz playback ceiling would give
        // ~4+2 ≈ 6 — require clearly more. Upper bound: an uncapped 10 Hz loop
        // would give ~20+2 — require clearly fewer, so losing the cap fails.
        #expect(counter.value >= 8, "cadence too low: \(counter.value) frames in 2 s")
        #expect(counter.value <= 15, "map-telemetry cap lost: \(counter.value) frames in 2 s")
    }
}
