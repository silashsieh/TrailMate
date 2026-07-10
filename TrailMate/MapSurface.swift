import AppKit
import MapKit
import SwiftUI

// The SwiftUI bridge to the imperative map. It hosts one `MKMapView` (created
// once) and forwards the *structural* model to `MapSurfaceController`, which
// owns all content and delegate behavior. Body inputs are structural only:
// the live simulated position never passes through here — it reaches the dot
// via the controller's telemetry seam — so a moving dot triggers no SwiftUI
// update (epic 037's load-bearing property).
//
// The long-lived collaborators (camera director, gesture bridge) are owned by
// the caller (MapArea's @State) and injected here; `makeNSView` attaches them to
// the one `MKMapView` and wires the controller's telemetry fan-out. This view
// stays a thin conduit — it holds no per-tick state and observes nothing that
// changes at telemetry rate.
struct MapSurface: NSViewRepresentable {
    var model: MapSurfaceModel

    // Long-lived collaborators owned by the caller (MapArea), attached here.
    var director: MapCameraDirector
    var bridge: MapGestureBridge

    // Injected per-session telemetry subscription (frozen contract §2): the
    // controller resolves streams through this, so it never imports `AppState`.
    var telemetryStream: (UUID) -> AsyncStream<TelemetryFrame>

    // Mirror the caller's follow-button state when follow disengages by a path
    // the SwiftUI layer can't see itself — a user camera gesture inside the map,
    // or the selected session's position clearing.
    var onFollowMirror: (Bool) -> Void

    // Gesture actions (WP5 → integration): long-press coordinate, right-click
    // (coordinate + click point for menu placement), freehand stroke phases.
    var onLongPress: (CLLocationCoordinate2D) -> Void
    var onRightClick: (CLLocationCoordinate2D, NSPoint) -> Void
    var onStroke: (MapGestureBridge.StrokePhase) -> Void

    func makeCoordinator() -> MapSurfaceController {
        MapSurfaceController()
    }

    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator

        // `.realistic` elevation for parity with today's `.mapStyle(.standard(elevation:))`;
        // the compass + zoom controls mirror the SwiftUI `MapCompass`/`MapZoomStepper`.
        mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic)
        mapView.showsCompass = true
        mapView.showsZoomControls = true

        let controller = context.coordinator
        controller.attach(to: mapView)
        controller.cameraDirector = director
        director.attach(to: mapView)
        bridge.attach(to: mapView)

        wire(controller)
        controller.apply(model, to: mapView)
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        let controller = context.coordinator
        wire(controller)
        controller.apply(model, to: mapView)
    }

    // Cancel the telemetry consumers when the surface is permanently removed. The
    // recognizers go away with the map view; the tasks must be cancelled by hand.
    static func dismantleNSView(_ nsView: MKMapView, coordinator: MapSurfaceController) {
        coordinator.cancelTelemetryConsumers()
    }

    // Re-point the controller/collaborator closures on every structural update so
    // they always capture the freshest caller state. Cheap, and never called at
    // telemetry rate (the dot bypasses `updateNSView` entirely).
    private func wire(_ controller: MapSurfaceController) {
        controller.telemetryStreamProvider = telemetryStream
        controller.onFollowDisengagedByStream = { onFollowMirror(false) }
        director.onFollowDisengaged = { onFollowMirror(false) }
        bridge.onLongPress = onLongPress
        bridge.onRightClick = onRightClick
        bridge.onStroke = onStroke
    }
}
