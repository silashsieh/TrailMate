import CoreLocation
import Foundation
import Testing
@testable import TrailMate

// Every fixture owns temporary files, a unique defaults suite, a parked clock,
// fake discovery rows, and fake backends. Dispatch never reaches a live device.
@MainActor
struct CommandDispatchTests {
    private let a = "DEVICE-A"
    private let b = "DEVICE-B"
    private let c = "DEVICE-C"

    private func fixture() throws -> (IsolatedTestRuntime, AppState, FakeDeviceConnectionAttempter) {
        let runtime = try IsolatedTestRuntime()
        SimulatedPositionPersistence.setRestoreOnLaunch(false, in: runtime.defaults)
        let attempter = FakeDeviceConnectionAttempter()
        let app = AppState(defaults: runtime.defaults, runtimePaths: runtime.runtimePaths,
                           monotonicTime: ManualMonotonicClock().timeSource,
                           connectionAttempter: attempter)
        app.discovery.scanLinesForTesting = [
            #"{"udid":"DEVICE-A","name":"Alpha","connectionType":"USB"}"#,
            #"{"udid":"DEVICE-B","name":"Beta","connectionType":"WiFi","host":"beta.local","port":1234}"#,
            #"{"udid":"DEVICE-C","name":"Gamma","connectionType":"USB"}"#
        ]
        return (runtime, app, attempter)
    }

    private func bindPair(_ app: AppState) async -> (DeviceSession, DeviceSession, FakeSimulationBackend, FakeSimulationBackend) {
        let first = app.selectedSession
        app.addSession()
        let second = app.selectedSession
        app.selectedSessionID = first.id
        let firstBackend = FakeSimulationBackend()
        let secondBackend = FakeSimulationBackend()
        await first.bindConnectedForTesting(udid: a, backend: firstBackend)
        await second.bindConnectedForTesting(udid: b, backend: secondBackend)
        return (first, second, firstBackend, secondBackend)
    }

