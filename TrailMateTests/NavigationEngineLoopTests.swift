import CoreLocation
import Testing
@testable import TrailMate

struct NavigationEngineLoopTests {
    // Taipei City Hall, used as a stable reference point.
    private let start = CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654)

    private func offset(_ base: CLLocationCoordinate2D, north: Double) -> CLLocationCoordinate2D {
        // ~111_320 m per degree of latitude.
        CLLocationCoordinate2D(latitude: base.latitude + north / 111_320.0, longitude: base.longitude)
    }

    private func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    // A ~100 m straight northbound route at 1 m/s, so tick(dt: totalDistance)
    // traverses exactly one leg per call.
    private func makeEngine() -> NavigationEngine {
        let engine = NavigationEngine()
        engine.loadRoute(coordinates: [start, offset(start, north: 100)], baseSpeed: 1.0)
        return engine
    }

    @Test func restartLoopWrapsToStartWithJump() {
        let engine = makeEngine()
        engine.updateLoop(mode: .restart, count: 0)
        engine.play(multiplier: 1)
        let d = engine.totalDistance

        let wrap = engine.tick(dt: d)
        #expect(wrap != nil)
        #expect(wrap?.jump != nil)
        #expect(wrap?.vx == 0)
        #expect(wrap?.vy == 0)
        #expect(engine.playbackState == .playing)
        #expect(engine.completedLoops == 1)
        #expect(engine.progress == 0)
        #expect(engine.elapsedDistance == 0)
        if let jump = wrap?.jump {
            #expect(distance(jump, start) < 0.01)
        }
    }

    @Test func restartLoopHonorsCount() {
        let engine = makeEngine()
        engine.updateLoop(mode: .restart, count: 2)
        engine.play(multiplier: 1)
        let d = engine.totalDistance

        #expect(engine.tick(dt: d)?.jump != nil)   // pass 1 done → wraps
        #expect(engine.playbackState == .playing)

        let final = engine.tick(dt: d)             // pass 2 done → count reached
        #expect(final?.jump == nil)
        #expect(engine.playbackState == .idle)
        #expect(engine.completedLoops == 2)
        #expect(engine.progress == 1.0)
    }

    @Test func pingPongReversesWithoutJump() {
        let engine = makeEngine()
        engine.updateLoop(mode: .pingPong, count: 0)
        engine.play(multiplier: 1)
        let d = engine.totalDistance

        let flip = engine.tick(dt: d)              // lands on B, flips
        #expect(flip?.jump == nil)
        #expect((flip?.vy ?? 0) > 0)               // still northbound on the landing tick
        #expect(engine.playbackState == .playing)

        let back = engine.tick(dt: d / 2)          // halfway down the return leg
        #expect(back?.jump == nil)
        #expect((back?.vy ?? 0) < 0)               // southbound now
        #expect(abs(engine.elapsedDistance - d / 2) < 0.01)  // per-leg elapsed
        #expect(abs(engine.progress - 0.5) < 0.001)
    }

    @Test func pingPongCountsRoundTrips() {
        let engine = makeEngine()
        engine.updateLoop(mode: .pingPong, count: 1)
        engine.play(multiplier: 1)
        let d = engine.totalDistance

        _ = engine.tick(dt: d)                     // A→B: flip, not yet a loop
        #expect(engine.completedLoops == 0)
        #expect(engine.playbackState == .playing)

        _ = engine.tick(dt: d)                     // B→A: round trip 1 → done
        #expect(engine.completedLoops == 1)
        #expect(engine.playbackState == .idle)
        if let pos = engine.expectedPosition {
            #expect(distance(pos, start) < 0.01)   // ends back at A
        }
    }

    // Regression: a finished route left currentDistance at totalDistance, so
    // a second Play re-idled instantly at the far end.
    @Test func playAfterCompletionRestartsFromStart() {
        let engine = makeEngine()
        engine.play(multiplier: 1)
        let d = engine.totalDistance

        #expect(engine.tick(dt: d) != nil)
        #expect(engine.playbackState == .idle)
        #expect(engine.progress == 1.0)

        engine.play(multiplier: 1)
        #expect(engine.playbackState == .playing)
        #expect(engine.progress == 0)

        #expect(engine.tick(dt: d / 2) != nil)
        #expect(engine.playbackState == .playing)
        #expect(abs(engine.progress - 0.5) < 0.001)
    }

    // The boundary clamp means one leg end per tick, even when a single tick's
    // advance would overshoot the whole route several times over.
    @Test func overshootTickClampsToOneBoundary() {
        let engine = makeEngine()
        engine.updateLoop(mode: .restart, count: 3)
        engine.play(multiplier: 1)
        let d = engine.totalDistance

        #expect(engine.tick(dt: 10 * d)?.jump != nil)
        #expect(engine.completedLoops == 1)
        #expect(engine.tick(dt: 10 * d)?.jump != nil)
        #expect(engine.completedLoops == 2)
        #expect(engine.tick(dt: 10 * d)?.jump == nil)  // count reached → no wrap
        #expect(engine.completedLoops == 3)
        #expect(engine.playbackState == .idle)
    }

    @Test func stopPreservesLoopConfigAndResetsRuntime() {
        let engine = makeEngine()
        engine.updateLoop(mode: .pingPong, count: 5)
        engine.play(multiplier: 1)
        let d = engine.totalDistance
        _ = engine.tick(dt: d)                     // flip at B

        engine.stop()
        #expect(engine.playbackState == .idle)
        #expect(engine.loopMode == .pingPong)      // config survives stop
        #expect(engine.loopCount == 5)
        #expect(engine.completedLoops == 0)        // runtime state resets

        engine.play(multiplier: 1)
        let r = engine.tick(dt: d / 2)
        #expect((r?.vy ?? 0) > 0)                  // forward again, not stuck returning
    }
}
