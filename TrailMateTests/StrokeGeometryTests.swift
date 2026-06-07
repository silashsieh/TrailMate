import CoreLocation
import Testing
@testable import TrailMate

struct StrokeGeometryTests {
    // Taipei City Hall, used as a stable reference point.
    private let p = CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654)

    private func offset(_ base: CLLocationCoordinate2D, north: Double = 0, east: Double = 0) -> CLLocationCoordinate2D {
        // ~111_320 m per degree of latitude; longitude scaled by cos(lat).
        CLLocationCoordinate2D(
            latitude: base.latitude + north / 111_320.0,
            longitude: base.longitude + east / (111_320.0 * cos(base.latitude * .pi / 180))
        )
    }

    private func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    private func totalLength(_ pts: [CLLocationCoordinate2D]) -> Double {
        zip(pts, pts.dropFirst()).reduce(0) { $0 + meters($1.0, $1.1) }
    }

    // MARK: - chaikin

    @Test func chaikinPreservesEndpoints() {
        let pts = [p, offset(p, north: 50, east: 30), offset(p, north: 100)]
        let smoothed = StrokeGeometry.chaikin(pts, iterations: 2)
        #expect(meters(smoothed.first!, pts.first!) < 0.01)
        #expect(meters(smoothed.last!, pts.last!) < 0.01)
    }

    @Test func chaikinKnownCutPoints() {
        // Right angle: 100 m north, then 100 m east. One pass cuts each
        // segment at its 1/4 and 3/4 marks, so the corner vertex disappears
        // and the known-good cut points are 25 N, 75 N, (100 N, 25 E),
        // (100 N, 75 E).
        let corner = offset(p, north: 100)
        let end = offset(corner, east: 100)
        let out = StrokeGeometry.chaikin([p, corner, end], iterations: 1)

        #expect(out.count == 6)
        #expect(meters(out[1], offset(p, north: 25)) < 0.5)
        #expect(meters(out[2], offset(p, north: 75)) < 0.5)
        #expect(meters(out[3], offset(p, north: 100, east: 25)) < 0.5)
        #expect(meters(out[4], offset(p, north: 100, east: 75)) < 0.5)
        // The sharp corner itself is cut: nothing lands on it.
        for vertex in out {
            #expect(meters(vertex, corner) > 20)
        }
    }

    @Test func chaikinLeavesTwoPointStrokeAlone() {
        let pts = [p, offset(p, north: 100)]
        #expect(StrokeGeometry.chaikin(pts, iterations: 2).count == 2)
    }

    // MARK: - resampleUniform

    @Test func resampleUniformSpacingAndEndpoints() throws {
        // ~100 m straight line at 10 m spacing: start + 9 interior samples
        // + exact endpoint, every gap ≈ spacing.
        let end = offset(p, north: 100)
        let out = StrokeGeometry.resampleUniform([p, end], spacingMeters: 10)
        let pts = try #require(out)

        #expect(pts.count == 11)
        #expect(meters(pts.first!, p) < 0.01)
        #expect(meters(pts.last!, end) < 0.01)
        for (a, b) in zip(pts.dropLast(2), pts.dropFirst().dropLast()) {
            #expect(abs(meters(a, b) - 10) < 0.2)
        }
    }

    @Test func resampleEvensOutUnevenSampling() throws {
        // Wildly uneven input vertices along one line — output is uniform
        // regardless of where the input happened to be sampled.
        let pts = [p,
                   offset(p, north: 1),
                   offset(p, north: 2.5),
                   offset(p, north: 80),
                   offset(p, north: 100)]
        let out = try #require(StrokeGeometry.resampleUniform(pts, spacingMeters: 10))
        #expect(out.count == 11)
        for (a, b) in zip(out.dropLast(2), out.dropFirst().dropLast()) {
            #expect(abs(meters(a, b) - 10) < 0.2)
        }
    }

    @Test func resamplePreservesArcLength() throws {
        // L-shaped path, ~200 m total. Resampling can only cut the corner, so
        // length is preserved within a small tolerance.
        let corner = offset(p, north: 100)
        let end = offset(corner, east: 100)
        let original = totalLength([p, corner, end])
        let out = try #require(StrokeGeometry.resampleUniform([p, corner, end], spacingMeters: 5))
        #expect(abs(totalLength(out) - original) / original < 0.02)
    }

    @Test func resampleRejectsAllCoincidentPoints() {
        #expect(StrokeGeometry.resampleUniform([p, p, p, p], spacingMeters: 2) == nil)
    }

    @Test func resampleRejectsStrokeShorterThanOneSpacing() {
        let out = StrokeGeometry.resampleUniform([p, offset(p, north: 1)], spacingMeters: 2)
        #expect(out == nil)
    }

    @Test func resampleRejectsJitterBlob() {
        // ~2.4 m of arc length crammed inside a 0.3 m blob: enough total
        // distance to pass the length gate, but nothing ever escapes
        // minSeparation of the start — not a route.
        let up = offset(p, north: 0.3)
        let blob = [p, up, p, up, p, up, p, up, p]
        #expect(StrokeGeometry.resampleUniform(blob, spacingMeters: 2) == nil)
    }

    @Test func resampleSwitchbackEmitsNoDegenerateSegments() throws {
        // Out 25 m and back past the start: samples a full spacing apart in
        // arc length fold onto the same spot at the turnaround. The contract
        // NavigationEngine relies on: no consecutive output vertices closer
        // than minSeparationMeters (bar the swapped-in exact endpoint, which
        // is merely strictly positive).
        let out25 = offset(p, north: 25)
        let back = offset(p, north: -10)
        let pts = try #require(StrokeGeometry.resampleUniform([p, out25, back], spacingMeters: 10))
        for (a, b) in zip(pts.dropLast(), pts.dropFirst()) {
            #expect(meters(a, b) > 0)
        }
        for (a, b) in zip(pts.dropLast(2), pts.dropFirst().dropLast()) {
            #expect(meters(a, b) >= StrokeGeometry.minSeparationMeters - 0.001)
        }
        #expect(meters(pts.last!, back) < 0.01)
    }

    // MARK: - spacing(forSpeedMPS:)

    @Test func spacingTracksSpeedWithClamps() {
        #expect(StrokeGeometry.spacing(forSpeedMPS: 5.0 / 3.6) == 2.0)            // walk hits the floor
        let cycle = 15.0 / 3.6
        #expect(abs(StrokeGeometry.spacing(forSpeedMPS: cycle) - cycle) < 0.001)  // cycle ≈ speed × 1 s
        #expect(StrokeGeometry.spacing(forSpeedMPS: 50) == 15.0)                  // fast custom hits the cap
    }
}
