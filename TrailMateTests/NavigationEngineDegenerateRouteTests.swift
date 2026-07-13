import CoreLocation
import Testing
@testable import TrailMate

// High 2 (PR #69 second review): one-point and zero-length routes flipped to
// `.idle` INSIDE tick() after play() had entered `.playing` — an internal
// transition nothing published — and an EMPTY route trapped in loadRoute's
// cumulative-distance loop. Degenerate routes must never enter `.playing`, and
// loading them must be safe.
struct NavigationEngineDegenerateRouteTests {

    private func coord(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    @Test func emptyRouteLoadsSafelyAndNeverPlays() {
        let nav = NavigationEngine()
        nav.loadRoute(coordinates: [], baseSpeed: 5)   // must not trap (1..<0)
        #expect(nav.isPlayable == false)
        nav.play(multiplier: 1)
        #expect(nav.playbackState == .idle)
        #expect(nav.tick(dt: 0.1) == nil)
    }

    @Test func onePointRouteNeverPlays() {
        let nav = NavigationEngine()
        nav.loadRoute(coordinates: [coord(25.0, 121.0)], baseSpeed: 5)
        #expect(nav.isPlayable == false)
        nav.play(multiplier: 1)
        #expect(nav.playbackState == .idle)
    }

    @Test func zeroLengthRouteNeverPlays() {
        let nav = NavigationEngine()
        let p = coord(25.0, 121.0)
        nav.loadRoute(coordinates: [p, p], baseSpeed: 5)
        #expect(nav.totalDistance == 0)
        #expect(nav.isPlayable == false)
        nav.play(multiplier: 1)
        #expect(nav.playbackState == .idle)
    }

    @Test func validRouteStillPlays() {
        let nav = NavigationEngine()
        nav.loadRoute(coordinates: [coord(25.0, 121.0), coord(25.001, 121.0)], baseSpeed: 5)
        #expect(nav.isPlayable == true)
        nav.play(multiplier: 1)
        #expect(nav.playbackState == .playing)
        #expect(nav.tick(dt: 0.1) != nil)
    }
}
