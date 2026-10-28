import CoreLocation
import Foundation
import Testing
@testable import TrailMate

// WP4 verifies the pipe/process event sources; WP5 verifies retry timing and
// cancellation. These cases cover the remaining handoff from each loss reason
// into the session state while another device is still connected.
@MainActor
struct DeviceSessionLossTests {
    @Test func eachBackendLossDropsOnlyItsSessionAndPreservesTheOtherDevice() async throws {
        let failures: [SimulationBackendFailure] = [
            .brokenPipe,
            .endOfFile,
            .unexpectedExit(status: 7, reason: .normal),
            .tunnelDown(line: "TUNNEL_DOWN")
        ]
        for failure in failures {
            let runtime = try IsolatedTestRuntime()
            let clock = ManualMonotonicClock()
            let simulationClock = ManualMonotonicClock()
            let attempter = FakeDeviceConnectionAttempter()
            SimulatedPositionPersistence.setRestoreOnLaunch(false, in: runtime.defaults)
            let app = AppState(
                defaults: runtime.defaults,
                runtimePaths: runtime.runtimePaths,
                monotonicTime: clock.timeSource,
                simulationMonotonicTime: simulationClock.timeSource,
                connectionAttempter: attempter
            )
            let a = app.selectedSession
            a.selectedDeviceUDID = "DEVICE-A"
            let backendA = FakeSimulationBackend()
            attempter.script(.succeed(backendA))
            await a.connect()
            app.addSession()
            let b = app.selectedSession
            b.selectedDeviceUDID = "DEVICE-B"
            let backendB = FakeSimulationBackend()
            attempter.script(.succeed(backendB))
            await b.connect()

            #expect(a.autoReconnectArmed)
            #expect(b.connectionStatus == .connected)
            backendA.fail(failure)
            #expect(await eventually { a.connectionStatus == .reconnecting(attempt: 1, maxAttempts: 10) })
            #expect(await eventually { backendA.stopCount == 1 })
            #expect(a.connectedUDID == nil)
            #expect(a.autoReconnectArmed)
            #expect(b.connectionStatus == .connected)
            #expect(b.connectedUDID == "DEVICE-B")
            #expect(backendB.stopCount == 0)
            #expect(app.selectedSessionID == b.id)
            #expect(app.connectionStatus == .connected)
            #expect(attempter.calls.map(\.udid) == ["DEVICE-A", "DEVICE-B"])
            #expect(app.logMessages.contains { $0.contains(failure.logMessage) })

            // A's pending retry can be cancelled without disturbing B.
            #expect(await eventually { clock.pendingSleepCount == 1 })
            a.cancelRetry()
            #expect(a.connectionStatus == .error(failure.statusMessage))
            clock.advance(by: .seconds(3_600))
            for _ in 0..<100 { await Task.yield() }
            #expect(attempter.calls.count == 2)
            #expect(b.connectionStatus == .connected)
            await b.sim.teleport(to: CLLocationCoordinate2D(latitude: 24, longitude: 120))
            #expect(await b.sim.integratorPosition?.latitude == 24)

            await app.prepareForQuit()
            runtime.cleanup()
        }
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<5_000 {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }
}
