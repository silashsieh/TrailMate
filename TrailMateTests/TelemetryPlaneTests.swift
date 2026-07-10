import CoreLocation
import Foundation
import Observation
import Testing
@testable import TrailMate

// Epic 041/037 — the telemetry plane. Properties the substrate must hold, all
// checkable at the seam without a device:
//   1. the per-actor telemetry stream is latest-wins (a slow consumer reads the
//      freshest frame, never a backlog),
//   2. the stream is RENEWABLE — a cancelled/re-created consumer (window close →
//      reopen) can resubscribe and frames flow again (a stored stream would be
//      dead after the first cancel),
//   3. the bridge's snapshot apply is change-guarded (re-applying an identical
//      snapshot fires no Observation),
//   4. DeviceSession.routeVersion bumps exactly once per route assignment.
@MainActor
struct TelemetryPlaneTests {

    // Each test gets its own UserDefaults suite so an app-hosted run never
    // persists a fake red dot into the owner's real defaults (the bridge's
    // position persistence writes through this).
    private static func freshDefaults() -> UserDefaults {
        let suiteName = "com.sh.TrailMateTests.Telemetry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    // MARK: - Latest-wins stream

    // bufferingNewest(1): frames produced while no one is reading collapse to the
    // most recent, so a consumer that wakes late gets the current position, not a
    // stale queue it has to drain. Three teleports before the first read must
    // surface only the third.
    @Test func telemetryStreamKeepsOnlyNewestForSlowConsumer() async {
        let bridge = SimulationStateBridge(defaults: Self.freshDefaults())
        let sim = SimulationActor(bridge: bridge, recorder: RecorderService())
        let stream = await sim.telemetryStream()

        // Produce three frames without draining the iterator (the slow consumer).
        await sim.teleport(to: CLLocationCoordinate2D(latitude: 10, longitude: 10))
        await sim.teleport(to: CLLocationCoordinate2D(latitude: 20, longitude: 20))
        await sim.teleport(to: CLLocationCoordinate2D(latitude: 30, longitude: 30))

        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        #expect(first?.coordinate?.latitude == 30)
        #expect(first?.coordinate?.longitude == 30)
    }

    // The stream carries the route-relative derivatives too, sourced from the
    // same snapshot as the bridge push so the two planes never disagree.
    @Test func telemetryFrameCarriesPositionAndRecordingCount() async {
        let bridge = SimulationStateBridge(defaults: Self.freshDefaults())
        let sim = SimulationActor(bridge: bridge, recorder: RecorderService())
        let stream = await sim.telemetryStream()

        let dot = CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654)
        await sim.teleport(to: dot)

        var iterator = stream.makeAsyncIterator()
        let frame = await iterator.next()
        #expect(frame != nil)
        #expect(frame?.coordinate?.latitude == 25.0330)
        #expect(frame?.recordingPointCount == 0)
        #expect(frame?.routeDeviationMeters == 0)
    }

    // MARK: - Renewable subscription (window close → reopen)

    // The stored-stream trap this replaced: an app-lifetime AsyncStream dies once
    // its lone consumer is cancelled, so a later iterator reads nil forever. The
    // factory hands out a fresh stream each call and seeds the newest frame, so a
    // re-subscriber renders immediately and keeps receiving.
    @Test func telemetryStreamIsRenewableAcrossResubscribe() async {
        let bridge = SimulationStateBridge(defaults: Self.freshDefaults())
        let sim = SimulationActor(bridge: bridge, recorder: RecorderService())

        await sim.teleport(to: CLLocationCoordinate2D(latitude: 10, longitude: 10))
        // First subscription — seeded with the current (10,10) frame.
        let stream1 = await sim.telemetryStream()
        var it1 = stream1.makeAsyncIterator()
        #expect(await it1.next()?.coordinate?.latitude == 10)

        // Consumer stops (window close): drop the iterator. Resubscribe (reopen):
        // a fresh, seeded stream must flow — a dead stored stream would give nil.
        await sim.teleport(to: CLLocationCoordinate2D(latitude: 20, longitude: 20))
        let stream2 = await sim.telemetryStream()
        var it2 = stream2.makeAsyncIterator()
        #expect(await it2.next()?.coordinate?.latitude == 20)

        // …and it keeps flowing: a subsequent teleport lands on the new stream.
        await sim.teleport(to: CLLocationCoordinate2D(latitude: 30, longitude: 30))
        #expect(await it2.next()?.coordinate?.latitude == 30)
    }

    // MARK: - Change-guarded bridge writes

