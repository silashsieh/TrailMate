import CoreLocation
import Foundation
import Testing
@testable import TrailMate

// Epic 043 acceptance: the auto-reconnect state machine driven by a manual
// clock and a scripted attempt seam. No tunnel, daemon, admin prompt, or
// real-time wait is involved — every "5 seconds" below is a clock advance, and
// every attempt settles when the test says so.
@MainActor
struct DeviceSessionReconnectTests {
    private static let maxAttempts = DeviceSession.autoReconnectMaxAttempts
    private static let delay = DeviceSession.autoReconnectDelay

    // MARK: - Harness

    @MainActor
    final class Harness {
        let runtime: IsolatedTestRuntime
        let clock = ManualMonotonicClock()
        let attempter = FakeDeviceConnectionAttempter()
        let app: AppState
        let a: DeviceSession

        init() throws {
            runtime = try IsolatedTestRuntime()
            SimulatedPositionPersistence.setRestoreOnLaunch(false, in: runtime.defaults)
            app = AppState(
                defaults: runtime.defaults,
                runtimePaths: runtime.runtimePaths,
                monotonicTime: clock.timeSource,
                connectionAttempter: attempter
            )
            a = app.selectedSession
            a.selectedDeviceUDID = "DEVICE-A"
        }

        // Explicit Connect through the real path (the one that arms recovery),
        // scripted to succeed on its first startup try.
        @discardableResult
        func connectExplicitly(_ session: DeviceSession? = nil) async -> FakeSimulationBackend {
            let target = session ?? a
            let backend = FakeSimulationBackend()
            attempter.script(.succeed(backend))
            await target.connect()
            return backend
        }

        // Wait until the recovery loop is parked on the manual clock, prove
        // nothing fires a millisecond early, then release exactly one
        // post-failure delay.
        func elapseDelay() async {
            let parked = await eventually { self.clock.pendingSleepCount == 1 }
            #expect(parked, "recovery loop should be waiting on the manual clock")
            let callsBefore = attempter.calls.count
            clock.advance(by: DeviceSessionReconnectTests.delay - .milliseconds(1))
            await settle()
            #expect(attempter.calls.count == callsBefore, "attempt must not start before the full delay")
            clock.advance(by: .milliseconds(1))
        }

        // Wait for the `count`th attempt overall to be in flight (the explicit
        // Connect is call 1, so recovery attempt n is call n + 1).
        func waitForAttempts(_ count: Int) async {
            let reached = await eventually {
                self.attempter.calls.count == count && self.attempter.inFlightCount == 1
            }
            #expect(reached, "expected call \(count) in flight; calls=\(attempter.calls.count) inFlight=\(attempter.inFlightCount)")
        }

        func waitForStatus(_ status: ConnectionStatus, of session: DeviceSession? = nil) async {
            let target = session ?? a
            let reached = await eventually { target.connectionStatus == status }
            #expect(reached, "expected \(status), got \(target.connectionStatus)")
        }

        // Prove that no retry is scheduled: an hour of clock time changes nothing.
        func expectNoFurtherAttempts() async {
            let callsBefore = attempter.calls.count
            let statusBefore = a.connectionStatus
            clock.advance(by: .seconds(3_600))
            await settle()
            #expect(attempter.calls.count == callsBefore)
            #expect(a.connectionStatus == statusBefore)
        }

        func finish() async {
            await app.prepareForQuit()
            runtime.cleanup()
        }
    }

    // MARK: - Drop → recovery

