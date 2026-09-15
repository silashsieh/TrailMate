import CoreLocation
import Testing
@testable import TrailMate

// Cross-checks our flat-ENU math (PositionIntegrator steps, NavigationEngine
// tangents and route distances) against CoreLocation's geodesic distance and
// a known city-scale reference pair. The 111_320 m/deg constant is a sphere
// approximation, so meter-scale assertions allow ~1% slack against WGS-84.
struct CoordinateMathTests {
    private let taipei101 = CLLocationCoordinate2D(latitude: 25.0339, longitude: 121.5645)
    private let taipeiMainStation = CLLocationCoordinate2D(latitude: 25.0478, longitude: 121.5170)

    private func geodesic(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    private func offset(
        _ base: CLLocationCoordinate2D,
        north: Double = 0,
        east: Double = 0
    ) -> CLLocationCoordinate2D {
        let latRad = base.latitude * .pi / 180
        return CLLocationCoordinate2D(
            latitude: base.latitude + north / 111_320.0,
            longitude: base.longitude + east / (111_320.0 * cos(latRad))
        )
    }

    private func referenceDistanceFromRoute(
        _ probe: CLLocationCoordinate2D,
        route: [CLLocationCoordinate2D]
    ) -> Double {
        guard route.count >= 2 else { return 0 }
        return zip(route, route.dropFirst())
            .map { referenceDistanceFromSegment(probe: probe, a: $0.0, b: $0.1) }
            .min() ?? 0
    }

    private func referenceDistanceFromSegment(
        probe: CLLocationCoordinate2D,
        a: CLLocationCoordinate2D,
        b: CLLocationCoordinate2D
    ) -> Double {
        let probeLoc = CLLocation(latitude: probe.latitude, longitude: probe.longitude)
        let aLoc = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let bLoc = CLLocation(latitude: b.latitude, longitude: b.longitude)
        let ab = aLoc.distance(from: bLoc)
        let ap = aLoc.distance(from: probeLoc)
        let bp = bLoc.distance(from: probeLoc)

        if ab == 0 { return ap }

        let t = (ap * ap + ab * ab - bp * bp) / (2 * ab)
        if t <= 0 { return ap }
        if t >= ab { return bp }

        let perpSq = ap * ap - t * t
        return perpSq > 0 ? perpSq.squareRoot() : 0
    }

    @Test func routeDistanceMatchesKnownTaipeiReference() {
        // Taipei 101 → Taipei Main Station straight line: haversine gives
        // 5028.7 m; testing.md's reference demands agreement within 1%.
        let engine = NavigationEngine()
        engine.loadRoute(coordinates: [taipei101, taipeiMainStation], baseSpeed: 1.4)
        #expect(abs(engine.totalDistance - 5028.7) < 50.3)
    }

    @Test func eastStepMatchesGeodesicDistance() throws {
        let start = CLLocationCoordinate2D(latitude: 25.0, longitude: 121.5)
        let integrator = PositionIntegrator()
        integrator.reset(to: start)
        integrator.step(vx: 10, vy: 0, dt: 1)
        let pos = try #require(integrator.position)
        #expect(pos.latitude == start.latitude)
        #expect(abs(geodesic(start, pos) - 10) < 0.1)
    }

    @Test func northStepMatchesGeodesicDistance() throws {
        let start = CLLocationCoordinate2D(latitude: 25.0, longitude: 121.5)
        let integrator = PositionIntegrator()
        integrator.reset(to: start)
        integrator.step(vx: 0, vy: 5, dt: 2)
        let pos = try #require(integrator.position)
        #expect(pos.longitude == start.longitude)
        #expect(abs(geodesic(start, pos) - 10) < 0.1)
    }

    @Test func eastStepAtHighLatitudeHonorsCosScaling() throws {
        // At 60° N a degree of longitude is half as long as at the equator,
        // so the same 10 m east step must move twice as many degrees.
        let start = CLLocationCoordinate2D(latitude: 60.0, longitude: 10.0)
        let integrator = PositionIntegrator()
        integrator.reset(to: start)
        integrator.step(vx: 10, vy: 0, dt: 1)
        let pos = try #require(integrator.position)
        let expectedDeltaLon = 10.0 / (111_320.0 * cos(60.0 * .pi / 180))
        #expect(abs((pos.longitude - start.longitude) - expectedDeltaLon) < 1e-12)
        #expect(abs(geodesic(start, pos) - 10) < 0.1)
    }

    @Test func tickVelocityIsTangentToSegment() throws {
        // Due-north segment: the full tick velocity lands on the +y axis.
        let start = taipei101
        let end = CLLocationCoordinate2D(latitude: start.latitude + 100.0 / 111_320.0,
                                         longitude: start.longitude)
        let engine = NavigationEngine()
        engine.loadRoute(coordinates: [start, end], baseSpeed: 2.0)
        engine.play(multiplier: 1.0)
        let tick = try #require(engine.tick(dt: 1))
        #expect(abs(tick.vx) < 1e-9)
        #expect(abs(tick.vy - 2.0) < 1e-9)
        #expect(tick.jump == nil)
    }

    @Test func tickVelocityMagnitudeOnDiagonal() throws {
        // 30 m east + 40 m north (3-4-5 triangle), built with the engine's own
        // ENU constants so the tangent components are exact: vx/vy = 3/4 and
        // |v| equals the base speed.
        let start = taipei101
        let latRad = start.latitude * .pi / 180
        let end = CLLocationCoordinate2D(
            latitude: start.latitude + 40.0 / 111_320.0,
            longitude: start.longitude + 30.0 / (111_320.0 * cos(latRad))
        )
        let engine = NavigationEngine()
        engine.loadRoute(coordinates: [start, end], baseSpeed: 5.0)
        engine.play(multiplier: 1.0)
        let tick = try #require(engine.tick(dt: 1))
        #expect(abs((tick.vx * tick.vx + tick.vy * tick.vy).squareRoot() - 5.0) < 1e-6)
        #expect(abs(tick.vx / tick.vy - 0.75) < 1e-6)
    }

    @Test func deviationDistanceMatchesCLLocationReference() {
        let start = CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654)
        let north = offset(start, north: 100)
        let east = offset(north, east: 120)
        let probe = offset(start, north: 50, east: 20)
        let route = [start, north, east]

        let engine = NavigationEngine()
        engine.loadRoute(coordinates: route, baseSpeed: 1.4)

        let expected = referenceDistanceFromRoute(probe, route: route)
        #expect(abs(engine.distanceFromRoute(probe) - expected) < 0.25)
    }
}
