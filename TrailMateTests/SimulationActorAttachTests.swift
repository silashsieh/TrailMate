import CoreLocation
import Dispatch
import Testing
@testable import TrailMate

// Epic 028: connecting a device must immediately mirror the current red dot to
// it — "the device follows the red dot on connect", whether the dot came from a
// launch restore or from offline control. The UI/mock path can't observe this
// (MockSimulationBackend deliberately swallows locations), so it's exercised
// here at the actor seam with a backend that records the hot-path push.
struct SimulationActorAttachTests {

    // Records the last coordinate pushed through the nonisolated, hot-path
    // setLocationQuiet — guarded by the same serial-queue pattern DaemonBridge
    // uses for that call, so it's safe to read from the test's MainActor.
    final class RecordingBackend: SimulationBackend {
        private let queue = DispatchQueue(label: "test.recording-backend")
        nonisolated(unsafe) private var _last: (lat: Double, lon: Double)?
        var lastLocation: (lat: Double, lon: Double)? { queue.sync { _last } }

        let events: AsyncStream<SimulationBackendEvent>
        private let continuation: AsyncStream<SimulationBackendEvent>.Continuation
        init() {
            var c: AsyncStream<SimulationBackendEvent>.Continuation!
            events = AsyncStream { c = $0 }
            continuation = c
        }
        func start(rsdAddress: String, rsdPort: String) async throws {}
        func stop() async { continuation.finish() }
        @discardableResult func sendCommand(_ command: String) async throws -> String { "OK" }
        nonisolated func setLocationQuiet(latitude: Double, longitude: Double) {
            queue.sync { _last = (latitude, longitude) }
        }
    }

    @MainActor
    @Test func attachMirrorsCurrentRedDotToDevice() async throws {
        let bridge = SimulationStateBridge()
        let recorder = RecorderService()
        let sim = SimulationActor(bridge: bridge, recorder: recorder)
        // Zero noise so the emitted value equals the clean coordinate exactly
        // (see LocationNoiseTests.zeroSigmaIsIdentity).
        await sim.updateNoiseSigma(0)

        // Drive the red dot with NO backend attached — offline control (028).
        let dot = CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654)
        await sim.teleport(to: dot)

        // Connecting attaches a backend; attach() must push the current dot to
        // it immediately, without waiting for the next tick.
        let backend = RecordingBackend()
        await sim.attach(backend: backend)

        let received = backend.lastLocation
        #expect(received != nil)
        if let received {
            #expect(abs(received.lat - dot.latitude) < 1e-9)
            #expect(abs(received.lon - dot.longitude) < 1e-9)
        }
    }

    // Detaching keeps the red dot put and controllable; re-attaching must
    // re-mirror wherever the dot ended up while offline (epic 028's "reconnect
    // re-syncs the device").
    @MainActor
    @Test func reattachAfterOfflineMoveMirrorsTheNewDot() async throws {
        let bridge = SimulationStateBridge()
        let sim = SimulationActor(bridge: bridge, recorder: RecorderService())
        await sim.updateNoiseSigma(0)

        await sim.teleport(to: CLLocationCoordinate2D(latitude: 25.0, longitude: 121.0))
        let backend = RecordingBackend()
        await sim.attach(backend: backend)
        await sim.detach()

        // Move the dot while disconnected, then reconnect.
        let moved = CLLocationCoordinate2D(latitude: 40.7128, longitude: -74.0060)
        await sim.teleport(to: moved)
        let reconnected = RecordingBackend()
        await sim.attach(backend: reconnected)

        let received = reconnected.lastLocation
        #expect(received != nil)
        if let received {
            #expect(abs(received.lat - moved.latitude) < 1e-9)
            #expect(abs(received.lon - moved.longitude) < 1e-9)
        }
    }

    @Test func productionTimingUsesTenHzActiveCadence() {
        #expect(SimulationTiming.production.aggregatorDeltaTime == 0.1)
        #expect(SimulationTiming.production.aggregatorInterval == .milliseconds(100))
        #expect(SimulationTiming.production.scrubEmitInterval == .milliseconds(100))
        #expect(SimulationTiming.production.activeSnapshotInterval == .milliseconds(100))
        #expect(SimulationTiming.production.playbackSnapshotInterval == .milliseconds(500))
    }

    @MainActor
    @Test func nonPlayingSnapshotThrottleDoesNotThrottleDeviceEmits() async throws {
        let bridge = SimulationStateBridge()
        let timing = SimulationTiming(
            aggregatorDeltaTime: 0.02,
            aggregatorInterval: .milliseconds(20),
            scrubEmitInterval: .milliseconds(20),
            playbackSnapshotInterval: .milliseconds(500),
            activeSnapshotInterval: .milliseconds(250)
        )
        let sim = SimulationActor(bridge: bridge, recorder: RecorderService(), timing: timing)
        let backend = RecordingBackend()
        await sim.updateNoiseSigma(0)

        let start = CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654)
        await sim.teleport(to: start)
        await sim.attach(backend: backend)
        await sim.startEngine()
        await sim.startJoystick(baseSpeed: 50)

        let initialApplied = await waitUntil {
            Self.distanceMeters(bridge.simulatedCoordinate, from: start) < 0.01
        }
        #expect(initialApplied)

        await sim.updateStickInput(x: 1, y: 0)

        let deviceMovedBeforeUIPush = await waitUntil(timeout: .milliseconds(120)) {
            Self.distanceMeters(backend.lastLocation, from: start) > 0.5
        }
        #expect(deviceMovedBeforeUIPush)
        #expect(Self.distanceMeters(bridge.simulatedCoordinate, from: start) < 0.01)

        let uiEventuallyMoved = await waitUntil(timeout: .milliseconds(500)) {
            Self.distanceMeters(bridge.simulatedCoordinate, from: start) > 0.5
        }
        #expect(uiEventuallyMoved)

        await sim.stopEngine()
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .milliseconds(500),
        _ predicate: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    private static func distanceMeters(
        _ coordinate: CLLocationCoordinate2D?,
        from origin: CLLocationCoordinate2D
    ) -> Double {
        guard let coordinate else { return .infinity }
        return CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            .distance(from: CLLocation(latitude: origin.latitude, longitude: origin.longitude))
    }

    private static func distanceMeters(
        _ coordinate: (lat: Double, lon: Double)?,
        from origin: CLLocationCoordinate2D
    ) -> Double {
        guard let coordinate else { return .infinity }
        return CLLocation(latitude: coordinate.lat, longitude: coordinate.lon)
            .distance(from: CLLocation(latitude: origin.latitude, longitude: origin.longitude))
    }
}