    @Test func armedDropReconnectsAfterFiveSecondsWithoutPromptOnTheSameActorAndCapture() async throws {
        let h = try Harness()
        let backend = await h.connectExplicitly()
        #expect(h.a.connectionStatus == .connected)
        #expect(h.a.autoReconnectArmed)
        #expect(h.attempter.calls == [.init(udid: "DEVICE-A", promptPolicy: .allowPrompt)])
        let actorBefore = h.a.sim
        await h.a.sim.startRecording()
        await h.a.sim.teleport(to: CLLocationCoordinate2D(latitude: 25, longitude: 121))

        backend.fail(.tunnelDown(line: "TUNNEL_DOWN"))
        await h.waitForStatus(.reconnecting(attempt: 1, maxAttempts: Self.maxAttempts))
        #expect(h.a.connectedUDID == nil)
        #expect(h.a.autoReconnectArmed)
        #expect(h.attempter.calls.count == 1, "no attempt before the post-failure delay")
        #expect(await eventually { backend.stopCount == 1 })

        await h.elapseDelay()
        await h.waitForAttempts(2)
        #expect(h.attempter.calls[1] == .init(udid: "DEVICE-A", promptPolicy: .neverPrompt))
        #expect(h.a.connectionStatus == .reconnecting(attempt: 1, maxAttempts: Self.maxAttempts))

        let replacement = FakeSimulationBackend()
        h.attempter.succeedInFlight(with: replacement)
        await h.waitForStatus(.connected)
        #expect(h.a.connectedUDID == "DEVICE-A")
        #expect(h.a.sim === actorBefore)
        #expect(await h.a.sim.recordingStatus() == .init(isActive: true, pointCount: 1))
        #expect(h.a.autoReconnectArmed, "a successful reconnect keeps the window armed")
        #expect(h.clock.pendingSleepCount == 0)
        // The log line lands after the commit's actor hops, so wait for it.
        #expect(await eventually { h.app.logMessages.contains { $0.contains("Reconnected on attempt 1/\(Self.maxAttempts)") } })

        // Quit still discards the retained capture without persisting it.
        await h.app.prepareForQuit()
        #expect(await h.a.sim.recordingStatus() == .init(isActive: false, pointCount: 0))
        #expect(h.app.recordingsLibrary.recordings.isEmpty)
        h.runtime.cleanup()
    }

    @Test func successOnAttemptNResetsTheCounterForTheNextDrop() async throws {
        let h = try Harness()
        let backend = await h.connectExplicitly()
        backend.fail(.brokenPipe)
        await h.waitForStatus(.reconnecting(attempt: 1, maxAttempts: Self.maxAttempts))

        for attempt in 1...2 {
            await h.elapseDelay()
            await h.waitForAttempts(attempt + 1)
            h.attempter.failInFlight()
            await h.waitForStatus(.reconnecting(attempt: attempt + 1, maxAttempts: Self.maxAttempts))
        }
        await h.elapseDelay()
        await h.waitForAttempts(4)
        let second = FakeSimulationBackend()
        h.attempter.succeedInFlight(with: second)
        await h.waitForStatus(.connected)
        #expect(await eventually { h.app.logMessages.contains { $0.contains("Reconnected on attempt 3/\(Self.maxAttempts)") } })

        // The next drop gets a fresh ten.
        second.fail(.tunnelDown(line: "TUNNEL_DOWN"))
        await h.waitForStatus(.reconnecting(attempt: 1, maxAttempts: Self.maxAttempts))
        await h.elapseDelay()
        await h.waitForAttempts(5)
        h.attempter.succeedInFlight(with: FakeSimulationBackend())
        await h.waitForStatus(.connected)
        await h.finish()
    }

    @Test func unreachableDeviceMakesExactlyTenNonOverlappingAttemptsThenSettles() async throws {
        let h = try Harness()
        let backend = await h.connectExplicitly()
        backend.fail(.unexpectedExit(status: 7, reason: .normal))
        await h.waitForStatus(.reconnecting(attempt: 1, maxAttempts: Self.maxAttempts))

        for attempt in 1...Self.maxAttempts {
            #expect(h.a.connectionStatus == .reconnecting(attempt: attempt, maxAttempts: Self.maxAttempts))
            #expect(h.attempter.inFlightCount == 0, "attempts never overlap: nothing runs during a delay")
            await h.elapseDelay()
            await h.waitForAttempts(attempt + 1)
            #expect(h.attempter.calls[attempt].promptPolicy == .neverPrompt)
            #expect(h.a.connectionStatus == .reconnecting(attempt: attempt, maxAttempts: Self.maxAttempts))
            // Attempt runtime is not part of the delay: no timer runs while an
            // attempt is in flight, so the next delay starts at its failure.
            #expect(h.clock.pendingSleepCount == 0)
            h.attempter.failInFlight(FakeDeviceConnectionAttempter.AttemptError(message: "attempt \(attempt) refused"))
            await settle()
        }

        // Attempt 10 settles straight into the ordinary disconnected state.
        await h.waitForStatus(.error("attempt \(Self.maxAttempts) refused"))
        #expect(h.clock.pendingSleepCount == 0, "no final delay")
        #expect(!h.a.autoReconnectArmed)
        await h.expectNoFurtherAttempts()
        #expect(h.attempter.calls.count == Self.maxAttempts + 1, "no eleventh attempt")
        #expect(h.app.logMessages.contains { $0.contains("gave up after \(Self.maxAttempts) attempts") })

        // Connect works out of it by hand and re-arms.
        await h.connectExplicitly()
        #expect(h.a.connectionStatus == .connected)
        #expect(h.a.autoReconnectArmed)
        await h.finish()
    }

