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

    // Thread-safe frame log filled by a DETACHED consumer (off MainActor — the
    // test host runs suites in parallel and a starved MainActor consumer would
    // drop latest-wins frames). Assertions below are on SOURCE-derived motion
    // deltas, not wall-clock counts: scheduler load can only merge frames
    // (making deltas larger), never fabricate small ones, so the cap invariant
    // is load-proof.
    private final class FrameLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [Double] = []
        func append(_ v: Double) { lock.lock(); _values.append(v); lock.unlock() }
        var values: [Double] { lock.lock(); defer { lock.unlock() }; return _values }
    }

    private func positiveDeltas(_ values: [Double]) -> [Double] {
        zip(values.dropFirst(), values).map { $0 - $1 }.filter { $0 > 0.01 }
    }

    @Test func mapTelemetryIsCappedAtFiveHzAndDecoupledFromBridgeThrottle() async throws {
        let bridge = SimulationStateBridge(defaults: Self.freshDefaults())
        let sim = SimulationActor(bridge: bridge, recorder: RecorderService())

        // A long route at 5 m/s: each 100 ms tick advances 0.5 m, so
        // elapsedDistance is a tick counter in disguise. Frames published on
        // ADJACENT ticks differ by 0.5 m; the 5 Hz cap (every 2nd tick) makes
        // consecutive published frames differ by ≥ ~1.0 m; the old 2 Hz bridge
        // ride-along would differ by ~2.5 m.
        let start = CLLocationCoordinate2D(latitude: 25.0, longitude: 121.0)
        let end = CLLocationCoordinate2D(latitude: 25.02, longitude: 121.0)
        await sim.loadRoute(coordinates: [start, end], baseSpeed: 5, resetStart: true)

        let stream = await sim.telemetryStream()
        await sim.startEngine()
        await sim.play(multiplier: 1)

        let log = FrameLog()
        let consumer = Task.detached {
            for await frame in stream { log.append(frame.elapsedDistance) }
        }

        try await Task.sleep(for: .milliseconds(2000))
        consumer.cancel()
        await sim.stopEngine()

        let deltas = positiveDeltas(log.values)
        #expect(deltas.count >= 3, "telemetry not flowing: \(log.values.count) frames")
        if let minDelta = deltas.min() {
            // Cap lost → two adjacent ticks published → a 0.5 m delta appears.
            // Load only merges frames (larger deltas), so this cannot flake big.
            #expect(minDelta >= 0.9, "map-telemetry cap lost: min advance \(minDelta) m/frame")
            // Old 2 Hz ride-along → every delta ≈ 2.5 m; the cap's clean pairs
            // are ≈ 1.0 m, so at least one small delta proves the decoupling.
            #expect(minDelta <= 1.6, "telemetry still riding the 2 Hz bridge throttle: min advance \(minDelta) m/frame")
        }
    }

    // Review blocker (PR #69): a route short/fast enough to complete between
    // cadence ticks flips playing→idle inside nav.tick — with a leading-edge-only
    // throttle both the terminal coordinate and the idle transition were dropped
    // forever (no later tick retries). The transition must publish unthrottled.
    @Test func routeCompletionBetweenTicksPublishesTerminalCoordinateAndIdle() async throws {
        let bridge = SimulationStateBridge(defaults: Self.freshDefaults())
        let sim = SimulationActor(bridge: bridge, recorder: RecorderService())

        // ~3.3 m at 50 m/s: completes on the very first 100 ms tick, well inside
        // the 200 ms telemetry-cap window opened by play()'s transition push.
        let start = CLLocationCoordinate2D(latitude: 25.0, longitude: 121.0)
        let end = CLLocationCoordinate2D(latitude: 25.00003, longitude: 121.0)
        await sim.loadRoute(coordinates: [start, end], baseSpeed: 50, resetStart: true)

        let stream = await sim.telemetryStream()
        await sim.startEngine()

        final class Box { var last: TelemetryFrame? }
        let box = Box()
        let consumer = Task { @MainActor in
            for await frame in stream { box.last = frame }
        }

        await sim.play(multiplier: 1)
        try await Task.sleep(for: .milliseconds(800))
        consumer.cancel()
        await sim.stopEngine()

        #expect(bridge.navigationPlaybackState == .idle,
                "playing→idle transition was dropped by the throttle")
        let lastCoord = box.last?.coordinate
        let distanceToEnd = lastCoord.map {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        }
        #expect(distanceToEnd != nil && distanceToEnd! < 1.5,
                "terminal coordinate not published (last frame \(String(describing: lastCoord)))")
    }

    // The 5 Hz cap is PLAYBACK-only: joystick steering keeps the loop's 10 Hz
    // visual cadence (pre-migration parity; 200 ms steps would approach the
    // ~300 ms perceptibility line while hand-steering). At baseSpeed 10 each
    // tick moves 1.0 m, so a clean adjacent-tick pair of published frames is
    // ~1.0 m apart; a capped (every-2nd-tick) joystick would never produce a
    // consecutive-frame distance under ~2.0 m.
    @Test func joystickTelemetryKeepsLoopCadence() async throws {
        let bridge = SimulationStateBridge(defaults: Self.freshDefaults())
        let sim = SimulationActor(bridge: bridge, recorder: RecorderService())

        let stream = await sim.telemetryStream()
        await sim.startEngine()
        let origin = CLLocationCoordinate2D(latitude: 25.0, longitude: 121.0)
        await sim.teleport(to: origin)
        await sim.startJoystick(baseSpeed: 10)
        await sim.updateStickInput(x: 1, y: 0)

        let log = FrameLog()
        let consumer = Task.detached {
            for await frame in stream {
                guard let c = frame.coordinate else { continue }
                log.append(CLLocation(latitude: c.latitude, longitude: c.longitude)
                    .distance(from: CLLocation(latitude: origin.latitude, longitude: origin.longitude)))
            }
        }

        try await Task.sleep(for: .milliseconds(2000))
        consumer.cancel()
        await sim.stopEngine()

        let deltas = positiveDeltas(log.values)
        #expect(deltas.count >= 3, "telemetry not flowing: \(log.values.count) frames")
        if let minDelta = deltas.min() {
            #expect(minDelta <= 1.5,
                    "joystick telemetry appears capped below loop cadence: min step \(minDelta) m/frame")
        }
    }

    // High 2 (second review), observable end-to-end: pressing Play on a
    // degenerate (one-point) route must leave the PUBLISHED state idle. Before
    // the fix, play() entered .playing (published), tick() flipped back to
    // .idle internally, and nothing published the flip — the UI stayed stuck
    // on "playing" forever.
    @Test func playOnDegenerateRoutePublishesIdle() async throws {
        let bridge = SimulationStateBridge(defaults: Self.freshDefaults())
        let sim = SimulationActor(bridge: bridge, recorder: RecorderService())

        await sim.loadRoute(
            coordinates: [CLLocationCoordinate2D(latitude: 25.0, longitude: 121.0)],
            baseSpeed: 5, resetStart: true
        )
        await sim.startEngine()
        await sim.play(multiplier: 1)

        try await Task.sleep(for: .milliseconds(400))
        await sim.stopEngine()

        #expect(bridge.navigationPlaybackState == .idle,
                "degenerate route left the published state at \(bridge.navigationPlaybackState)")
    }
}
