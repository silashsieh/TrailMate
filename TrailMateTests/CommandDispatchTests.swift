import CoreLocation
import Foundation
import Testing
@testable import TrailMate

// Multi-device dispatch routing (epic 012). The top correctness risk is that a
// UDID-scoped command for device A must reach A's session and never B's — with N
// sessions a mis-wired backend would silently spoof the wrong phone. These tests
// prove dispatch resolves the target session by connectedUDID, and that an
// unknown or not-connected UDID is a clean machine-readable error, not a
// fall-through onto another device.
@MainActor
struct CommandDispatchTests {
    // Build a manager with two sessions bound (sans tunnel) to A and B.
    private func twoConnectedSessions() -> (AppState, DeviceSession, DeviceSession) {
        let suiteName = "com.sh.TrailMateTests.CommandDispatch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        SimulatedPositionPersistence.setRestoreOnLaunch(false, in: defaults)

        let app = AppState(defaults: defaults)
        // Avoid dispatch's lazy discovery scan (it would shell out to the real
        // device lister); we don't rely on discovery for connected routing.
        app.discovery.hasScanned = true
        let a = app.sessions[0]
        app.addSession()
        let b = app.sessions[1]
        a.bindConnectedForTesting(udid: "DEVICE-A")
        b.bindConnectedForTesting(udid: "DEVICE-B")
        return (app, a, b)
    }

    // Poll the actor's authoritative integrator position until it reaches the
    // target — DeviceSession.teleport hands off to the actor on a detached Task,
    // so the move isn't synchronous with dispatch returning.
    private func awaitLatitude(_ session: DeviceSession, near lat: Double) async -> CLLocationCoordinate2D? {
        for _ in 0..<100 {
            if let p = await session.sim.integratorPosition, abs(p.latitude - lat) < 1e-5 {
                return p
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await session.sim.integratorPosition
    }

    @Test func teleportRoutesToNamedDeviceOnly() async {
        let (app, a, b) = twoConnectedSessions()

        let resp = await app.dispatch(.teleport(udid: "DEVICE-A", latitude: 25.0, longitude: 121.0))
        #expect(resp.ok)

        // A landed on the commanded coordinate…
        let aPos = await awaitLatitude(a, near: 25.0)
        #expect(aPos != nil)
        #expect(abs((aPos?.latitude ?? -999) - 25.0) < 1e-4)
        // …and B never moved (it was never teleported or restored).
        let bPos = await b.sim.integratorPosition
        #expect(bPos == nil)
    }

    @Test func teleportToOtherDeviceLeavesFirstUntouched() async {
        let (app, a, b) = twoConnectedSessions()

        let resp = await app.dispatch(.teleport(udid: "DEVICE-B", latitude: 24.0, longitude: 120.0))
        #expect(resp.ok)

        let bPos = await awaitLatitude(b, near: 24.0)
        #expect(bPos != nil)
        #expect(abs((bPos?.latitude ?? -999) - 24.0) < 1e-4)
        // A was the launch-restore slot; whatever its dot, it must not be at B's
        // commanded latitude — i.e. B's command did not bleed onto A.
        let aPos = await a.sim.integratorPosition
        if let aPos {
            #expect(abs(aPos.latitude - 24.0) > 1e-4)
        }
    }

    @Test func unknownUDIDIsRejected() async {
        let (app, _, _) = twoConnectedSessions()
        let resp = await app.dispatch(.teleport(udid: "NO-SUCH-DEVICE", latitude: 1, longitude: 1))
        #expect(!resp.ok)
        #expect(resp.code == "unknown_device")
    }

    @Test func knownButNotConnectedUDIDIsNotConnected() async {
        let (app, _, _) = twoConnectedSessions()
        // A slot targets DEVICE-C but never connected — "known, not connected".
        app.addSession()
        app.sessions[2].selectedDeviceUDID = "DEVICE-C"

        let resp = await app.dispatch(.pause(udid: "DEVICE-C"))
        #expect(!resp.ok)
        #expect(resp.code == "not_connected")
    }

    // STATUS must report each device's own connection + simulation state, so an
    // agent can poll the device it CONNECTed regardless of the GUI selection.
    @Test func statusReportsPerDeviceState() async {
        let (app, _, _) = twoConnectedSessions()
        let resp = await app.dispatch(.status)
        #expect(resp.ok)
        guard case .object(let root)? = resp.data,
              case .array(let devices)? = root["devices"] else {
            Issue.record("status payload missing devices array")
            return
        }
        let udids: [String] = devices.compactMap {
            guard case .object(let d) = $0, case .string(let u)? = d["udid"] else { return nil }
            return u
        }
        #expect(udids.contains("DEVICE-A"))
        #expect(udids.contains("DEVICE-B"))
    }
}
