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
}