    // Re-applying a byte-identical snapshot must not mutate any observed
    // property, so Observation fires nothing — this is the whole point of the
    // guards (idle 1 Hz jitter re-pushes the same dot; it must not fan out).
    @Test func identicalSnapshotFiresNoObservation() async {
        let bridge = SimulationStateBridge(defaults: Self.freshDefaults())
        let snap = Self.sampleSnapshot()
        bridge.apply(snap)   // establish state == snap

        await confirmation("identical apply fires no observation", expectedCount: 0) { confirm in
            withObservationTracking {
                Self.readAllObservedFields(bridge)
            } onChange: {
                confirm()
            }
            bridge.apply(snap)   // identical → every field guard skips its write
        }
    }

    // Control: a snapshot that differs in even one field must fire Observation,
    // proving the guards don't wall off legitimate updates.
    @Test func changedSnapshotFiresObservation() async {
        let bridge = SimulationStateBridge(defaults: Self.freshDefaults())
        let snap = Self.sampleSnapshot()
        bridge.apply(snap)

        await confirmation("changed apply fires observation", expectedCount: 1) { confirm in
            withObservationTracking {
                Self.readAllObservedFields(bridge)
            } onChange: {
                confirm()
            }
            var changed = snap
            changed.navigationProgress = snap.navigationProgress + 0.25
            bridge.apply(changed)
        }
    }

    // The coordinate guard compares lat/lon (CLLocationCoordinate2D isn't
    // Equatable): a moved dot must fire even when every scalar field is unchanged.
    @Test func changedCoordinateAloneFiresObservation() async {
        let bridge = SimulationStateBridge(defaults: Self.freshDefaults())
        let snap = Self.sampleSnapshot()
        bridge.apply(snap)

        await confirmation("moved coordinate fires observation", expectedCount: 1) { confirm in
            withObservationTracking {
                _ = bridge.simulatedCoordinate
            } onChange: {
                confirm()
            }
            var moved = snap
            moved.simulatedCoordinate = CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)
            bridge.apply(moved)
        }
    }

    // MARK: - routeVersion

    // Every assignment to routeCoordinates bumps routeVersion exactly once; a
    // mutating append bumps it too; a plain read does not.
    @Test func routeVersionBumpsOncePerAssignment() {
        let suiteName = "com.sh.TrailMateTests.Telemetry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        SimulatedPositionPersistence.setRestoreOnLaunch(false, in: defaults)

        let app = AppState(defaults: defaults)
        let session = app.sessions[0]
        let base = session.routeVersion   // initializer default assignment doesn't fire didSet

        session.routeCoordinates = [
            CLLocationCoordinate2D(latitude: 1, longitude: 1),
            CLLocationCoordinate2D(latitude: 2, longitude: 2)
        ]
        #expect(session.routeVersion == base + 1)

        // A second assignment (reroute / GPX import / drawn route) bumps again.
        session.routeCoordinates = [CLLocationCoordinate2D(latitude: 3, longitude: 3)]
        #expect(session.routeVersion == base + 2)

        // A mutating append (the appendDirectly path) is a get-modify-set, so it
        // fires didSet too.
        session.routeCoordinates.append(CLLocationCoordinate2D(latitude: 4, longitude: 4))
        #expect(session.routeVersion == base + 3)

        // Reading the route must not bump.
        _ = session.routeCoordinates
        _ = session.routeCoordinates.count
        #expect(session.routeVersion == base + 3)
    }

    // AppState's forwarding setter routes through the session property, so a
    // route mutation via the manager bumps the same counter.
    @Test func routeVersionBumpsViaForwardingSetter() {
        let suiteName = "com.sh.TrailMateTests.Telemetry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        SimulatedPositionPersistence.setRestoreOnLaunch(false, in: defaults)

        let app = AppState(defaults: defaults)
        let session = app.sessions[0]
        let base = session.routeVersion

        app.routeCoordinates = [
            CLLocationCoordinate2D(latitude: 5, longitude: 5),
            CLLocationCoordinate2D(latitude: 6, longitude: 6)
        ]
        #expect(session.routeVersion == base + 1)
    }

    // MARK: - Fixtures

    private static func sampleSnapshot() -> SimSnapshot {
        SimSnapshot(
            simulatedCoordinate: CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654),
            navigationPlaybackState: .playing,
            navigationProgress: 0.4,
            navigationElapsedDistance: 120,
            navigationTotalDistance: 300,
            navigationCompletedLoops: 1,
            joystickIsActive: false,
            joystickControllerName: "Controller",
            routeDeviationMeters: 3.5,
            recordingPointCount: 7,
            isRecording: true
        )
    }

    private static func readAllObservedFields(_ bridge: SimulationStateBridge) {
        _ = bridge.simulatedCoordinate
        _ = bridge.navigationPlaybackState
        _ = bridge.navigationProgress
        _ = bridge.navigationElapsedDistance
        _ = bridge.navigationTotalDistance
        _ = bridge.navigationCompletedLoops
        _ = bridge.joystickIsActive
        _ = bridge.joystickControllerName
        _ = bridge.routeDeviationMeters
        _ = bridge.recordingPointCount
        _ = bridge.isRecording
    }
}