    private func object(_ value: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let fields)? = value else { return nil }
        return fields
    }

    private func device(_ response: CommandResponse, udid: String) -> [String: JSONValue]? {
        guard let root = object(response.data), case .array(let devices)? = root["devices"] else { return nil }
        for value in devices {
            guard case .object(let fields) = value else { continue }
            if fields["udid"] == .string(udid) { return fields }
        }
        return nil
    }

    private func eventually(_ predicate: @escaping @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if await predicate() { return true }
            await Task.yield()
        }
        return await predicate()
    }

    private var route: [Command.Coordinate] {
        [.init(latitude: 25.0, longitude: 121.0),
         .init(latitude: 25.001, longitude: 121.001)]
    }

    @Test func devicesRefreshesFakeRowsAndIncludesTransportAndConnection() async throws {
        let (runtime, app, _) = try fixture()
        defer { runtime.cleanup() }
        let (first, _, _, _) = await bindPair(app)
        let focusedID = app.selectedSessionID
        let response = await app.dispatch(.devices)
        #expect(response.ok)
        #expect(object(response.data)?["protocol"] == .int(AIProtocol.version))
        #expect(device(response, udid: a)?["name"] == .string("Alpha"))
        #expect(device(response, udid: a)?["connection"] == .string("USB"))
        #expect(device(response, udid: a)?["connected"] == .bool(true))
        #expect(device(response, udid: b)?["connection"] == .string("WiFi"))
        #expect(device(response, udid: c)?["connected"] == .bool(false))
        #expect(app.selectedSessionID == focusedID)
        #expect(first.connectedUDID == a)
        app.discovery.scanLinesForTesting = [
            #"{"udid":"DEVICE-C","name":"Updated","connectionType":"USB"}"#
        ]
        let refreshed = await app.dispatch(.devices)
        #expect(device(refreshed, udid: c)?["name"] == .string("Updated"))
        // Connected sessions remain visible after a scan omits them.
        #expect(device(refreshed, udid: a)?["connected"] == .bool(true))
        #expect(device(refreshed, udid: b)?["connected"] == .bool(true))
        await app.prepareForQuit()
    }

    @Test func teleportRoutesToNamedDeviceOnly() async throws {
        let (runtime, app, _) = try fixture()
        defer { runtime.cleanup() }
        let (first, second, _, secondBackend) = await bindPair(app)
        app.selectedSessionID = second.id
        #expect((await app.dispatch(.teleport(udid: a, latitude: 25, longitude: 121))).ok)
        #expect(await eventually { await first.sim.integratorPosition?.latitude == 25 })
        #expect(await second.sim.integratorPosition == nil)
        #expect(secondBackend.quietLocationCount == 0)
        #expect(app.selectedSessionID == second.id)
        await app.prepareForQuit()
    }

    @Test func routeLoadsOnlyTargetAndRejectsTooFewPoints() async throws {
        let (runtime, app, _) = try fixture()
        defer { runtime.cleanup() }
        let (first, second, _, _) = await bindPair(app)
        app.selectedSessionID = second.id
        #expect((await app.dispatch(.route(udid: a, coordinates: [route[0]]))).code == "bad_route")
        #expect(first.routeCoordinates.isEmpty)
        #expect((await app.dispatch(.route(udid: a, coordinates: route))).ok)
        #expect(first.routeCoordinates.map(\.latitude) == [25.0, 25.001])
        #expect(second.routeCoordinates.isEmpty)
        #expect(first.simState.navigationPlaybackState == .idle)
        #expect(app.selectedSessionID == second.id)
        await app.prepareForQuit()
    }

    @Test func playPauseStopAndSeekClampUseTheTargetRoute() async throws {
        let (runtime, app, _) = try fixture()
        defer { runtime.cleanup() }
        let (first, second, _, _) = await bindPair(app)
        app.selectedSessionID = second.id
        #expect((await app.dispatch(.play(udid: a))).code == "no_route")
        #expect((await app.dispatch(.route(udid: a, coordinates: route))).ok)
        #expect((await app.dispatch(.play(udid: a))).ok)
        #expect(await eventually { first.simState.navigationPlaybackState == .playing })
        #expect(second.simState.navigationPlaybackState == .idle)
        #expect((await app.dispatch(.pause(udid: a))).ok)
        #expect(await eventually { first.simState.navigationPlaybackState == .paused })
        #expect((await app.dispatch(.seek(udid: a, progress: 2))).ok)
        #expect(await eventually { first.simState.navigationProgress == 1 })
        #expect((await app.dispatch(.seek(udid: a, progress: -2))).ok)
        #expect(await eventually { first.simState.navigationProgress == 0 })
        #expect(second.simState.navigationProgress == 0)
        #expect(app.selectedSessionID == second.id)
        #expect((await app.dispatch(.stop(udid: a))).ok)
        #expect(await eventually { first.simState.navigationPlaybackState == .idle })
        #expect(!first.routeCoordinates.isEmpty)
        await app.prepareForQuit()
    }

    @Test func clearSendsOnlyToNamedBackendAndStopsItsPlayback() async throws {
        let (runtime, app, _) = try fixture()
        defer { runtime.cleanup() }
        let (first, second, firstBackend, secondBackend) = await bindPair(app)
        #expect((await app.dispatch(.route(udid: a, coordinates: route))).ok)
        #expect((await app.dispatch(.play(udid: a))).ok)
        #expect(await eventually { first.simState.navigationPlaybackState == .playing })
        #expect((await app.dispatch(.clear(udid: a))).ok)
        #expect(firstBackend.commands == ["CLEAR"])
        #expect(secondBackend.commands.isEmpty)
        #expect(first.simState.navigationPlaybackState == .idle)
        #expect(second.simState.navigationPlaybackState == .idle)
        await app.prepareForQuit()
    }

    @Test func scopedVerbsReturnUnknownOrNotConnectedWithoutMovingAnotherDevice() async throws {
        let (runtime, app, _) = try fixture()
        defer { runtime.cleanup() }
        let (first, second, _, secondBackend) = await bindPair(app)
        app.addSession()
        app.selectedSession.selectedDeviceUDID = c
        app.selectedSessionID = second.id
        let known: [Command] = [.teleport(udid: c, latitude: 1, longitude: 2),
            .route(udid: c, coordinates: route), .play(udid: c), .pause(udid: c),
            .stop(udid: c), .seek(udid: c, progress: 0.5), .clear(udid: c)]
        for command in known {
            #expect((await app.dispatch(command)).code == "not_connected")
        }
        let unknown: [Command] = [.teleport(udid: "MISSING", latitude: 1, longitude: 2),
            .route(udid: "MISSING", coordinates: route), .play(udid: "MISSING"),
            .pause(udid: "MISSING"), .stop(udid: "MISSING"),
            .seek(udid: "MISSING", progress: 0.5), .clear(udid: "MISSING")]
        for command in unknown {
            #expect((await app.dispatch(command)).code == "unknown_device")
        }
        #expect(await first.sim.integratorPosition == nil)
        #expect(await second.sim.integratorPosition == nil)
        #expect(secondBackend.commands.isEmpty)
        #expect(app.selectedSessionID == second.id)
        await app.prepareForQuit()
    }

    @Test func connectIsAcknowledgedIdempotentAndDoesNotStealFocus() async throws {
        let (runtime, app, attempter) = try fixture()
        defer { runtime.cleanup() }
        let selected = app.selectedSession
        await selected.bindConnectedForTesting(udid: a, backend: FakeSimulationBackend())
        let focusedID = app.selectedSessionID
        let first = await app.dispatch(.connect(udid: b))
        #expect(first.data == .object(["state": .string("connecting"), "udid": .string(b)]))
        #expect(await eventually { attempter.inFlightCount == 1 })
        let whileConnecting = await app.dispatch(.connect(udid: b))
        #expect(whileConnecting.data == .object(["state": .string("connecting"), "udid": .string(b)]))
        #expect(attempter.calls.count == 1)
        attempter.succeedInFlight(with: FakeSimulationBackend())
        #expect(await eventually { app.sessions.first { $0.connectedUDID == b }?.connectionStatus == .connected })
        #expect(attempter.calls.map(\.udid) == [b])
        #expect(app.selectedSessionID == focusedID)
        let repeated = await app.dispatch(.connect(udid: b))
        #expect(repeated.data == .object(["state": .string("connected"), "udid": .string(b)]))
        #expect(attempter.calls.count == 1)
        #expect((await app.dispatch(.connect(udid: "MISSING"))).code == "unknown_device")
        #expect(device(await app.dispatch(.status), udid: b)?["state"] == .string("connected"))
        await app.prepareForQuit()
    }

    @Test func failedConnectIsReportedForItsDeviceWithoutChangingFocus() async throws {
        let (runtime, app, attempter) = try fixture()
        defer { runtime.cleanup() }
        await app.selectedSession.bindConnectedForTesting(udid: a, backend: FakeSimulationBackend())
        let focusedID = app.selectedSessionID
        attempter.script(.fail(FakeDeviceConnectionAttempter.AttemptError.unreachable))

        #expect((await app.dispatch(.connect(udid: b))).ok)
        #expect(await eventually {
            app.sessions.first { $0.selectedDeviceUDID == b }?.connectionStatus
                == .error("device unreachable")
        })
        let status = await app.dispatch(.status)
        #expect(device(status, udid: b)?["state"] == .string("error"))
        #expect(device(status, udid: b)?["error"] == .string("device unreachable"))
        #expect(device(status, udid: a)?["connected"] == .bool(true))
        #expect(app.selectedSessionID == focusedID)
        await app.prepareForQuit()
    }

    @Test func disconnectOnlyTargetsTheNamedDeviceAndReportsFailureForOthers() async throws {
        let (runtime, app, _) = try fixture()
        defer { runtime.cleanup() }
        let (first, second, firstBackend, secondBackend) = await bindPair(app)
        app.selectedSessionID = second.id
        let response = await app.dispatch(.disconnect(udid: a))
        #expect(response.data == .object(["state": .string("disconnected"), "udid": .string(a)]))
        #expect(first.connectionStatus == .disconnected)
        #expect(firstBackend.stopCount == 1)
        #expect(second.connectionStatus == .connected)
        #expect(secondBackend.stopCount == 0)
        #expect(app.selectedSessionID == second.id)
        let status = await app.dispatch(.status)
        #expect(device(status, udid: a)?["state"] == .string("disconnected"))
        #expect(device(status, udid: b)?["state"] == .string("connected"))
        #expect((await app.dispatch(.disconnect(udid: a))).code == "not_connected")
        #expect((await app.dispatch(.disconnect(udid: "MISSING"))).code == "not_connected")
        await app.prepareForQuit()
    }

    @Test func statusReportsPerDeviceActivityIndependentlyOfGuiFocus() async throws {
        let (runtime, app, _) = try fixture()
        defer { runtime.cleanup() }
        let (first, second, _, _) = await bindPair(app)
        app.selectedSessionID = second.id
        await first.sim.startRecording()
        #expect((await app.dispatch(.route(udid: a, coordinates: route))).ok)
        #expect((await app.dispatch(.seek(udid: a, progress: 0.5))).ok)
        #expect(await eventually { first.simState.navigationProgress == 0.5 })
        let response = await app.dispatch(.status)
        #expect(response.ok)
        #expect(object(response.data)?["protocol"] == .int(AIProtocol.version))
        #expect(object(object(response.data)?["connection"])?["udid"] == .string(b))
        #expect(device(response, udid: a)?["connected"] == .bool(true))
        #expect(device(response, udid: a)?["hasRoute"] == .bool(true))
        #expect(device(response, udid: a)?["recording"] == .bool(true))
        #expect(device(response, udid: a)?["progress"] == .double(0.5))
        #expect(device(response, udid: b)?["hasRoute"] == .bool(false))
        #expect(device(response, udid: b)?["recording"] == .bool(false))
        #expect(device(response, udid: b)?["playback"] == .string("idle"))
        #expect(device(response, udid: c)?["connected"] == .bool(false))
        #expect(second.simState.navigationProgress == 0)
        first.connectionStatus = .reconnecting(attempt: 3, maxAttempts: 10)
        let recovering = await app.dispatch(.status)
        #expect(device(recovering, udid: a)?["state"] == .string("reconnecting"))
        #expect(device(recovering, udid: a)?["connected"] == .bool(false))
        #expect(device(recovering, udid: a)?["attempt"] == .int(3))
        #expect(device(recovering, udid: a)?["maxAttempts"] == .int(10))
        await app.prepareForQuit()
    }

    @Test func aiTeleportRecordsCleanCoordinateWhileBackendReceivesNoisyCoordinate() async throws {
        let (runtime, app, _) = try fixture()
        defer { runtime.cleanup() }
        let session = app.selectedSession
        let backend = FakeSimulationBackend()
        await session.bindConnectedForTesting(udid: a, backend: backend)
        await session.sim.updateNoiseSigma(1_000)
        await session.sim.startRecording()
        #expect((await app.dispatch(.teleport(udid: a, latitude: 25, longitude: 121))).ok)
        #expect(await eventually { await session.sim.recordingStatus().pointCount == 1 })
        let draft = try #require(await session.sim.stopRecording())
        let point = try #require(draft.points.first)
        let wire = try #require(backend.locations.first)
        #expect(point.latitude == 25)
        #expect(point.longitude == 121)
        #expect(wire.0 != point.latitude || wire.1 != point.longitude)
        #expect(app.recordingsLibrary.recordings.isEmpty)
        await app.prepareForQuit()
    }
}
