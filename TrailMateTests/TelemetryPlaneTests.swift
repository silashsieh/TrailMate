import CoreLocation
import Foundation
import Observation
import Testing
@testable import TrailMate

// Epic 041 — the telemetry plane. Three properties the substrate must hold, all
// checkable at the seam without a device:
//   1. the per-actor telemetry stream is latest-wins (a slow consumer reads the
//      freshest frame, never a backlog),
//   2. the bridge's snapshot apply is change-guarded (re-applying an identical
//      snapshot fires no Observation, so idle same-value pushes don't fan out),
//   3. DeviceSession.routeVersion bumps exactly once per route assignment.
@MainActor
struct TelemetryPlaneTests {

    // MARK: - Latest-wins stream

    // bufferingNewest(1): frames produced while no one is reading collapse to the
    // most recent, so a consumer that wakes late gets the current position, not a
    // stale queue it has to drain. Three teleports before the first read must
    // surface only the third.
    @Test func telemetryStreamKeepsOnlyNewestForSlowConsumer() async {
        let bridge = SimulationStateBridge()
        let sim = SimulationActor(bridge: bridge, recorder: RecorderService())
        let stream = sim.telemetry

        // Produce three frames with no iterator attached yet (the slow consumer).
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
        let bridge = SimulationStateBridge()
        let sim = SimulationActor(bridge: bridge, recorder: RecorderService())
        let stream = sim.telemetry

        let dot = CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654)
        await sim.teleport(to: dot)

        var iterator = stream.makeAsyncIterator()
        let frame = await iterator.next()
        #expect(frame != nil)
        #expect(frame?.coordinate?.latitude == 25.0330)
        #expect(frame?.recordingPointCount == 0)
        #expect(frame?.routeDeviationMeters == 0)
    }

    // MARK: - Change-guarded bridge writes

    // Re-applying a byte-identical snapshot must not mutate any observed
    // property, so Observation fires nothing — this is the whole point of the
    // guards (idle 1 Hz jitter re-pushes the same dot; it must not fan out).
    @Test func identicalSnapshotFiresNoObservation() {
        let bridge = SimulationStateBridge()
        let snap = Self.sampleSnapshot()
        bridge.apply(snap)   // establish state == snap

        var fired = false
        withObservationTracking {
            Self.readAllObservedFields(bridge)
        } onChange: {
            fired = true
        }

        bridge.apply(snap)   // identical → every field guard skips its write
        #expect(fired == false)
    }

    // Control: a snapshot that differs in even one field must fire Observation,
    // proving the guards don't wall off legitimate updates.
    @Test func changedSnapshotFiresObservation() {
        let bridge = SimulationStateBridge()
        let snap = Self.sampleSnapshot()
        bridge.apply(snap)

        var fired = false
        withObservationTracking {
            Self.readAllObservedFields(bridge)
        } onChange: {
            fired = true
        }

        var changed = snap
        changed.navigationProgress = snap.navigationProgress + 0.25
        bridge.apply(changed)
        #expect(fired == true)
    }

    // The coordinate guard compares lat/lon (CLLocationCoordinate2D isn't
    // Equatable): a moved dot must fire even when every scalar field is unchanged.
    @Test func changedCoordinateAloneFiresObservation() {
        let bridge = SimulationStateBridge()
        let snap = Self.sampleSnapshot()
        bridge.apply(snap)

        var fired = false
        withObservationTracking {
            _ = bridge.simulatedCoordinate
        } onChange: {
            fired = true
        }

        var moved = snap
        moved.simulatedCoordinate = CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522)
        bridge.apply(moved)
        #expect(fired == true)
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