    // MARK: - Explicit actions

    @Test func explicitDisconnectNeverReconnects() async throws {
        let h = try Harness()
        let backend = await h.connectExplicitly()
        await h.a.disconnect()
        #expect(h.a.connectionStatus == .disconnected)
        #expect(h.a.connectedUDID == nil)
        #expect(!h.a.autoReconnectArmed)
        #expect(backend.stopCount == 1)
        await h.expectNoFurtherAttempts()
        #expect(h.attempter.calls.count == 1)
        await h.finish()
    }

    @Test func unarmedLossStaysInTheManualState() async throws {
        // The test-only bind seam stands in for a session that never went
        // through an explicit Connect: a loss there is plain manual territory.
        let h = try Harness()
        let backend = FakeSimulationBackend()
        await h.a.bindConnectedForTesting(udid: "DEVICE-A", backend: backend)
        backend.fail(.tunnelDown(line: "TUNNEL_DOWN"))
        await h.waitForStatus(.error("Tunnel down"))
        #expect(h.clock.outstandingSleepCount == 0)
        await h.expectNoFurtherAttempts()
        #expect(h.attempter.calls.isEmpty)
        await h.finish()
    }

    @Test func policyOffReproducesManualBehaviorAndPersists() async throws {
        let h = try Harness()
        #expect(h.app.autoReconnectEnabled, "auto-reconnect is on by default")
        h.app.autoReconnectEnabled = false
        #expect(h.runtime.defaults.object(forKey: AppState.autoReconnectEnabledKey) != nil)
        #expect(!h.runtime.defaults.bool(forKey: AppState.autoReconnectEnabledKey))

        let backend = await h.connectExplicitly()
        #expect(h.a.autoReconnectArmed, "Connect still arms; the policy gates recovery")
        backend.fail(.tunnelDown(line: "TUNNEL_DOWN"))
        await h.waitForStatus(.error("Tunnel down"))
        #expect(h.clock.outstandingSleepCount == 0)
        await h.expectNoFurtherAttempts()
        #expect(h.attempter.calls.count == 1)

        // The persisted choice survives a fresh app graph.
        let reloaded = AppState(
            defaults: h.runtime.defaults,
            runtimePaths: h.runtime.runtimePaths,
            monotonicTime: h.clock.timeSource,
            connectionAttempter: h.attempter
        )
        #expect(!reloaded.autoReconnectEnabled)
        await reloaded.prepareForQuit()
        await h.finish()
    }

    // MARK: - Cancel retry

    @Test func cancelDuringDelaySettlesImmediatelyAndPreventsThePendingAttempt() async throws {
        let h = try Harness()
        let backend = await h.connectExplicitly()
        backend.fail(.tunnelDown(line: "TUNNEL_DOWN"))
        await h.waitForStatus(.reconnecting(attempt: 1, maxAttempts: Self.maxAttempts))
        #expect(await eventually { h.clock.pendingSleepCount == 1 })

        h.a.cancelRetry()
        // Settles synchronously: no Cancelling… phase during a delay.
        #expect(h.a.connectionStatus == .error("Tunnel down"))
        #expect(!h.a.autoReconnectArmed)
        #expect(await eventually { h.clock.outstandingSleepCount == 0 })
        await h.expectNoFurtherAttempts()
        #expect(h.attempter.calls.count == 1)
        #expect(h.app.logMessages.contains { $0.contains("Reconnect cancelled.") })

        // Nothing reconnects on its own until Connect, which re-arms.
        await h.connectExplicitly()
        #expect(h.a.connectionStatus == .connected)
        #expect(h.a.autoReconnectArmed)
        await h.finish()
    }

