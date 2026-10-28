import CoreLocation
import Foundation
import Testing
@testable import TrailMate

// Epic 033 (WP8): the simulation loop's idle, cadence, deviation, and abort
// contracts at the actor seam. Every test drives SimulationActor's aggregator
// and idle-jitter loops with ManualMonotonicClock — the same MonotonicTimeSource
// the live actor runs on (ContinuousClock-backed in production) — so a
// 10-second abort window costs no wall-clock time. Device emits are observed
// on a recording backend, or while disconnected through the recording capture
// (emit() is the one chokepoint that appends to it). UI display pushes are
// observed through the actor's snapshot-observer seam, synchronously on the
// actor, so counts are exact rather than "eventually".
@MainActor
struct SimulationLoopTests {

    // MARK: - Disconnected vs connected idle

    // With no backend attached an idle session must stay perfectly still: no
    // 1 Hz re-emit (it would only drift the displayed/persisted dot for no one,
    // and pad an active recording with duplicate points) and no snapshot churn.
    @Test func disconnectedIdleSuppressesEmitsAndSnapshotChurn() async throws {
        try await withHarness { h in
            await h.sim.startRecording()
            let dot = CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654)
            await h.sim.teleport(to: dot)
            #expect(await h.sim.recordingStatus() == .init(isActive: true, pointCount: 1))
            h.snapshots.reset()

            // 50 aggregator ticks and 5 idle-jitter ticks.
            await h.advance(by: .seconds(5))

            #expect(await h.sim.recordingStatus() == .init(isActive: true, pointCount: 1))
            #expect(h.snapshots.pushes.isEmpty)
            let position = try #require(await h.sim.integratorPosition)
            #expect(Self.distanceMeters(position, from: dot) < 0.001)
        }
    }

    // Mirroring a device, the same idle session re-emits its dot once per second
    // (fresh noisy points keep flowing to the device) and still pushes no
    // snapshots — the aggregator has nothing to report while nothing moves.
    @Test func connectedIdleReEmitsOncePerSecondWithoutSnapshotChurn() async throws {
        try await withHarness { h in
            let dot = CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654)
            await h.sim.teleport(to: dot)
            let backend = EmitRecordingBackend(clock: h.clock)
            await h.sim.attach(backend: backend)
            #expect(backend.emits.count == 1)   // mirror-on-connect (epic 028)
            backend.reset()
            h.snapshots.reset()

            await h.advance(by: .seconds(5))

            let emits = backend.emits
            #expect(emits.map(\.at) == (1...5).map { Duration.seconds($0) })
            for emit in emits {
                // σ = 0, so each re-emit is the clean dot itself.
                #expect(abs(emit.latitude - dot.latitude) < 1e-12)
                #expect(abs(emit.longitude - dot.longitude) < 1e-12)
            }
            #expect(h.snapshots.pushes.isEmpty)

            // Detaching returns to the silent offline behavior on the same dot.
            await h.sim.detach()
            backend.reset()
            h.snapshots.reset()
            await h.advance(by: .seconds(3))
            #expect(backend.emits.isEmpty)
            #expect(h.snapshots.pushes.isEmpty)
        }
    }

    // MARK: - Display push caps

    // Run the loop at 50 Hz with the production snapshot intervals: every tick
    // still reaches the device, but the UI sees at most one push per 100 ms.
    // At the production 10 Hz loop the cap is invisible, so this is the only
    // configuration that actually exercises it.
    @Test func activeJoystickDisplayPushesCapAtTenHertzWhileEveryTickReachesTheDevice() async throws {
        let timing = SimulationTiming(
            aggregatorDeltaTime: 0.02,
            aggregatorInterval: .milliseconds(20),
            scrubEmitInterval: .milliseconds(20),
            playbackSnapshotInterval: SimulationTiming.production.playbackSnapshotInterval,
            activeSnapshotInterval: SimulationTiming.production.activeSnapshotInterval
        )
        try await withHarness(timing: timing) { h in
            let dot = CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654)
            await h.sim.teleport(to: dot)
            let backend = EmitRecordingBackend(clock: h.clock)
            await h.sim.attach(backend: backend)
            await h.sim.startJoystick(baseSpeed: 10)
            await h.sim.updateStickInput(x: 1, y: 0)
            backend.reset()
            h.snapshots.reset()

            await h.advance(by: .seconds(2), step: .milliseconds(20))

            #expect(backend.emits.count == 100)
            let pushes = h.snapshots.pushes
            #expect(pushes.map(\.at) == (1...20).map { Duration.milliseconds(100 * $0) })
            #expect(pushes.allSatisfy { $0.snapshot.joystickIsActive })
            #expect(pushes.allSatisfy { $0.snapshot.navigationPlaybackState == .idle })
            #expect(pushes.allSatisfy { $0.snapshot.routeDeviationMeters == 0 })
            // 2 s due east at 10 m/s.
            let last = try #require(backend.emits.last)
            #expect(abs(Self.eastMeters(of: last.coordinate, from: dot) - 20) < 0.05)
            #expect(abs(Self.northMeters(of: last.coordinate, from: dot)) < 0.001)
        }
    }

    // The cap must not starve the production loop: at 10 Hz every joystick tick
    // both reaches the device and updates the display.
    @Test func productionJoystickCadencePushesEveryTick() async throws {
        try await withHarness { h in
            let dot = CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654)
            await h.sim.teleport(to: dot)
            let backend = EmitRecordingBackend(clock: h.clock)
            await h.sim.attach(backend: backend)
            await h.sim.startJoystick(baseSpeed: 10)
            await h.sim.updateStickInput(x: 0, y: 1)
            backend.reset()
            h.snapshots.reset()

            await h.advance(by: .seconds(3))

            let ticks = (1...30).map { Duration.milliseconds(100 * $0) }
            #expect(backend.emits.map(\.at) == ticks)
            #expect(h.snapshots.pushes.map(\.at) == ticks)
        }
    }

    // Route playback keeps MapArea from rebuilding the polyline faster than
    // 2 Hz: consecutive display pushes are at least 500 ms apart while every
    // tick still streams to the device.
    @Test func playbackDisplayPushesCapAtTwoHertzWhileEveryTickReachesTheDevice() async throws {
        try await withHarness { h in
            let origin = CLLocationCoordinate2D(latitude: 25.0, longitude: 121.5)
            await h.sim.loadRoute(coordinates: Self.northRoute(from: origin, meters: 5_000), baseSpeed: 10, resetStart: true)
            let backend = EmitRecordingBackend(clock: h.clock)
            await h.sim.attach(backend: backend)
            await h.sim.play(multiplier: 1)
            backend.reset()
            h.snapshots.reset()

            await h.advance(by: .seconds(10))

            #expect(backend.emits.map(\.at) == (1...100).map { Duration.milliseconds(100 * $0) })
            let pushes = h.snapshots.pushes
            let gaps = zip(pushes.dropFirst(), pushes).map { $0.at - $1.at }
            #expect(gaps.allSatisfy { $0 >= .milliseconds(500) })
            #expect(pushes.count <= 20)
            #expect(pushes.count >= 10)   // capped, not starved
            #expect(pushes.allSatisfy { $0.snapshot.navigationPlaybackState == .playing })
            #expect(pushes.allSatisfy { $0.snapshot.routeDeviationMeters < 0.01 })
            let lastPush = try #require(pushes.last)
            #expect(abs(lastPush.snapshot.navigationElapsedDistance - lastPush.at.asSeconds * 10) < 0.01)
            // 10 s along the route at 10 m/s.
            let last = try #require(backend.emits.last)
            #expect(abs(Self.northMeters(of: last.coordinate, from: origin) - 100) < 0.05)
        }
    }

    // MARK: - Deviation

    // Composite control: the joystick drags the dot due east off a northbound
    // route. Rejoin snaps it back to the route's expected position, the next
    // deviation check reads on-route, and the 10 s abort window restarts — a
    // second excursion that pushes the cumulative off-route time past 10 s
    // must not abort, while a full fresh window after it does.
    @Test func rejoinSnapsBackToTheRouteAndRestartsTheAbortWindow() async throws {
        try await withHarness { h in
            let origin = CLLocationCoordinate2D(latitude: 25.0, longitude: 121.5)
            let route = Self.northRoute(from: origin, meters: 5_000)
            await h.sim.loadRoute(coordinates: route, baseSpeed: 1, resetStart: true)
            let backend = EmitRecordingBackend(clock: h.clock)
            await h.sim.attach(backend: backend)
            await h.sim.play(multiplier: 1)
            await h.sim.startJoystick(baseSpeed: 100)
            await h.sim.updateStickInput(x: 1, y: 0)

            // Off-route (>200 m) from ~2.1 s; by 9 s the window has run ~7 s.
            await h.advance(by: .seconds(9))
            let beforeRejoin = try #require(h.snapshots.pushes.last)
            #expect(beforeRejoin.snapshot.routeDeviationMeters > 200)
            #expect(h.events.events.isEmpty)
            let idleBeforeRejoin = await h.sim.isPlaybackIdle
            #expect(!idleBeforeRejoin)

            await h.sim.updateStickInput(x: 0, y: 0)
            backend.reset()
            await h.sim.rejoinRoute()

            // Rejoin emits the route's expected position — 9 s at 1 m/s up the
            // route — immediately, without waiting for a tick.
            let rejoined = try #require(backend.emits.last)
            #expect(rejoined.at == .seconds(9))
            #expect(abs(Self.eastMeters(of: rejoined.coordinate, from: origin)) < 0.01)
            let expected = Self.pointAlong(route, meters: 9)
            #expect(Self.distanceMeters(rejoined.coordinate, from: expected) < 0.01)
            let integrator = try #require(await h.sim.integratorPosition)
            #expect(Self.distanceMeters(integrator, from: rejoined.coordinate) < 0.001)

            // The next deviation checks read on-route.
            h.snapshots.reset()
            await h.advance(by: .seconds(1))
            let afterRejoin = h.snapshots.pushes
            #expect(!afterRejoin.isEmpty)
            #expect(afterRejoin.allSatisfy { $0.snapshot.routeDeviationMeters < 0.01 })

            // Second excursion: >200 m again from ~12.1 s. By 19 s the two
            // excursions total ~14 s off-route, yet only ~7 s since the reset.
            await h.sim.updateStickInput(x: 1, y: 0)
            await h.advance(by: .seconds(9))
            let secondExcursion = try #require(h.snapshots.pushes.last)
            #expect(secondExcursion.snapshot.routeDeviationMeters > 200)
            #expect(h.events.events.isEmpty)
            let idleAfterSecondExcursion = await h.sim.isPlaybackIdle
            #expect(!idleAfterSecondExcursion)

            // ...and the restarted window does expire on its own schedule.
            await h.advance(by: .seconds(4))
            #expect(await h.waitForEvents(count: 1))
            #expect(await h.sim.isPlaybackIdle)
        }
    }

    // More than 200 m off-route for more than 10 s aborts the route exactly
    // once: playback stops, one routeAborted event carries the thresholds, and
    // the still-armed joystick keeps driving the dot without a second abort.
    @Test func sustainedDeviationAbortsTheRouteOnceAndStopsPlayback() async throws {
        try await withHarness { h in
            let origin = CLLocationCoordinate2D(latitude: 25.0, longitude: 121.5)
            await h.sim.loadRoute(coordinates: Self.northRoute(from: origin, meters: 5_000), baseSpeed: 1, resetStart: true)
            let backend = EmitRecordingBackend(clock: h.clock)
            await h.sim.attach(backend: backend)
            await h.sim.play(multiplier: 1)
            await h.sim.startJoystick(baseSpeed: 100)
            await h.sim.updateStickInput(x: 1, y: 0)

            // 10 m/tick east crosses 200 m between 2.0 s and 2.2 s, whichever
            // 5 Hz check sees it first. Exactly 10 s later is not yet "more
            // than 10 s".
            await h.advance(by: .seconds(12))
            #expect(h.events.events.isEmpty)
            let idleAtTenSeconds = await h.sim.isPlaybackIdle
            #expect(!idleAtTenSeconds)

            await h.advance(by: .milliseconds(500))
            #expect(await h.waitForEvents(count: 1))
            if case .routeAborted(let meters, let seconds)? = h.events.events.first {
                #expect(meters == 200)
                #expect(seconds == 10)
            } else {
                Issue.record("expected one routeAborted event, got \(h.events.events)")
            }
            #expect(await h.sim.isPlaybackIdle)
            #expect(await h.sim.isJoystickActive)
            let abortPush = try #require(h.snapshots.pushes.last { $0.snapshot.navigationPlaybackState == .idle })
            #expect(abortPush.at <= .milliseconds(12_500))

            // The abort is one-shot: the joystick keeps streaming and no further
            // event or playback change follows.
            let emitsAtAbort = backend.emits.count
            h.snapshots.reset()
            await h.advance(by: .seconds(5))
            #expect(h.events.events.count == 1)
            #expect(await h.sim.isPlaybackIdle)
            #expect(backend.emits.count == emitsAtAbort + 50)
            let pushes = h.snapshots.pushes
            #expect(pushes.count == 50)   // joystick-only motion at the 10 Hz cap
            #expect(pushes.allSatisfy { $0.snapshot.navigationPlaybackState == .idle })
            #expect(pushes.allSatisfy { $0.snapshot.routeDeviationMeters == 0 })
            #expect(pushes.allSatisfy { $0.snapshot.joystickIsActive })
        }
    }

    // MARK: - Harness

    // Records every hot-path push to the "device" with the manual-clock time it
    // arrived. Lock-guarded like DaemonBridge's serial queue, so it's safe to
    // read from the test's MainActor while the actor writes.
    nonisolated final class EmitRecordingBackend: SimulationBackend, @unchecked Sendable {
        struct Emit {
            let at: Duration
            let latitude: Double
            let longitude: Double
            var coordinate: CLLocationCoordinate2D {
                CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            }
        }

        private let lock = NSLock()
        private let clock: ManualMonotonicClock
        private var _emits: [Emit] = []

        let events: AsyncStream<SimulationBackendEvent>
        private let continuation: AsyncStream<SimulationBackendEvent>.Continuation

        init(clock: ManualMonotonicClock) {
            self.clock = clock
            var c: AsyncStream<SimulationBackendEvent>.Continuation!
            events = AsyncStream { c = $0 }
            continuation = c
        }

        var emits: [Emit] { lock.withLock { _emits } }
        func reset() { lock.withLock { _emits.removeAll() } }

        func start(rsdAddress: String, rsdPort: String) async throws {}
        func stop() async { continuation.finish() }
        @discardableResult func sendCommand(_ command: String) async throws -> String { "OK" }
        nonisolated func setLocationQuiet(latitude: Double, longitude: Double) {
            let at = clock.now
            lock.withLock { _emits.append(Emit(at: at, latitude: latitude, longitude: longitude)) }
        }
    }

    // Every snapshot the actor pushed, throttled or not, with its clock time.
    nonisolated final class SnapshotRecorder: @unchecked Sendable {
        struct Push {
            let at: Duration
            let snapshot: SimSnapshot
        }

        private let lock = NSLock()
        private var _pushes: [Push] = []

        var pushes: [Push] { lock.withLock { _pushes } }
        func reset() { lock.withLock { _pushes.removeAll() } }
        func record(_ snapshot: SimSnapshot, at instant: Duration) {
            lock.withLock { _pushes.append(Push(at: instant, snapshot: snapshot)) }
        }
    }

    nonisolated final class EventRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [SimulationEvent] = []

        var events: [SimulationEvent] { lock.withLock { _events } }
        func append(_ event: SimulationEvent) { lock.withLock { _events.append(event) } }
    }

    @MainActor
    final class Harness {
        let runtime: IsolatedTestRuntime
        let clock: ManualMonotonicClock
        let bridge: SimulationStateBridge
        let snapshots: SnapshotRecorder
        let events: EventRecorder
        let sim: SimulationActor
        private let eventDrain: Task<Void, Never>
        private let step: Duration

        // Two loops park on the clock between ticks: the aggregator and the
        // idle jitter.
        private static let loopCount = 2

        init(timing: SimulationTiming) throws {
            runtime = try IsolatedTestRuntime()
            let clock = ManualMonotonicClock()
            let snapshots = SnapshotRecorder()
            let events = EventRecorder()
            self.clock = clock
            self.snapshots = snapshots
            self.events = events
            step = timing.aggregatorInterval
            bridge = SimulationStateBridge(defaults: runtime.defaults)
            sim = SimulationActor(
                bridge: bridge,
                monotonicTime: clock.timeSource,
                timing: timing,
                snapshotObserver: { snapshot in snapshots.record(snapshot, at: clock.now) }
            )
            let stream = sim.events
            eventDrain = Task { for await event in stream { events.append(event) } }
        }

        // Starts the loops and waits until both are parked on the manual clock.
        // Noise σ is pinned to 0 so emitted coordinates equal the clean ones.
        func start() async {
            await sim.updateNoiseSigma(0)
            await sim.startEngine()
            let parked = await settle()
            #expect(parked, "loops did not park on the manual clock")
        }

        func finish() async {
            await sim.stopEngine()
            eventDrain.cancel()
            runtime.cleanup()
        }

        // Advances the clock one loop interval at a time (never past a tick
        // deadline), yielding after each step until every woken loop has run
        // its tick and re-armed its sleep — the "expected state has consumed
        // the advancement" barrier the release plan requires.
        func advance(by total: Duration, step: Duration? = nil) async {
            let step = step ?? self.step
            var remaining = total
            while remaining > .zero {
                let increment = min(step, remaining)
                clock.advance(by: increment)
                remaining -= increment
                guard await settle() else {
                    Issue.record("loops did not consume a \(increment) advance at \(clock.now)")
                    return
                }
            }
        }

        // After advance() the woken loop's sleeper is gone until its tick
        // finishes and it re-arms, so "all loops pending" means the tick ran.
        func settle() async -> Bool {
            let deadline = ContinuousClock.now + .seconds(5)
            var spins = 0
            while clock.pendingSleepCount != Self.loopCount {
                if ContinuousClock.now > deadline { return false }
                spins += 1
                if spins % 100 == 0 {
                    try? await Task.sleep(for: .milliseconds(1))
                } else {
                    await Task.yield()
                }
            }
            return true
        }

        // Events cross an AsyncStream to the drain task, so give it a moment.
        func waitForEvents(count: Int) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(5)
            while events.events.count < count {
                if ContinuousClock.now > deadline { return false }
                await Task.yield()
            }
            return true
        }
    }

    private func withHarness(
        timing: SimulationTiming = .production,
        _ body: @MainActor (Harness) async throws -> Void
    ) async throws {
        let harness = try Harness(timing: timing)
        await harness.start()
        do {
            try await body(harness)
        } catch {
            await harness.finish()
            throw error
        }
        await harness.finish()
    }

    // MARK: - Geometry

    private static let metersPerDegLat = 111_320.0

    // A straight northbound route: deviation from it is exactly the east offset.
    private static func northRoute(from origin: CLLocationCoordinate2D, meters: Double) -> [CLLocationCoordinate2D] {
        [origin, CLLocationCoordinate2D(latitude: origin.latitude + meters / metersPerDegLat, longitude: origin.longitude)]
    }

    // The engine measures arc length geodesically (CLLocation.distance), so the
    // point `meters` along a two-vertex route is that fraction of the geodesic
    // length, not of the flat-projected one — 0.5% apart at 25°N.
    private static func pointAlong(_ route: [CLLocationCoordinate2D], meters: Double) -> CLLocationCoordinate2D {
        let fraction = meters / distanceMeters(route[1], from: route[0])
        return CLLocationCoordinate2D(
            latitude: route[0].latitude + (route[1].latitude - route[0].latitude) * fraction,
            longitude: route[0].longitude + (route[1].longitude - route[0].longitude) * fraction
        )
    }

    private static func northMeters(of coordinate: CLLocationCoordinate2D, from origin: CLLocationCoordinate2D) -> Double {
        (coordinate.latitude - origin.latitude) * metersPerDegLat
    }

    private static func eastMeters(of coordinate: CLLocationCoordinate2D, from origin: CLLocationCoordinate2D) -> Double {
        (coordinate.longitude - origin.longitude) * metersPerDegLat * cos(origin.latitude * .pi / 180)
    }

    private static func distanceMeters(_ coordinate: CLLocationCoordinate2D, from origin: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            .distance(from: CLLocation(latitude: origin.latitude, longitude: origin.longitude))
    }
}

private extension Duration {
    var asSeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
