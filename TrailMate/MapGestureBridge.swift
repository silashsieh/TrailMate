import AppKit
import CoreLocation
import MapKit
import os

// Installs TrailMate's three map interactions — long-press, right-click, and the
// freehand draw stroke — as AppKit gesture recognizers on a passed-in `MKMapView`,
// coexisting with MapKit's own pan/zoom. It only *reports* gestures (as coordinates
// and phases); what to do with them — teleport, present a menu, feed the stroke
// pipeline — is the integration layer's decision (WP6).
//
// Why AppKit recognizers and not SwiftUI gestures (the y-flip trap, per the 037
// gesture spike): macOS `MKMapView` is not flipped (origin bottom-left, y-up),
// while SwiftUI's `.local` space is top-left, y-down. A SwiftUI-sourced point fed
// to `convert(_:toCoordinateFrom:)` must be y-flipped first. Capturing points with
// `recognizer.location(in: mapView)` — always in the map view's own coordinate
// system — sidesteps the flip entirely, so every coordinate here is converted
// without any manual adjustment.
//
// Arbitration (epic 037 Decisions / spike findings): all recognizers share this
// object as their delegate and only implement
// `shouldRecognizeSimultaneouslyWith → true`; no `require(toFail:)` chains. Draw
// mode toggles `mapView.isScrollEnabled` to suppress the map's own pan while a
// stroke owns the drag, leaving `isZoomEnabled` untouched so pinch / zoom controls
// stay live.
@MainActor
final class MapGestureBridge: NSObject, NSGestureRecognizerDelegate {
    // Delivered on the draw recognizer's pan phases. The raw screen `NSPoint` is
    // carried alongside the converted coordinate so the integration layer can keep
    // today's screen-space jitter decimation (ContentView's `lastStrokePoint`,
    // < 3 pt = jitter) and feed the coordinates straight into the existing
    // `StrokeGeometry` pipeline unchanged.
    enum StrokePhase {
        case began(NSPoint, CLLocationCoordinate2D)
        case changed(NSPoint, CLLocationCoordinate2D)
        case ended       // commit the stroke
        case cancelled   // discard — recognizer cancelled/failed, no route
    }

    // Long-press release → coordinate (matches today's 0.5 s long-press).
    var onLongPress: ((CLLocationCoordinate2D) -> Void)?
    // Right-click → coordinate + the click point in the map's coordinate system,
    // both fresh at click time (menu presentation is the caller's choice).
    var onRightClick: ((_ coordinate: CLLocationCoordinate2D, _ locationInMap: NSPoint) -> Void)?
    // Freehand stroke phases (only fires while draw mode is enabled).
    var onStroke: ((StrokePhase) -> Void)?

    // Weak for the same reason `MapSurfaceController` holds it weak: the view's
    // lifetime is SwiftUI's. A recognizer only fires while attached to a live map,
    // and `setDrawMode` is only called while the surface is on screen.
    private(set) weak var mapView: MKMapView?

    private var longPress: NSPressGestureRecognizer?
    private var rightClick: NSClickGestureRecognizer?
    private var draw: NSPanGestureRecognizer?

    private let log = Logger(subsystem: "com.harry.trailmate", category: "MapGesture")

    // MARK: - Attachment