    @Test func cancelDuringInFlightAttemptShowsCancellingThenSettlesWithoutScheduling() async throws {
        let h = try Harness()
        let backend = await h.connectExplicitly()
        backend.fail(.tunnelDown(line: "TUNNEL_DOWN"))
        await h.waitForStatus(.reconnecting(attempt: 1, maxAttempts: Self.maxAttempts))
        await h.elapseDelay()
        await h.waitForAttempts(2)

        h.a.cancelRetry()
        #expect(h.a.connectionStatus == .cancellingRetry)
        #expect(h.a.connectionStatus.recoveryText == String(localized: "Cancelling…"))
        #expect(!h.a.autoReconnectArmed)
        #expect(h.attempter.inFlightCount == 1, "the running attempt is not force-killed")
        // A second press while winding down changes nothing.
        h.a.cancelRetry()
        #expect(h.a.connectionStatus == .cancellingRetry)

        h.attempter.failInFlight(FakeDeviceConnectionAttempter.AttemptError(message: "timed out"))
        await h.waitForStatus(.error("timed out"))
        #expect(h.clock.outstandingSleepCount == 0, "neither a delay nor another attempt is scheduled")
        await h.expectNoFurtherAttempts()
        #expect(h.attempter.calls.count == 2)
        await h.finish()
    }

    @Test func cancelledInFlightAttemptThatSucceedsConnectsButStaysDisarmed() async throws {
        let h = try Harness()
        let backend = await h.connectExplicitly()
        backend.fail(.tunnelDown(line: "TUNNEL_DOWN"))
        await h.waitForStatus(.reconnecting(attempt: 1, maxAttempts: Self.maxAttempts))
        await h.elapseDelay()
        await h.waitForAttempts(2)
        h.a.cancelRetry()
        #expect(h.a.connectionStatus == .cancellingRetry)

        let landed = FakeSimulationBackend()
        h.attempter.succeedInFlight(with: landed)
        await h.waitForStatus(.connected)
        #expect(h.a.connectedUDID == "DEVICE-A")
        #expect(!h.a.autoReconnectArmed, "Cancel was a deliberate disarm")
        #expect(await eventually { h.app.logMessages.contains { $0.contains("retry was cancelled") } })

        // The next loss is manual territory until an explicit Connect.
        landed.fail(.tunnelDown(line: "TUNNEL_DOWN"))
        await h.waitForStatus(.error("Tunnel down"))
        await h.expectNoFurtherAttempts()
        #expect(h.attempter.calls.count == 2)
        await h.finish()
    }

    // MARK: - No prompt

    @Test func recoveryThatWouldNeedAuthorizationSettlesWithoutPrompting() async throws {
        let h = try Harness()
        let backend = await h.connectExplicitly()
        backend.fail(.tunnelDown(line: "TUNNEL_DOWN"))
        await h.waitForStatus(.reconnecting(attempt: 1, maxAttempts: Self.maxAttempts))
        await h.elapseDelay()
        await h.waitForAttempts(2)

        h.attempter.failInFlight(ConnectionAttemptFailure.authorizationRequired)
        await h.waitForStatus(.error("Authentication required"))
        #expect(h.attempter.calls.dropFirst().allSatisfy { $0.promptPolicy == .neverPrompt })
        #expect(h.clock.outstandingSleepCount == 0)
        #expect(!h.a.autoReconnectArmed)
        await h.expectNoFurtherAttempts()
        #expect(h.attempter.calls.count == 2, "authorization ends the window; it is not one of ten")
        #expect(h.app.logMessages.contains { $0.contains("press Connect to authorize") })
        await h.finish()
    }

    // MARK: - Sleep / wake

    @Test func sleepThenWakeRunsTheSamePolicyWithTheSameControls() async throws {
        let h = try Harness()
        let backend = await h.connectExplicitly()
        await h.a.sim.startRecording()

        await h.a.handleSystemSleep()
        #expect(h.a.connectionStatus == .disconnected)
        #expect(h.a.connectedUDID == nil)
        #expect(backend.stopCount == 1)
        #expect(h.a.autoReconnectArmed, "sleep is not an explicit Disconnect")
        #expect(h.attempter.calls.count == 1)

        h.a.handleSystemWake()
        #expect(h.a.connectionStatus == .reconnecting(attempt: 1, maxAttempts: Self.maxAttempts))
        await h.elapseDelay()
        await h.waitForAttempts(2)
        #expect(h.attempter.calls[1] == .init(udid: "DEVICE-A", promptPolicy: .neverPrompt))
        h.attempter.failInFlight()
        await h.waitForStatus(.reconnecting(attempt: 2, maxAttempts: Self.maxAttempts))

        // Same Cancel retry, same settle; the capture survived sleep and wake.
        h.a.cancelRetry()
        #expect(h.a.connectionStatus == .error("device unreachable"))
        #expect(await h.a.sim.recordingStatus().isActive)
        await h.expectNoFurtherAttempts()
        await h.finish()
    }

