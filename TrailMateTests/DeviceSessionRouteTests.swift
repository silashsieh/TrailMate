import CoreLocation
import MapKit
import Testing
@testable import TrailMate

@MainActor
struct DeviceSessionRouteTests {
    @Test func offlinePlannerBuildsPlaysStopsAndSavesWithoutADevice() async throws {
        let from = point(25, 121)
        let stop = point(25.001, 121.001)
        let to = point(25.002, 121.002)
        let plan = RoutePlan(coordinates: [from, stop, to], distanceMeters: 300, travelTimeSeconds: 180)
        let router = FakeRoutingService(.plan(plan))
        let h = try SessionWorkflowHarness(router: router)
        let session = h.app.selectedSession
        h.app.fromCoordinate = from
        h.app.toCoordinate = to
        h.app.fromSearch.setQuery("From")
        h.app.toSearch.setQuery("To")
        h.app.addStop()
        h.app.stops[0].coordinate = stop
        h.app.stops[0].search.setQuery("Stop")

        #expect(h.app.canCalculateRoute)
        await h.app.calculateRoute()
        #expect(session.connectionStatus == .disconnected)
        #expect(h.attempter.calls.isEmpty)
        #expect(h.app.routeCoordinates.map(\.latitude) == plan.coordinates.map(\.latitude))
        #expect(router.requestedWaypoints.first?.map(\.latitude) == [25, 25.001, 25.002])
        #expect(await h.eventually { session.simState.simulatedCoordinate?.latitude == from.latitude })

        h.app.startPlayback()
        #expect(await h.eventually { session.simState.navigationPlaybackState == .playing })
        h.app.saveCurrentLocation(name: "Offline start")
        #expect(h.app.savedWaypoints.map(\.name) == ["Offline start"])
        h.app.stopPlayback()
        #expect(await h.eventually { session.simState.navigationPlaybackState == .idle })

        h.app.saveCurrentRoute(name: "Offline plan")
        let saved = try #require(h.app.savedRoutes.routes.first)
        #expect(saved.name == "Offline plan")
        #expect(saved.coordinates.map(\.lat) == [25, 25.001, 25.002])
        #expect(saved.fromWaypoint?.label == "From")
        #expect(saved.toWaypoint?.label == "To")
        #expect(saved.stopWaypoints?.first?.label == "Stop")
        #expect(FileManager.default.fileExists(
            atPath: h.runtime.runtimePaths.savedRoutesDirectory
                .appendingPathComponent("\(saved.id.uuidString).json").path
        ))
        await h.finish()
    }

    @Test func routeFailureKeepsTheLastGoodOfflineRoute() async throws {
        let router = FakeRoutingService(.legNotFound(1))
        let h = try SessionWorkflowHarness(router: router)
        let old = [point(25, 121), point(25.001, 121.001)]
        await h.app.loadDrawnRoute(old)
        h.app.fromCoordinate = old[0]
        h.app.toCoordinate = old[1]
        h.app.addStop()
        h.app.stops[0].coordinate = point(25.0005, 121.0005)

        await h.app.calculateRoute()
        #expect(h.app.routeCoordinates.map(\.latitude) == old.map(\.latitude))
        #expect(!h.app.isCalculatingRoute)
        #expect(h.app.logMessages.contains { $0.contains("Stop 1 → To: no route found") })
        #expect(h.attempter.calls.isEmpty)
        await h.finish()
    }

    @Test func searchSuccessAndFailureUseInjectedResolverAndKeepPlannerSeparate() async throws {
        let found = point(23.5, 120.5)
        let success = try SessionWorkflowHarness(searchResultResolver: { _, _ in found })
        let completion = MKLocalSearchCompletion()
        await success.app.goToSearchResult(completion)
        #expect(await success.eventually {
            await success.app.selectedSession.sim.integratorPosition?.latitude == found.latitude
        })
        #expect(success.app.fromCoordinate == nil && success.app.toCoordinate == nil)
        #expect(success.app.mapFocus != nil)

        await success.app.selectFrom(completion)
        await success.app.selectTo(completion)
        success.app.addStop()
        await success.app.selectStop(id: success.app.stops[0].id, completion: completion)
        #expect(success.app.fromCoordinate?.latitude == found.latitude)
        #expect(success.app.toCoordinate?.latitude == found.latitude)
        #expect(success.app.stops[0].coordinate?.latitude == found.latitude)
        await success.finish()

        let failure = try SessionWorkflowHarness(searchResultResolver: { _, _ in nil })
        await failure.app.goToSearchResult(completion)
        await failure.app.selectFrom(completion)
        #expect(await failure.app.selectedSession.sim.integratorPosition == nil)
        #expect(failure.app.mapFocus == nil)
        #expect(failure.app.fromCoordinate == nil)
        #expect(failure.app.logMessages.contains { $0.contains("Couldn't resolve") })
        await failure.finish()
    }

    @Test func copyWritesPasteableCoordinateOnlyToTheInjectedWriter() async throws {
        let clipboard = ClipboardProbe()
        let h = try SessionWorkflowHarness(coordinateWriter: { clipboard.text = $0 })
        let coordinate = point(25.033123, 121.565456)
        h.app.copyCoordinate(coordinate)
        #expect(clipboard.text == "25.033123, 121.565456")
        let parsed = try #require(CoordinateFormat.parse(clipboard.text ?? ""))
        #expect(parsed.latitude == coordinate.latitude)
        #expect(parsed.longitude == coordinate.longitude)
        await h.finish()
    }

    @Test func offlinePositionAndRouteSurviveDisconnectThenMirrorOnReattach() async throws {
        let h = try SessionWorkflowHarness()
        let session = h.app.selectedSession
        session.selectedDeviceUDID = "DEVICE-A"
        h.app.noiseSigmaMeters = 0
        #expect(await h.eventually { await session.sim.tuningForTesting.noiseSigma == 0 })

        let route = [point(25, 121), point(25.001, 121.001)]
        await h.app.loadDrawnRoute(route)
        let first = FakeSimulationBackend()
        h.attempter.script(.succeed(first))
        await h.app.connect()
        #expect(session.connectionStatus == .connected)
        #expect(first.lastQuietLocation?.latitude == route[0].latitude)

        await h.app.disconnect()
        #expect(session.connectionStatus == .disconnected)
        #expect(session.routeCoordinates.map(\.latitude) == route.map(\.latitude))
        let final = point(24.5, 120.5)
        await session.sim.teleport(to: final)
        #expect(session.simState.simulatedCoordinate?.latitude == final.latitude)
        #expect(first.stopCount == 1)

        let replacement = FakeSimulationBackend()
        h.attempter.script(.succeed(replacement))
        await h.app.connect()
        #expect(session.connectionStatus == .connected)
        #expect(session.routeCoordinates.map(\.latitude) == route.map(\.latitude))
        #expect(replacement.lastQuietLocation?.latitude == final.latitude)
        #expect(replacement.lastQuietLocation?.longitude == final.longitude)
        #expect(h.attempter.calls.map(\.udid) == ["DEVICE-A", "DEVICE-A"])
        await h.finish()
    }

    private func point(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

@MainActor
private final class ClipboardProbe {
    var text: String?
}
