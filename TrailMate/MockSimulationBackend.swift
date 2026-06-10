import Foundation

#if DEBUG
// The "record-only mock" backend the SimulationBackend doc anticipates:
// accepts every command and swallows location updates so connected-only UI
// flows can run with no device, tunnel, or daemon. Reached only via
// UITestSupport.mockConnection.
nonisolated final class MockSimulationBackend: SimulationBackend {
    let events: AsyncStream<SimulationBackendEvent>
    private let eventsContinuation: AsyncStream<SimulationBackendEvent>.Continuation

    init() {
        var continuation: AsyncStream<SimulationBackendEvent>.Continuation!
        events = AsyncStream { continuation = $0 }
        eventsContinuation = continuation
    }

    func start(rsdAddress: String, rsdPort: String) async throws {}

    func stop() async {
        eventsContinuation.finish()
    }

    @discardableResult
    func sendCommand(_ command: String) async throws -> String { "OK" }

    nonisolated func setLocationQuiet(latitude: Double, longitude: Double) {}
}
#endif
