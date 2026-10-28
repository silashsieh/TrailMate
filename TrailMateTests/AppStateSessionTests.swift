import CoreLocation
import Testing
@testable import TrailMate

@MainActor
struct AppStateSessionTests {
    @Test func addSelectAndRemoveKeepOneSlotAndRehomeJoystick() async throws {
        let h = try SessionWorkflowHarness()
        let a = h.app.selectedSession
        #expect(h.app.sessions.count == 1)
        #expect(await h.eventually { await a.sim.isJoystickActive })

        h.app.addSession()
        let b = h.app.selectedSession
        #expect(h.app.sessions.map(\.id) == [a.id, b.id])
        #expect(h.app.selectedSessionID == b.id)
        #expect(await h.eventually {
            let aArmed = await a.sim.isJoystickActive
            let bArmed = await b.sim.isJoystickActive
            return !aArmed && bArmed
        })

        h.app.selectedSessionID = a.id
        #expect(await h.eventually {
            let aArmed = await a.sim.isJoystickActive
            let bArmed = await b.sim.isJoystickActive
            return aArmed && !bArmed
        })

        h.app.removeSession(a)
        #expect(h.app.sessions.map(\.id) == [b.id])
        #expect(h.app.selectedSessionID == b.id)
        #expect(await h.eventually { await b.sim.isJoystickActive })

        h.app.removeSession(b)
        #expect(h.app.sessions.count == 1)
        #expect(h.app.selectedSessionID == h.app.sessions[0].id)
        #expect(h.app.selectedSession.id != a.id && h.app.selectedSession.id != b.id)
        await h.finish()
    }

    @Test func tuningSeedsNewSessionAndFansOutLaterChanges() async throws {
        let h = try SessionWorkflowHarness()
        let a = h.app.selectedSession
        h.app.transportMode = .cycle
        h.app.noiseSigmaMeters = 2.5
        h.app.loopMode = .restart
        h.app.loopCount = 3
        h.app.addSession()
        let b = h.app.selectedSession

        #expect(await h.eventually {
            let x = await a.sim.tuningForTesting
            let y = await b.sim.tuningForTesting
            return abs(x.baseSpeed - 15.0 / 3.6) < 1e-9
                && abs(y.baseSpeed - 15.0 / 3.6) < 1e-9
                && x.noiseSigma == 2.5 && y.noiseSigma == 2.5
                && x.loopMode == .restart && y.loopMode == .restart
                && x.loopCount == 3 && y.loopCount == 3
        })

        h.app.transportMode = .custom
        h.app.customSpeedKmh = 36
        h.app.noiseSigmaMeters = 0
        h.app.loopMode = .pingPong
        h.app.loopCount = 2
        #expect(await h.eventually {
            let x = await a.sim.tuningForTesting
            let y = await b.sim.tuningForTesting
            return x.baseSpeed == 10 && y.baseSpeed == 10
                && x.noiseSigma == 0 && y.noiseSigma == 0
                && x.loopMode == .pingPong && y.loopMode == .pingPong
                && x.loopCount == 2 && y.loopCount == 2
        })
        await h.finish()
    }

    @Test func selectedNameFollowsConnectionAndClearsOnDisconnect() async throws {
        let h = try SessionWorkflowHarness()
        let a = h.app.selectedSession
        a.deviceName = "Alpha"
        a.bindConnectedForTesting(udid: "A")
        #expect(h.app.connectedDeviceName == "Alpha")

        h.app.addSession()
        let b = h.app.selectedSession
        b.deviceName = "Beta"
        #expect(h.app.connectedDeviceName == nil)
        b.bindConnectedForTesting(udid: "B")
        #expect(h.app.connectedDeviceName == "Beta")

        await h.app.disconnect()
        #expect(h.app.connectedDeviceName == nil)
        #expect(b.deviceName == "Beta", "the switcher can still identify its disconnected slot")
        h.app.selectedSessionID = a.id
        #expect(h.app.connectedDeviceName == "Alpha")
        await a.disconnect()
        #expect(h.app.connectedDeviceName == nil)
        await h.finish()
    }

    @Test func routeAndPlaybackStayWithTheirOwningSession() async throws {
        let h = try SessionWorkflowHarness()
        let a = h.app.selectedSession
        let aRoute = [point(25, 121), point(25.001, 121.001)]
        await h.app.loadDrawnRoute(aRoute)

        h.app.addSession()
        let b = h.app.selectedSession
        let bRoute = [point(24, 120), point(24.001, 120.001)]
        await h.app.loadDrawnRoute(bRoute)
        #expect(h.app.routeCoordinates.map(\.latitude) == bRoute.map(\.latitude))
        h.app.startPlayback()
        #expect(await h.eventually { b.simState.navigationPlaybackState == .playing })
        #expect(a.simState.navigationPlaybackState == .idle)

        h.app.selectedSessionID = a.id
        #expect(h.app.routeCoordinates.map(\.latitude) == aRoute.map(\.latitude))
        #expect(h.app.simState.navigationPlaybackState == .idle)
        h.app.startPlayback()
        #expect(await h.eventually { a.simState.navigationPlaybackState == .playing })
        h.app.stopPlayback()
        #expect(await h.eventually { a.simState.navigationPlaybackState == .idle })
        #expect(b.simState.navigationPlaybackState == .playing)
        await h.finish()
    }

    private func point(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}
