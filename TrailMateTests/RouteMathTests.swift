import CoreLocation
import Testing
@testable import TrailMate

struct RouteMathTests {
    // Taipei City Hall, used as a stable reference point.
    private let p = CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654)

    private func offset(_ base: CLLocationCoordinate2D, north: Double) -> CLLocationCoordinate2D {
        // ~111_320 m per degree of latitude.
        CLLocationCoordinate2D(latitude: base.latitude + north / 111_320.0, longitude: base.longitude)
    }

    @Test func joinEmptyA() {
        let result = RouteMath.joinSegments([], [p])
        #expect(result.count == 1)
    }

    @Test func joinEmptyB() {
        let result = RouteMath.joinSegments([p], [])
        #expect(result.count == 1)
    }

    @Test func joinBothEmpty() {
        let result = RouteMath.joinSegments([], [])
        #expect(result.isEmpty)
    }

    @Test func joinNoDedupWhenFar() {
        let far = offset(p, north: 100.0)  // 100 m apart
        let result = RouteMath.joinSegments([p], [far])
        #expect(result.count == 2)
    }

    @Test func joinDedupAtSubMeterGap() {
        let near = offset(p, north: 0.5)  // 0.5 m apart, under default 2 m tolerance
        let result = RouteMath.joinSegments([p], [near])
        #expect(result.count == 1)
    }

    @Test func joinDedupExact() {
        let result = RouteMath.joinSegments([p], [p])
        #expect(result.count == 1)
    }

    @Test func joinPreservesInteriorAndOrder() {
        let mid = offset(p, north: 50.0)
        let end = offset(p, north: 100.0)
        let joinNear = offset(end, north: 0.3)  // joins within tolerance
        let next = offset(end, north: 60.0)
        let result = RouteMath.joinSegments([p, mid, end], [joinNear, next])
        // Expect: [p, mid, end, next] — joinNear dropped, interior + final preserved.
        #expect(result.count == 4)
        let lastLoc = CLLocation(latitude: result.last!.latitude, longitude: result.last!.longitude)
        let nextLoc = CLLocation(latitude: next.latitude, longitude: next.longitude)
        #expect(lastLoc.distance(from: nextLoc) < 0.01)
    }

    // MARK: - Polyline length

    @Test func totalLengthMatchesKnownTaipeiReference() {
        // Taipei 101 -> Taipei Main Station straight line: 5028.7 m by haversine,
        // the same reference CoordinateMathTests uses. A second 100 m leg north of
        // the station proves the total sums the legs rather than measuring the
        // end-to-end gap.
        let taipei101 = CLLocationCoordinate2D(latitude: 25.0339, longitude: 121.5645)
        let mainStation = CLLocationCoordinate2D(latitude: 25.0478, longitude: 121.5170)
        let legs = [taipei101, mainStation, offset(mainStation, north: 100)]
        #expect(abs(RouteMath.totalLengthMeters([taipei101, mainStation]) - 5028.7) < 50.3)
        #expect(abs(RouteMath.totalLengthMeters(legs) - (5028.7 + 100)) < 51.3)
    }

    @Test func totalLengthOfDegenerateInputIsZero() {
        #expect(RouteMath.totalLengthMeters([]) == 0)
        #expect(RouteMath.totalLengthMeters([p]) == 0)
        #expect(RouteMath.totalLengthMeters([p, p]) == 0)
    }
}