    @Test func wakeDoesNothingWithoutAnArmedSessionOrWithThePolicyOff() async throws {
        let h = try Harness()
        // Never connected: wake is a no-op.
        h.a.handleSystemWake()
        #expect(h.a.connectionStatus == .disconnected)

        // Policy off: sleep disconnects like today and wake stays put.
        h.app.autoReconnectEnabled = false
        await h.connectExplicitly()
        await h.a.handleSystemSleep()
        h.a.handleSystemWake()
        #expect(h.a.connectionStatus == .disconnected)
        await h.expectNoFurtherAttempts()
        #expect(h.attempter.calls.count == 1)

        // Explicit Disconnect before sleep: wake must not reconnect either.
        h.app.autoReconnectEnabled = true
        await h.connectExplicitly()
        await h.a.disconnect()
        await h.a.handleSystemSleep()
        h.a.handleSystemWake()
        #expect(h.a.connectionStatus == .disconnected)
        await h.expectNoFurtherAttempts()
        #expect(h.attempter.calls.count == 2)
        await h.finish()
    }

    @Test func sleepDuringRecoveryStartsAFreshWindowOnWakeAndDiscardsTheStaleAttempt() async throws {
        let h = try Harness()
        let backend = await h.connectExplicitly()
        backend.fail(.tunnelDown(line: "TUNNEL_DOWN"))
        await h.waitForStatus(.reconnecting(attempt: 1, maxAttempts: Self.maxAttempts))
        await h.elapseDelay()
        await h.waitForAttempts(2)
        h.attempter.failInFlight()
        await h.waitForStatus(.reconnecting(attempt: 2, maxAttempts: Self.maxAttempts))
        await h.elapseDelay()
        await h.waitForAttempts(3)   // attempt 2 in flight

        await h.a.handleSystemSleep()
        #expect(h.a.connectionStatus == .disconnected)
        #expect(h.attempter.inFlightCount == 1, "an in-flight attempt is never cancelled")
        #expect(h.a.autoReconnectArmed)

        h.a.handleSystemWake()
        #expect(h.a.connectionStatus == .reconnecting(attempt: 1, maxAttempts: Self.maxAttempts), "wake starts a fresh ten")

        // The stale attempt lands a backend after its window was abandoned: it
        // is stopped, never committed, and the fresh window is unaffected.
        let stale = FakeSimulationBackend()
        h.attempter.succeedInFlight(with: stale)
        #expect(await eventually { stale.stopCount == 1 })
        #expect(h.a.connectionStatus == .reconnecting(attempt: 1, maxAttempts: Self.maxAttempts))
        #expect(h.a.connectedUDID == nil)

        await h.elapseDelay()
        await h.waitForAttempts(4)
        h.attempter.succeedInFlight(with: FakeSimulationBackend())
        await h.waitForStatus(.connected)
        await h.finish()
    }

    // MARK: - Per-session isolation

    @Test func retryStateIsSessionScopedAndSelectionDoesNotLeakOrMutateIt() async throws {
        let h = try Harness()
        let a = h.a
        let backendA = await h.connectExplicitly(a)
        h.app.addSession()
        let b = h.app.selectedSession
        b.selectedDeviceUDID = "DEVICE-B"
        let backendB = await h.connectExplicitly(b)
        #expect(h.attempter.calls.map(\.udid) == ["DEVICE-A", "DEVICE-B"])

        backendA.fail(.tunnelDown(line: "TUNNEL_DOWN"))
        await h.waitForStatus(.reconnecting(attempt: 1, maxAttempts: Self.maxAttempts), of: a)
        #expect(b.connectionStatus == .connected)
        #expect(b.connectedUDID == "DEVICE-B")

        // B is selected: the control surface shows B, not A's retry.
        #expect(h.app.selectedSessionID == b.id)
        #expect(h.app.connectionStatus == .connected)
        h.app.selectedSessionID = a.id
        #expect(h.app.connectionStatus == .reconnecting(attempt: 1, maxAttempts: Self.maxAttempts))
        h.app.selectedSessionID = b.id
        #expect(a.connectionStatus == .reconnecting(attempt: 1, maxAttempts: Self.maxAttempts), "selecting B does not mutate A's retry")

        await h.elapseDelay()
        await h.waitForAttempts(3)
        #expect(h.attempter.calls[2].udid == "DEVICE-A", "only the dropped session retries")

        // Cancelling A through the manager touches A alone.
        h.app.selectedSessionID = a.id
        h.app.cancelRetry()
        #expect(a.connectionStatus == .cancellingRetry)
        #expect(b.connectionStatus == .connected)
        h.attempter.failInFlight()
        await h.waitForStatus(.error("device unreachable"), of: a)
        #expect(b.connectionStatus == .connected)
        #expect(b.autoReconnectArmed)
        #expect(backendB.stopCount == 0)
        await h.finish()
    }

