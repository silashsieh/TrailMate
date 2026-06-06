import CoreLocation
import Testing
@testable import TrailMate

// Engine-level loop tests can't see the integrator, which owns the on-screen
// position — this exercises the actor seam those tests miss. Deterministic:
// no aggregator, no ticks, no sleeps.
struct SimulationActorReplayTests {
    // Regression: after a route ran to completion the integrator stayed parked
    // at the far end (play() seeded it only from nil), so a second Play
    // re-armed the engine at distance 0 while the marker traced a route-shaped
    // ghost path offset from the polyline. Play from idle must reset the
    // integrator to the route start.
    @MainActor
    @Test func playFromIdleResetsIntegratorToRouteStart() async throws {
        let bridge = SimulationStateBridge()
        let recorder = RecorderService()
        let sim = SimulationActor(bridge: bridge, recorder: recorder)

        let start = CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654)
        let end = CLLocationCoordinate2D(latitude: 25.0330 + 100.0 / 111_320.0, longitude: 121.5654)

        await sim.loadRoute(coordinates: [start, end], baseSpeed: 50, resetStart: true)
        // Park the integrator away from the start — the same state a completed
        // pass leaves behind (nav idle, position at the far end).
        await sim.teleport(to: end)
        await sim.play(multiplier: 1)

        let pos = await sim.integratorPosition
        #expect(pos != nil)
        if let pos {
            let d = CLLocation(latitude: pos.latitude, longitude: pos.longitude)
                .distance(from: CLLocation(latitude: start.latitude, longitude: start.longitude))
            #expect(d < 0.01)
        }
    }
}
