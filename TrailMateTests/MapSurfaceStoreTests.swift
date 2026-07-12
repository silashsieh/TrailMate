import CoreLocation
import MapKit
import Testing
@testable import TrailMate

// Verifies the surface core's structural diffing: an unchanged model must not
// churn overlays/annotations, a route version bump rebuilds only that session's
// polyline, sessions add/remove their overlay + dot together, the telemetry
// seam moves a dot in place (stable identity) and toggles visibility on nil,
// and a selection flip re-emphasizes in place without recreating objects.
//
// `@MainActor` because the controller and `MKMapView` are main-actor bound; a
// real `MKMapView` is instantiated directly (fine in the macOS test host).
@MainActor
struct MapSurfaceStoreTests {
    // Taipei City Hall region — stable, valid coordinates.
    private func coord(_ lat: Double, _ lon: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func session(
        _ id: UUID,
        color: Int,
        selected: Bool,
        version: Int,
        coords: [CLLocationCoordinate2D]
    ) -> SessionRenderState {
        SessionRenderState(
            id: id,
            colorIndex: color,
            isSelected: selected,
            routeVersion: version,
            routeCoordinates: coords
        )
    }

    private var lineA: [CLLocationCoordinate2D] {
        [coord(25.033, 121.565), coord(25.034, 121.566)]
    }

    private var lineB: [CLLocationCoordinate2D] {
        [coord(25.040, 121.560), coord(25.041, 121.561)]
    }

    private func routePolyline(for id: UUID, in map: MKMapView) -> RoutePolyline? {
        map.overlays.compactMap { $0 as? RoutePolyline }.first { $0.sessionID == id }
    }

    private func dot(for id: UUID, in map: MKMapView) -> SessionDotAnnotation? {
        map.annotations.compactMap { $0 as? SessionDotAnnotation }.first { $0.sessionID == id }
    }

    private func approxEqual(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        abs(a.latitude - b.latitude) < 1e-9 && abs(a.longitude - b.longitude) < 1e-9
    }

    @Test func applyingSameModelTwiceDoesNotChurn() {
        let map = MKMapView()
        let controller = MapSurfaceController()
        let id = UUID()
        let model = MapSurfaceModel(
            sessions: [session(id, color: 0, selected: true, version: 1, coords: lineA)],
            markers: MapMarkers(
                from: coord(25.030, 121.564),
                to: coord(25.045, 121.567),
                stops: [MapMarkers.Stop(id: UUID(), number: 1, coordinate: coord(25.037, 121.565))]
            )
        )

        controller.apply(model, to: map)
        let overlaysBefore = Set(map.overlays.map { ObjectIdentifier($0) })
        let annotationsBefore = Set(map.annotations.map { ObjectIdentifier($0 as AnyObject) })

        controller.apply(model, to: map)
        let overlaysAfter = Set(map.overlays.map { ObjectIdentifier($0) })
        let annotationsAfter = Set(map.annotations.map { ObjectIdentifier($0 as AnyObject) })

        #expect(overlaysBefore == overlaysAfter)
        #expect(map.overlays.count == overlaysBefore.count)
        #expect(annotationsBefore == annotationsAfter)
        #expect(map.annotations.count == annotationsBefore.count)
    }

    @Test func bumpingRouteVersionReplacesOnlyThatSessionsPolyline() {
        let map = MKMapView()
        let controller = MapSurfaceController()
        let a = UUID()
        let b = UUID()

        controller.apply(
            MapSurfaceModel(sessions: [
                session(a, color: 0, selected: true, version: 1, coords: lineA),
                session(b, color: 1, selected: false, version: 1, coords: lineB),
            ]),
            to: map
        )
        let polyA1 = routePolyline(for: a, in: map)
        let polyB1 = routePolyline(for: b, in: map)
        #expect(polyA1 != nil)
        #expect(polyB1 != nil)

        let newCoordsA = [coord(25.033, 121.565), coord(25.0335, 121.5655), coord(25.034, 121.566)]
        controller.apply(
            MapSurfaceModel(sessions: [
                session(a, color: 0, selected: true, version: 2, coords: newCoordsA),
                session(b, color: 1, selected: false, version: 1, coords: lineB),
            ]),
            to: map
        )
        let polyA2 = routePolyline(for: a, in: map)
        let polyB2 = routePolyline(for: b, in: map)

        #expect(polyA2 !== polyA1)          // A's version changed → rebuilt
        #expect(polyA2?.pointCount == 3)    // ...with the new geometry
        #expect(polyB2 === polyB1)          // B untouched → identity stable
    }

    @Test func addingAndRemovingSessionUpdatesOverlaysAndDot() {
        let map = MKMapView()
        let controller = MapSurfaceController()
        let a = UUID()
        let b = UUID()

        controller.apply(
            MapSurfaceModel(sessions: [session(a, color: 0, selected: true, version: 1, coords: lineA)]),
            to: map
        )
        #expect(routePolyline(for: a, in: map) != nil)
        #expect(dot(for: a, in: map) != nil)
        let polyA = routePolyline(for: a, in: map)

        controller.apply(
            MapSurfaceModel(sessions: [
                session(a, color: 0, selected: true, version: 1, coords: lineA),
                session(b, color: 1, selected: false, version: 1, coords: lineB),
            ]),
            to: map
        )
        #expect(routePolyline(for: b, in: map) != nil)
        #expect(dot(for: b, in: map) != nil)
        #expect(routePolyline(for: a, in: map) === polyA)   // A unaffected by B's arrival

        controller.apply(
            MapSurfaceModel(sessions: [session(a, color: 0, selected: true, version: 1, coords: lineA)]),
            to: map
        )
        #expect(routePolyline(for: b, in: map) == nil)      // B's overlay removed
        #expect(dot(for: b, in: map) == nil)                // ...and its dot
        #expect(routePolyline(for: a, in: map) === polyA)   // A still stable
    }

    @Test func setDotCoordinateMovesInPlaceAndTogglesVisibility() {
        let map = MKMapView()
        let controller = MapSurfaceController()
        let a = UUID()
        controller.apply(
            MapSurfaceModel(sessions: [session(a, color: 0, selected: true, version: 1, coords: lineA)]),
            to: map
        )
        guard let dotA = dot(for: a, in: map) else {
            Issue.record("dot for session A was not created")
            return
        }
        #expect(dotA.hasPosition == false)      // hidden until a position arrives
        let annotationCount = map.annotations.count

        let first = coord(25.0330, 121.5654)
        controller.setDotCoordinate(sessionID: a, coordinate: first)
        #expect(dotA.hasPosition)
        #expect(approxEqual(dotA.coordinate, first))
        #expect(dot(for: a, in: map) === dotA)            // same object
        #expect(map.annotations.count == annotationCount) // no add/remove

        let second = coord(25.0340, 121.5664)
        controller.setDotCoordinate(sessionID: a, coordinate: second)
        #expect(approxEqual(dotA.coordinate, second))     // moved in place
        #expect(dot(for: a, in: map) === dotA)
        #expect(map.annotations.count == annotationCount)

        controller.setDotCoordinate(sessionID: a, coordinate: nil)
        #expect(dotA.hasPosition == false)                // visibility toggled off
        #expect(dot(for: a, in: map) === dotA)            // object identity survives nil
        #expect(map.annotations.count == annotationCount)
    }

    @Test func selectionFlipUpdatesEmphasisWithoutIdentityChange() {
        let map = MKMapView()
        let controller = MapSurfaceController()
        let a = UUID()

        controller.apply(
            MapSurfaceModel(sessions: [session(a, color: 0, selected: false, version: 1, coords: lineA)]),
            to: map
        )
        let poly1 = routePolyline(for: a, in: map)
        let dot1 = dot(for: a, in: map)
        #expect(poly1?.isSelected == false)
        #expect(dot1?.isSelected == false)

        controller.apply(
            MapSurfaceModel(sessions: [session(a, color: 0, selected: true, version: 1, coords: lineA)]),
            to: map
        )
        #expect(routePolyline(for: a, in: map) === poly1)  // identity stable
        #expect(dot(for: a, in: map) === dot1)
        #expect(poly1?.isSelected == true)                 // emphasis updated in place
        #expect(dot1?.isSelected == true)
    }

    // MARK: - Delegate paths (the controller is the MKMapViewDelegate)

    @Test func rendererStylesSelectedAndUnselectedRoutes() {
        let map = MKMapView()
        let controller = MapSurfaceController()
        let a = UUID(), b = UUID()
        controller.apply(
            MapSurfaceModel(sessions: [
                session(a, color: 0, selected: true, version: 1, coords: lineA),
                session(b, color: 1, selected: false, version: 1, coords: lineB),
            ]),
            to: map
        )
        guard let polyA = routePolyline(for: a, in: map),
              let polyB = routePolyline(for: b, in: map),
              let rA = controller.mapView(map, rendererFor: polyA) as? MKPolylineRenderer,
              let rB = controller.mapView(map, rendererFor: polyB) as? MKPolylineRenderer else {
            Issue.record("route renderers not produced")
            return
        }
        #expect(rA.lineWidth == 4)   // selected: thicker
        #expect(rB.lineWidth == 3)   // unselected: thinner
        // Selected is full-strength; unselected is dimmed to 0.7.
        #expect((rA.strokeColor?.alphaComponent ?? 0) > 0.95)
        #expect(abs((rB.strokeColor?.alphaComponent ?? 0) - 0.7) < 0.05)
    }

    @Test func rendererStylesTheDrawStroke() {
        let map = MKMapView()
        let controller = MapSurfaceController()
        let a = UUID()
        controller.apply(
            MapSurfaceModel(
                sessions: [session(a, color: 0, selected: true, version: 1, coords: lineA)],
                strokeCoordinates: [coord(25.033, 121.565), coord(25.034, 121.566), coord(25.035, 121.567)]
            ),
            to: map
        )
        guard let stroke = map.overlays.compactMap({ $0 as? StrokePolyline }).first,
              let renderer = controller.mapView(map, rendererFor: stroke) as? MKPolylineRenderer else {
            Issue.record("stroke renderer not produced")
            return
        }
        #expect(renderer.lineWidth == 3)
        #expect(renderer.lineDashPattern?.map(\.intValue) == [6, 4])   // orange dashed
    }

    @Test func dotViewKeepsFixedFrameAndMidpointAcrossSelectionFlip() {
        let map = MKMapView()
        let controller = MapSurfaceController()
        let a = UUID()
        controller.apply(
            MapSurfaceModel(sessions: [session(a, color: 0, selected: false, version: 1, coords: lineA)]),
            to: map
        )
        guard let dotA = dot(for: a, in: map),
              let view = controller.mapView(map, viewFor: dotA) as? SessionDotAnnotationView else {
            Issue.record("dot annotation view not produced")
            return
        }
        // Fixed size regardless of selection state.
        #expect(view.frame.width == 19)
        #expect(view.frame.height == 19)

        // Simulate MapKit having positioned the view at a non-zero origin, then
        // flip selection: the reconfigure must not reset the origin (which would
        // strand the dot at (0,0) with no coordinate change to reposition it).
        view.frame.origin = CGPoint(x: 100, y: 80)
        let midBefore = CGPoint(x: view.frame.midX, y: view.frame.midY)

        view.configure(color: .systemRed, isSelected: true)

        #expect(view.frame.width == 19)               // still fixed
        #expect(view.frame.midX == midBefore.x)       // origin/midpoint preserved
        #expect(view.frame.midY == midBefore.y)
    }

    // Review blocker (PR #69): switching the selected session while Follow is
    // engaged must recenter from the newest CACHED frame immediately — the new
    // session's stream may not tick for up to a cap interval, or ever if it is
    // idle.
    @Test func selectionSwitchHandsFollowTheCachedFrame() {
        let mapView = MKMapView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let controller = MapSurfaceController()
        controller.attach(to: mapView)
        let director = MapCameraDirector()
        director.attach(to: mapView)
        controller.cameraDirector = director

        let a = UUID(), b = UUID()
        let aCoord = coord(25.0330, 121.5654)
        let bCoord = coord(24.1477, 120.6736)   // Taichung — far from A

        // A selected and followed; both sessions have delivered frames.
        controller.apply(MapSurfaceModel(sessions: [
            session(a, color: 0, selected: true, version: 1, coords: []),
            session(b, color: 1, selected: false, version: 1, coords: []),
        ]), to: mapView)
        controller.consumeTelemetry(
            TelemetryFrame(coordinate: aCoord, progress: 0, elapsedDistance: 0,
                           routeDeviationMeters: 0, recordingPointCount: 0),
            sessionID: a
        )
        controller.consumeTelemetry(
            TelemetryFrame(coordinate: bCoord, progress: 0, elapsedDistance: 0,
                           routeDeviationMeters: 0, recordingPointCount: 0),
            sessionID: b
        )
        director.setFollowing(true)
        director.followTarget(moved: aCoord)   // engaged and centered on A

        // Switch selection to B: the camera must move to B's cached frame NOW,
        // without waiting for B's next telemetry frame.
        controller.apply(MapSurfaceModel(sessions: [
            session(a, color: 0, selected: false, version: 1, coords: []),
            session(b, color: 1, selected: true, version: 1, coords: []),
        ]), to: mapView)

        #expect(abs(mapView.region.center.latitude - bCoord.latitude) < 0.05,
                "camera did not hand off to the newly selected session's cached frame")
        #expect(abs(mapView.region.center.longitude - bCoord.longitude) < 0.05)
    }
}
