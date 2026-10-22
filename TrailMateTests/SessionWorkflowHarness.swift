import Foundation
import CoreLocation
import MapKit
@testable import TrailMate

// Isolated AppState graph for session and offline workflow tests. The two
// clocks park connection delays and simulation ticks; no service sees the
// developer's defaults, route library, tunnel, socket, or device.
@MainActor
final class SessionWorkflowHarness {
    let runtime: IsolatedTestRuntime
    let connectionClock = ManualMonotonicClock()
    let simulationClock = ManualMonotonicClock()
    let attempter = FakeDeviceConnectionAttempter()
    let app: AppState

    init(
        router: (any RoutingService)? = nil,
        searchResultResolver: @escaping @MainActor (LocationSearch, MKLocalSearchCompletion) async -> CLLocationCoordinate2D? = { _, _ in nil },
        coordinateWriter: @escaping @MainActor (String) -> Void = { _ in }
    ) throws {
        runtime = try IsolatedTestRuntime()
        SimulatedPositionPersistence.setRestoreOnLaunch(false, in: runtime.defaults)
        app = AppState(
            defaults: runtime.defaults,
            runtimePaths: runtime.runtimePaths,
            monotonicTime: connectionClock.timeSource,
            simulationMonotonicTime: simulationClock.timeSource,
            connectionAttempter: attempter,
            router: router ?? FakeRoutingService(.degenerate),
            searchResultResolver: searchResultResolver,
            coordinateWriter: coordinateWriter
        )
    }

    func finish() async {
        await app.prepareForQuit()
        runtime.cleanup()
    }

    func eventually(_ predicate: @escaping @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if await predicate() { return true }
            await Task.yield()
        }
        return await predicate()
    }
}
