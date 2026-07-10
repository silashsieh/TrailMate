import AppKit
import CoreLocation
import MapKit
import Testing
@testable import TrailMate

// Headless coverage for the gesture bridge. What's testable without synthesizing
// real mouse events (deemed flaky by the 037 spike): that `attach` installs
// exactly the expected recognizers with the right buttonMasks / press duration /
// initial draw-disabled state; that `setDrawMode` toggles the pan recognizer and
// `isScrollEnabled` while `isZoomEnabled` stays true; that `detach` removes them;
// and the spike's recommended regression seam — the map-local→coordinate
// conversion path the bridge relies on lands on the region center.
//
// `@MainActor` because the bridge and `MKMapView` are main-actor bound; a real
// `MKMapView` is instantiated directly (fine in the macOS test host).
@MainActor
struct MapGestureBridgeTests {
    // The recognizers the bridge just added, isolated from MKMapView's own
    // built-in pan/zoom/magnify recognizers by diffing before vs after attach.
    private func addedRecognizers(
        by attach: (MKMapView) -> Void,
        on mapView: MKMapView
    ) -> [NSGestureRecognizer] {
        let before = Set((mapView.gestureRecognizers).map(ObjectIdentifier.init))
        attach(mapView)
        return mapView.gestureRecognizers.filter { !before.contains(ObjectIdentifier($0)) }
    }

    @Test func attachInstallsExpectedRecognizers() {
        let mapView = MKMapView()
        let bridge = MapGestureBridge()
        let added = addedRecognizers(by: { bridge.attach(to: $0) }, on: mapView)

        #expect(added.count == 3)

        let presses = added.compactMap { $0 as? NSPressGestureRecognizer }
        #expect(presses.count == 1)
        #expect(presses.first?.minimumPressDuration == 0.5)
        #expect(presses.first?.buttonMask == 0x1)

        let clicks = added.compactMap { $0 as? NSClickGestureRecognizer }
        #expect(clicks.count == 1)
        #expect(clicks.first?.buttonMask == 0x2)

        let pans = added.compactMap { $0 as? NSPanGestureRecognizer }
        #expect(pans.count == 1)
        #expect(pans.first?.buttonMask == 0x1)
        #expect(pans.first?.isEnabled == false)   // draw off until setDrawMode(true)

        // Every recognizer shares the bridge as its delegate (the arbitration seam).
        #expect(added.allSatisfy { $0.delegate === bridge })
    }

    @Test func setDrawModeTogglesPanAndScrollButNeverZoom() {
        let mapView = MKMapView()
        let bridge = MapGestureBridge()
        let added = addedRecognizers(by: { bridge.attach(to: $0) }, on: mapView)
        guard let pan = added.compactMap({ $0 as? NSPanGestureRecognizer }).first,
              let press = added.compactMap({ $0 as? NSPressGestureRecognizer }).first,
              let click = added.compactMap({ $0 as? NSClickGestureRecognizer }).first else {
            Issue.record("draw recognizers were not installed")
            return
        }

        bridge.setDrawMode(true)
        #expect(pan.isEnabled == true)
        #expect(press.isEnabled == false)            // long-press can't fire mid-stroke
        #expect(click.isEnabled == false)            // right-click menu suppressed
        #expect(mapView.isScrollEnabled == false)    // map's own pan suppressed
        #expect(mapView.isRotateEnabled == false)    // draw mode is zoom-only…
        #expect(mapView.isPitchEnabled == false)
        #expect(mapView.isZoomEnabled == true)       // …so zoom stays live while drawing

        bridge.setDrawMode(false)
        #expect(pan.isEnabled == false)
        #expect(press.isEnabled == true)             // all non-draw interaction restored
        #expect(click.isEnabled == true)
        #expect(mapView.isScrollEnabled == true)
        #expect(mapView.isRotateEnabled == true)
        #expect(mapView.isPitchEnabled == true)
        #expect(mapView.isZoomEnabled == true)
    }

    @Test func detachRemovesRecognizersAndRestoresScroll() {
        let mapView = MKMapView()
        let bridge = MapGestureBridge()
        let added = addedRecognizers(by: { bridge.attach(to: $0) }, on: mapView)
        let addedIDs = Set(added.map(ObjectIdentifier.init))

        bridge.setDrawMode(true)   // leave the map mid-draw...
        bridge.detach()

        let remaining = Set(mapView.gestureRecognizers.map(ObjectIdentifier.init))
        #expect(remaining.isDisjoint(with: addedIDs))   // all three gone
        #expect(mapView.isScrollEnabled == true)         // ...and scroll restored
        #expect(bridge.mapView == nil)
    }

    @Test func detachBeforeAttachIsSafe() {
        let bridge = MapGestureBridge()
        bridge.detach()   // must not crash with no map attached
        #expect(bridge.mapView == nil)
    }

    // The spike's recommended conversion regression seam: on a laid-out map with a
    // known region, converting the view's center point must land on the region
    // center. Robust to the y-flip trap precisely because the center is invariant
    // under a vertical flip. This exercises the exact primitive the bridge calls
    // (`convert(_:toCoordinateFrom:)` with a `location(in:)`-style point).
    @Test func viewCenterConvertsToRegionCenter() {
        let mapView = MKMapView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let center = CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654)
        mapView.setRegion(
            MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
            ),
            animated: false
        )
        mapView.layoutSubtreeIfNeeded()

        let centerPoint = NSPoint(x: mapView.bounds.midX, y: mapView.bounds.midY)
        let converted = mapView.convert(centerPoint, toCoordinateFrom: mapView)

        #expect(abs(converted.latitude - center.latitude) < 1e-3)
        #expect(abs(converted.longitude - center.longitude) < 1e-3)
    }
}
