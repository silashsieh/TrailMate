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
                stops: [MapMarkers.Stop(id: UUID(), coordinate: coord(25.037, 121.565))]
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
}