    @Test func sessionRemovalAbandonsRecoveryAndDiscardsItsRecording() async throws {
        let h = try Harness()
        h.app.addSession()
        let b = h.app.selectedSession
        b.selectedDeviceUDID = "DEVICE-B"
        let backend = await h.connectExplicitly(b)
        await b.sim.startRecording()
        backend.fail(.tunnelDown(line: "TUNNEL_DOWN"))
        await h.waitForStatus(.reconnecting(attempt: 1, maxAttempts: Self.maxAttempts), of: b)
        #expect(await eventually { h.clock.pendingSleepCount == 1 })

        h.app.removeSession(b)
        #expect(await eventually { b.connectionStatus == .disconnected })
        #expect(await eventually { h.clock.outstandingSleepCount == 0 })
        #expect(await eventuallyAsync { await !b.sim.recordingStatus().isActive })
        h.clock.advance(by: .seconds(3_600))
        await settle()
        #expect(h.attempter.calls.count == 1)
        #expect(h.app.recordingsLibrary.recordings.isEmpty)
        await h.finish()
    }

    // MARK: - Explicit Connect keeps its startup policy

    @Test func explicitConnectRetriesOnlyDaemonStartOnTheSharedClockAndMayPrompt() async throws {
        let h = try Harness()
        let backend = FakeSimulationBackend()
        h.attempter.script(
            .fail(ConnectionAttemptFailure.daemonStartFailed(
                underlying: FakeDeviceConnectionAttempter.AttemptError(message: "no READY")
            )),
            .succeed(backend)
        )
        let connect = Task { await h.a.connect() }
        // The startup retry pause runs on the shared clock, not real time.
        #expect(await eventually { h.clock.pendingSleepCount == 1 })
        #expect(h.a.connectionStatus == .connecting)
        h.clock.advance(by: .seconds(3))
        await connect.value
        #expect(h.a.connectionStatus == .connected)
        #expect(h.attempter.calls.count == 2)
        #expect(h.attempter.calls.allSatisfy { $0.promptPolicy == .allowPrompt })
        #expect(h.a.autoReconnectArmed)

        // A tunnel-level failure is not transient: no startup retry, not armed.
        await h.a.disconnect()
        h.attempter.script(.fail(ConnectionAttemptFailure.tunnelUnavailable(underlying: TunnelError.authCancelled)))
        await h.a.connect()
        #expect(h.a.connectionStatus == .error("Authentication required"))
        #expect(h.attempter.calls.count == 3)
        #expect(!h.a.autoReconnectArmed)
        #expect(h.clock.outstandingSleepCount == 0)
        await h.finish()
    }

    // MARK: - Projection

    @Test func recoveryStatesProjectTheAttemptForEverySurface() {
        let reconnecting = ConnectionStatus.reconnecting(attempt: 3, maxAttempts: 10)
        #expect(reconnecting.isRecovering)
        #expect(reconnecting.recoveryText?.contains("3/10") == true)
        #expect(ConnectionStatus.cancellingRetry.isRecovering)
        #expect(ConnectionStatus.cancellingRetry.recoveryText == String(localized: "Cancelling…"))
        for plain in [ConnectionStatus.disconnected, .connecting, .connected, .error("x")] {
            #expect(!plain.isRecovering)
            #expect(plain.recoveryText == nil)
        }
        #expect(!reconnecting.isConnected)
    }
}

// MARK: - Yield helpers (no real-time waits on the success path)

@MainActor
private func settle() async {
    for _ in 0..<100 { await Task.yield() }
}

@MainActor
private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
    for i in 0..<3_000 {
        if predicate() { return true }
        if i < 500 {
            await Task.yield()
        } else {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
    return predicate()
}

@MainActor
private func eventuallyAsync(_ predicate: @MainActor () async -> Bool) async -> Bool {
    for i in 0..<3_000 {
        if await predicate() { return true }
        if i < 500 {
            await Task.yield()
        } else {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }
    return await predicate()
}
