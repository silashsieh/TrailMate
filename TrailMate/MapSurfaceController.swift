import CoreLocation
import MapKit
import os

// The coordinator behind `MapSurface`: the single owner of the `MKMapView`'s
// content and its `MKMapViewDelegate`. It drives the map imperatively so a
// position update never evaluates a SwiftUI body (epic 037).
//
// It owns two stores and splits work by update frequency:
//   • `MapOverlayStore`    — routes, stroke, planning markers (structural)
//   • `MapAnnotationStore` — per-session dots (moved from the telemetry stream)
//
// `apply(_:to:)` reconciles the structural model; `setDotCoordinate` is the
// high-frequency seam the telemetry consumer calls to slide a dot in place.
//
// Seams for later work packages (deliberately not built here):
//   • WP4 `MapCameraDirector` reads `mapView` for imperative camera control and
//     adds region-change handling via a delegate extension in its own file.
//   • WP5 `MapGestureBridge` installs its recognizers on `mapView`.
// Both attach through the exposed `mapView`; no camera/gesture/telemetry types
// are referenced from here so those packages compile against this as-is.
@MainActor
final class MapSurfaceController: NSObject, MKMapViewDelegate {
    private let overlayStore = MapOverlayStore()
    private let annotationStore = MapAnnotationStore()

    private let log = Logger(subsystem: "com.harry.trailmate", category: "MapSurface")

    // The map this controller drives. Set when the representable creates the
    // view and on every `apply`. Weak: the view's lifetime is SwiftUI's.
    private(set) weak var mapView: MKMapView?

    // The camera owner (WP4). The controller owns the `MKMapViewDelegate`, so it
    // forwards the region-change callbacks the director needs for persistence and
    // follow-disengage detection. Weak: the director's lifetime is WP6's. Left
    // nil until wired at integration, so the surface core stands alone.
    weak var cameraDirector: MapCameraDirector?

    // MARK: - Attachment

    func attach(to mapView: MKMapView) {
        self.mapView = mapView
    }

    // MARK: - Structural apply

    func apply(_ model: MapSurfaceModel, to mapView: MKMapView) {
        self.mapView = mapView
        overlayStore.apply(model, to: mapView)
        annotationStore.apply(model.sessions, to: mapView)
    }

    // MARK: - Telemetry seam

    // Slide one session's dot to a new position, or hide it (nil). Called off
    // the telemetry stream, outside `apply`, so it uses the retained `mapView`.
    func setDotCoordinate(sessionID: UUID, coordinate: CLLocationCoordinate2D?) {
        guard let mapView else { return }
        annotationStore.setDotCoordinate(sessionID: sessionID, coordinate: coordinate, in: mapView)
    }

    // MARK: - MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
        if let renderer = overlayStore.renderer(for: overlay) {
            return renderer
        }
        log.warning("No renderer for overlay of type \(String(describing: type(of: overlay)), privacy: .public)")
        return MKOverlayRenderer(overlay: overlay)
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
        // Dots first (the common case), then planning markers. Anything else
        // (e.g. the user-location annotation) falls through to MapKit's default.
        if let view = annotationStore.view(for: annotation, in: mapView) {
            return view
        }
        return overlayStore.view(for: annotation, in: mapView)
    }

    // Region-change callbacks are forwarded to the camera director (WP4), which
    // uses them for its programmatic-move token accounting, follow-disengage
    // detection, and region persistence. No-ops until a director is wired.
    func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
        cameraDirector?.regionWillChange(animated: animated)
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        cameraDirector?.regionDidChange(animated: animated)
    }
}