    func attach(to mapView: MKMapView) {
        // Idempotent: tear down any prior install before re-attaching.
        detach()
        self.mapView = mapView

        let longPress = NSPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        longPress.buttonMask = 0x1   // primary/left
        longPress.delegate = self
        mapView.addGestureRecognizer(longPress)
        self.longPress = longPress

        let rightClick = NSClickGestureRecognizer(target: self, action: #selector(handleRightClick(_:)))
        rightClick.buttonMask = 0x2  // secondary/right
        rightClick.delegate = self
        mapView.addGestureRecognizer(rightClick)
        self.rightClick = rightClick

        let draw = NSPanGestureRecognizer(target: self, action: #selector(handleDraw(_:)))
        draw.buttonMask = 0x1        // primary/left
        draw.delegate = self
        draw.isEnabled = false       // off until draw mode is entered
        mapView.addGestureRecognizer(draw)
        self.draw = draw
    }

    // Enter/exit draw mode. Enabling the pan recognizer and suppressing the map's
    // own scroll (pan) is the spike's chosen arbitration — one documented line,
    // cleaner than force-failing MKMapView's unlabelled internal pan recognizer.
    // Zoom stays live throughout (`isZoomEnabled` untouched).
    func setDrawMode(_ enabled: Bool) {
        draw?.isEnabled = enabled
        // Suppress every non-draw interaction while a stroke owns the drag —
        // matching today's `interactionModes: .zoom` (zoom only). The map's own
        // pan, our long-press, our right-click menu, and rotate/pitch all go
        // quiet so a slow stroke can't trigger long-press or the context menu and
        // the camera holds still; `isZoomEnabled` is untouched, so zoom stays live.
        longPress?.isEnabled = !enabled
        rightClick?.isEnabled = !enabled
        mapView?.isScrollEnabled = !enabled
        mapView?.isRotateEnabled = !enabled
        mapView?.isPitchEnabled = !enabled
        log.debug("draw mode \(enabled ? "ON" : "OFF", privacy: .public) — isScrollEnabled=\(!enabled)")
    }

    // Remove every recognizer and restore normal map interaction. Safe to call
    // repeatedly and before any attach.
    func detach() {
        if let mapView {
            for recognizer in [longPress, rightClick, draw].compactMap({ $0 }) {
                mapView.removeGestureRecognizer(recognizer)
            }
            // Leave the map fully interactive if we tore down mid-draw.
            mapView.isScrollEnabled = true
            mapView.isRotateEnabled = true
            mapView.isPitchEnabled = true
        }
        longPress = nil
        rightClick = nil
        draw = nil
        mapView = nil
    }

    // MARK: - Recognizer actions

    @objc private func handleLongPress(_ recognizer: NSPressGestureRecognizer) {
        // Report on release only, matching today's on-ended long-press. A press
        // that travels past `allowableMovement` fails into pan and never ends here.
        guard recognizer.state == .ended, let mapView else { return }
        let point = recognizer.location(in: mapView)
        onLongPress?(mapView.convert(point, toCoordinateFrom: mapView))
    }

    @objc private func handleRightClick(_ recognizer: NSClickGestureRecognizer) {
        guard let mapView else { return }
        // Convert at click time so the reported coordinate is never stale (the
        // camera can't move between the click and this synchronous callback).
        let point = recognizer.location(in: mapView)
        onRightClick?(mapView.convert(point, toCoordinateFrom: mapView), point)
    }

    @objc private func handleDraw(_ recognizer: NSPanGestureRecognizer) {
        guard let mapView else { return }
        switch recognizer.state {
        case .began:
            // NSPan only begins after a small hysteresis, so `location(in:)` has
            // already moved off the mouse-down point (SwiftUI's DragGesture(0)
            // started AT mouse-down). Recover the true origin by subtracting the
            // accumulated translation and deliver it as the stroke's first point.
            let current = recognizer.location(in: mapView)
            let translation = recognizer.translation(in: mapView)
            let origin = NSPoint(x: current.x - translation.x, y: current.y - translation.y)
            onStroke?(.began(origin, mapView.convert(origin, toCoordinateFrom: mapView)))
        case .changed:
            let point = recognizer.location(in: mapView)
            onStroke?(.changed(point, mapView.convert(point, toCoordinateFrom: mapView)))
        case .ended:
            onStroke?(.ended)          // commit
        case .cancelled, .failed:
            onStroke?(.cancelled)      // discard — no route from a cancelled drag
        default:
            break
        }
    }

    // MARK: - NSGestureRecognizerDelegate

    // Let our three recognizers run alongside MKMapView's internal pan/zoom/magnify
    // recognizers rather than mutually excluding them (spike decision — no
    // `require(toFail:)`/`shouldBeRequiredToFail` relationships are needed).
    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
    ) -> Bool {
        true
    }
}
