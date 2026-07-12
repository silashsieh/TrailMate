import CoreLocation
import MapKit
import Testing
@testable import TrailMate

// Verifies the imperative camera director (epic 037, WP4): the programmatic-move
// token guard (our own moves — including across an animated focus — never read
// as user gestures), user-gesture follow-disengage via the delegate-forwarded
// `regionWillChange`, follow-span preservation on a follow recenter, focus
// disengaging follow, and the follow-span refresh on a settled region.
//
// `@MainActor` because the director and `MKMapView` are main-actor bound; a real
// `MKMapView` with a nonzero frame is instantiated directly (fine in the macOS
// test host, matching `MapSurfaceStoreTests`). Callbacks MapKit would deliver
// asynchronously are driven synchronously through the director's forwarding
// methods so the token accounting is exercised deterministically.
@MainActor
struct MapCameraDirectorTests {
    // A laid-out map: region math and point conversion need a nonzero frame.
    private func makeMapView() -> MKMapView {
        MKMapView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
    }

    private func coord(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // Simulate the will/did pair MapKit delivers for one settled camera move.
    private func settle(_ director: MapCameraDirector, animated: Bool) {
        director.regionWillChange(animated: animated)
        director.regionDidChange(animated: animated)
    }

    // MARK: - Token guard

    @Test("Director-initiated moves never disengage follow, even across an animated focus")
    func directorMovesDoNotDisengageFollow() {
        let mapView = makeMapView()
        let director = MapCameraDirector()
        director.attach(to: mapView)

        var disengageCount = 0
        director.onFollowDisengaged = { disengageCount += 1 }

        // Engage → an animated first recenter; its will/did carry a token.
        director.setFollowing(true)
        director.followTarget(moved: coord(25.05, 121.55))
        settle(director, animated: true)
        #expect(director.isFollowing)

        // A steady, unanimated recenter far from center; token-covered too.
        director.followTarget(moved: coord(25.20, 121.80))
        settle(director, animated: false)
        #expect(director.isFollowing)

        // An animated focus is programmatic: its will/did must not read as a
        // gesture. Focus ends follow deliberately, but silently — not via the
        // user-gesture callback.
        director.setFollowing(true)
        director.focus(on: MKCoordinateRegion(center: coord(24.9, 121.4),
                                              span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)))
        settle(director, animated: true)

        // Re-engage and move again: the counter stayed balanced across the
        // animated focus, so this is still recognized as our own move.
        director.setFollowing(true)
        director.followTarget(moved: coord(25.30, 121.90))
        settle(director, animated: true)
        director.followTarget(moved: coord(25.40, 122.00))
        settle(director, animated: false)
        #expect(director.isFollowing)

        #expect(disengageCount == 0)
    }

    // MARK: - User-gesture disengage (delegate-forwarded)

    @Test("A region-will-change with no outstanding token disengages follow and fires the callback")
    func userGestureDisengagesFollow() {
        let mapView = makeMapView()
        let director = MapCameraDirector()
        director.attach(to: mapView)

        var disengageCount = 0
        director.onFollowDisengaged = { disengageCount += 1 }

        director.setFollowing(true)
        #expect(director.isFollowing)

        // No programmatic move issued ⇒ zero tokens ⇒ this will-change is the
        // user grabbing the map.
        director.regionWillChange(animated: false)

        #expect(!director.isFollowing)
        #expect(disengageCount == 1)
    }

    @Test("The user-gesture disengage path is reached through MapSurfaceController's delegate forwarding")
    func controllerForwardsRegionWillChange() {
        let mapView = makeMapView()
        let controller = MapSurfaceController()
        controller.attach(to: mapView)

        let director = MapCameraDirector()
        director.attach(to: mapView)
        controller.cameraDirector = director

        var disengageCount = 0
        director.onFollowDisengaged = { disengageCount += 1 }
        director.setFollowing(true)

        // Invoke the delegate method exactly as MapKit would.
        controller.mapView(mapView, regionWillChangeAnimated: false)

        #expect(!director.isFollowing)
        #expect(disengageCount == 1)
    }

    // MARK: - Follow-span preservation

