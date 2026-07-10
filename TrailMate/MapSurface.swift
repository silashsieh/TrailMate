import MapKit
import SwiftUI

// The SwiftUI bridge to the imperative map. It hosts one `MKMapView` (created
// once) and forwards the *structural* model to `MapSurfaceController`, which
// owns all content and delegate behavior. Body inputs are structural only:
// the live simulated position never passes through here — it reaches the dot
// via the controller's telemetry seam — so a moving dot triggers no SwiftUI
// update (epic 037's load-bearing property).
//
// The camera (WP4) and gestures (WP5) attach to the controller's `mapView`;
// this representable stays a thin structural conduit. When those land, this
// view gains the handler/camera inputs the frozen contract sketches — kept out
// of the surface core so the packages build independently.
struct MapSurface: NSViewRepresentable {
    var model: MapSurfaceModel

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

        context.coordinator.attach(to: mapView)
        context.coordinator.apply(model, to: mapView)
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        context.coordinator.apply(model, to: mapView)
    }
}
