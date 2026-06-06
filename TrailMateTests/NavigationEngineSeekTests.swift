import CoreLocation
import Testing
@testable import TrailMate

// Engine-level seek math (epic 011). Interpolation between vertices is
// fraction-based, so midpoint expectations along axis-aligned segments are
// exact regardless of the geodesic distance metric.
struct NavigationEngineSeekTests {
    // Two-segment L-shaped route near Taipei City Hall:
    // a → b due north (~111 m), b → c due east (~101 m).
    private let a = CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654)
    private let b = CLLocationCoordinate2D(latitude: 25.0340, longitude: 121.5654)
    private let c = CLLocationCoordinate2D(latitude: 25.0340, longitude: 121.5664)

    private func makeEngine() -> (engine: NavigationEngine, ab: Double, bc: Double) {
        let engine = NavigationEngine()
        engine.loadRoute(coordinates: [a, b, c], baseSpeed: 1.4)
        let ab = CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        let bc = CLLocation(latitude: b.latitude, longitude: b.longitude)
            .distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude))
        return (engine, ab, bc)
    }

    @Test func seekToFirstSegmentMidpoint() {
        let (engine, ab, bc) = makeEngine()
        let coord = engine.seek(toProgress: (ab / 2) / (ab + bc))
        // Halfway up the due-north segment: lat midway, lon unchanged.
        #expect(abs(coord!.latitude - (a.latitude + b.latitude) / 2) < 1e-9)
        #expect(abs(coord!.longitude - a.longitude) < 1e-9)
        #expect(abs(engine.progress - (ab / 2) / (ab + bc)) < 1e-9)
        #expect(abs(engine.elapsedDistance - ab / 2) < 1e-9)
    }

    @Test func seekToSecondSegmentMidpoint() {
        let (engine, ab, bc) = makeEngine()
        let coord = engine.seek(toProgress: (ab + bc / 2) / (ab + bc))
        // Halfway along the due-east segment: lon midway, lat pinned to b's.
        #expect(abs(coord!.latitude - b.latitude) < 1e-9)
        #expect(abs(coord!.longitude - (b.longitude + c.longitude) / 2) < 1e-9)
    }

    @Test func seekClampsBelowZero() {
        let (engine, _, _) = makeEngine()
        let coord = engine.seek(toProgress: -0.5)
        #expect(abs(coord!.latitude - a.latitude) < 1e-9)
        #expect(abs(coord!.longitude - a.longitude) < 1e-9)
        #expect(engine.progress == 0)
        #expect(engine.elapsedDistance == 0)
    }

    @Test func seekClampsPastEnd() {
        let (engine, _, _) = makeEngine()
        let coord = engine.seek(toProgress: 1.5)
        #expect(abs(coord!.latitude - c.latitude) < 1e-9)
        #expect(abs(coord!.longitude - c.longitude) < 1e-9)
        #expect(engine.progress == 1)
    }

    @Test func seekBackwardAfterForward() {
        let (engine, ab, bc) = makeEngine()
        _ = engine.seek(toProgress: (ab + bc / 2) / (ab + bc))
        let coord = engine.seek(toProgress: (ab / 4) / (ab + bc))
        #expect(abs(coord!.latitude - (a.latitude + (b.latitude - a.latitude) / 4)) < 1e-9)
        #expect(abs(engine.elapsedDistance - ab / 4) < 1e-9)
    }

    @Test func seekLeavesPlaybackStateUntouched() {
        let (engine, _, _) = makeEngine()
        #expect(engine.playbackState == .idle)
        _ = engine.seek(toProgress: 0.5)
        #expect(engine.playbackState == .idle)
        engine.play(multiplier: 1)
        _ = engine.seek(toProgress: 0.25)
        #expect(engine.playbackState == .playing)
    }

    @Test func seekWithoutRouteReturnsNil() {
        let engine = NavigationEngine()
        #expect(engine.seek(toProgress: 0.5) == nil)
    }

    @Test func seekOnIdleRouteArmsPlayFromSoughtPoint() {
        let (engine, ab, bc) = makeEngine()
        let total = ab + bc
        _ = engine.seek(toProgress: 0.5)
        engine.play(multiplier: 1)
        // play() must honor the pending seek instead of re-arming from the
        // top; the next 1 s tick at 1.4 m/s advances from the sought point.
        #expect(abs(engine.elapsedDistance - total / 2) < 1e-9)
        _ = engine.tick(dt: 1)
        #expect(abs(engine.elapsedDistance - (total / 2 + 1.4)) < 1e-9)
    }

    @Test func playWithoutSeekStillRearmsFromTop() {
        let (engine, ab, bc) = makeEngine()
        engine.play(multiplier: 1)
        _ = engine.tick(dt: (ab + bc) / 1.4 + 1)   // run the route to completion
        #expect(engine.playbackState == .idle)
        engine.play(multiplier: 1)
        // No seek intervened — the a724b83 re-play semantics stand.
        #expect(engine.elapsedDistance == 0)
        #expect(engine.progress == 0)
    }

    // Progress runs 0→1 per leg, so a scrub on a ping-pong return leg seeks
    // within that leg: fraction 0.25 of the way back means 75% of the route
    // distance from the start, heading toward it.
    @Test func seekOnPingPongReturnLegMapsWithinLeg() {
        let start = CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654)
        let end = CLLocationCoordinate2D(latitude: 25.0330 + 100 / 111_320.0, longitude: 121.5654)
        let engine = NavigationEngine()
        engine.loadRoute(coordinates: [start, end], baseSpeed: 1.0)
        engine.updateLoop(mode: .pingPong, count: 0)
        engine.play(multiplier: 1)
        let d = engine.totalDistance
        _ = engine.tick(dt: d)                     // lands on the far end, flips to returning

        let coord = engine.seek(toProgress: 0.25)
        #expect(abs(engine.progress - 0.25) < 1e-9)
        #expect(abs(engine.elapsedDistance - d / 4) < 1e-9)
        // 25% into the return leg = 75% of the way up the route.
        #expect(abs(coord!.latitude - (start.latitude + (end.latitude - start.latitude) * 0.75)) < 1e-9)
        // Still on the return leg: the next tick keeps heading south.
        let next = engine.tick(dt: 1)
        #expect((next?.vy ?? 0) < 0)
    }
}