    @Test("A follow recenter preserves the follow-span and recenters on the target")
    func followTargetPreservesFollowSpan() {
        let mapView = makeMapView()
        let director = MapCameraDirector()
        director.attach(to: mapView)

        // `followTarget` itself never writes `followSpan` — only a settle does —
        // so the span is invariant across engage + steady recenters.
        let spanBefore = director.followSpan
        director.setFollowing(true)
        director.followTarget(moved: coord(25.05, 121.55))   // engage (animated)
        let target = coord(25.30, 121.90)
        director.followTarget(moved: target)                 // steady (unanimated, synchronous)

        #expect(director.followSpan.latitudeDelta == spanBefore.latitudeDelta)
        #expect(director.followSpan.longitudeDelta == spanBefore.longitudeDelta)

        // The unanimated steady move applies synchronously: the camera is now
        // centered on the target, at the follow zoom (within MapKit's snap).
        #expect(abs(mapView.region.center.latitude - target.latitude) < 0.05)
        #expect(abs(mapView.region.center.longitude - target.longitude) < 0.05)
        #expect(abs(mapView.region.span.latitudeDelta - spanBefore.latitudeDelta) < spanBefore.latitudeDelta)
    }

    // MARK: - Focus

    @Test("Focus disengages follow (programmatically, not via the gesture callback)")
    func focusDisengagesFollow() {
        let mapView = makeMapView()
        let director = MapCameraDirector()
        director.attach(to: mapView)

        var disengageCount = 0
        director.onFollowDisengaged = { disengageCount += 1 }

        director.setFollowing(true)
        #expect(director.isFollowing)

        director.focus(on: MKCoordinateRegion(center: coord(24.9, 121.4),
                                              span: MKCoordinateSpan(latitudeDelta: 0.2, longitudeDelta: 0.2)))

        #expect(!director.isFollowing)
        #expect(disengageCount == 0)   // programmatic, not a user gesture
    }

    // MARK: - Persistence / follow-span refresh on settle

    // MapCameraPersistence writes to `UserDefaults.standard` and offers no
    // injection seam, so (per WP4's brief) the settle behavior is verified via
    // the observable `followSpan` refresh rather than the persisted value.
    @Test("A settled region refreshes the follow-span from the map")
    func regionDidChangeRefreshesFollowSpan() {
        let mapView = makeMapView()
        let director = MapCameraDirector()
        director.attach(to: mapView)

        // A user zooms out to a distinctly larger region (no token outstanding).
        mapView.setRegion(MKCoordinateRegion(center: coord(25.033, 121.565),
                                             span: MKCoordinateSpan(latitudeDelta: 0.4, longitudeDelta: 0.4)),
                          animated: false)
        let mapSpan = mapView.region.span
        director.regionDidChange(animated: false)

        // The director adopts the settled span verbatim.
        #expect(director.followSpan.latitudeDelta == mapSpan.latitudeDelta)
        #expect(director.followSpan.longitudeDelta == mapSpan.longitudeDelta)
        // And it is the large, zoomed-out span, not the initial attach span.
        #expect(director.followSpan.latitudeDelta > 0.2)
    }

    // MARK: - User-input arbitration (review blocker, PR #69)

    // A REAL user pan that overlaps an in-flight programmatic animation arrives
    // while our token is still outstanding. The live-input probe must win over
    // the token so the gesture disengages follow instead of being swallowed.
    @Test("A live user input disengages follow even with a programmatic move in flight")
    func liveUserInputBeatsOutstandingToken() {
        let mapView = makeMapView()
        let director = MapCameraDirector()
        director.attach(to: mapView)

        var disengaged = 0
        director.onFollowDisengaged = { disengaged += 1 }

        director.setFollowing(true)
        director.followTarget(moved: coord(25.05, 121.55))   // animated engage → token outstanding

        // The user grabs the map mid-animation: a live camera-input event is
        // being dispatched at willChange time.
        director.userCameraInputProbe = { true }
        director.regionWillChange(animated: true)

        #expect(director.isFollowing == false)
        #expect(disengaged == 1)
    }

    @Test("Without live user input, an in-flight programmatic move still never disengages")
    func programmaticMoveWithoutLiveInputStaysFollowing() {
        let mapView = makeMapView()
        let director = MapCameraDirector()
        director.attach(to: mapView)

        var disengaged = 0
        director.onFollowDisengaged = { disengaged += 1 }

        director.setFollowing(true)
        director.followTarget(moved: coord(25.05, 121.55))   // token outstanding

        director.userCameraInputProbe = { false }
        director.regionWillChange(animated: true)            // our own callback

        #expect(director.isFollowing == true)
        #expect(disengaged == 0)
    }
}
