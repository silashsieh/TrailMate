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
    // Async because each resolution renews the actor's single-consumer stream.
    var telemetryStream: (UUID) async -> AsyncStream<TelemetryFrame>

    // Mirror the caller's follow-button state when follow disengages by a path
    // the SwiftUI layer can't see itself — a user camera gesture inside the map,
    // or the selected session's position clearing.
    var onFollowMirror: (Bool) -> Void

    // Gesture actions (WP5 → integration): long-press coordinate, right-click
    // (coordinate + click point for menu placement), freehand stroke phases.
    var onLongPress: (CLLocationCoordinate2D) -> Void
    var onRightClick: (CLLocationCoordinate2D, NSPoint) -> Void
    var onStroke: (MapGestureBridge.StrokePhase) -> Void
    // Native control+left-click context menu (the AppKit convention the 0x2
    // right-click recognizer misses). Returns the same menu the recognizer pops
    // up, or nil to defer to the default (e.g. while drawing).
    var controlClickMenu: (CLLocationCoordinate2D, NSPoint) -> NSMenu?

    func makeCoordinator() -> MapSurfaceController {
        MapSurfaceController()
    }

    func makeNSView(context: Context) -> MapContainerView {
        let container = MapContainerView()
        let mapView = container.mapView

        // `.realistic` elevation for parity with today's `.mapStyle(.standard(elevation:))`;
        // the compass + zoom controls mirror the SwiftUI `MapCompass`/`MapZoomStepper`.
        mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic)
        mapView.showsCompass = true
        mapView.showsZoomControls = true

        let controller = context.coordinator
        controller.attach(to: mapView)   // owns mapView.delegate = self
        controller.cameraDirector = director
        director.attach(to: mapView)
        bridge.attach(to: mapView)

        // The persisted region cannot be applied while the map is 0×0 (its
        // camera degenerates and MapKit renders blank tiles until the next
        // interaction), so the director defers it; the container reports the
        // first real layout.
        container.onFirstNonzeroLayout = { [weak director] in
            director?.applyInitialRegionIfNeeded()
        }

        wire(controller, container)
        controller.apply(model, to: mapView)
        return container
    }

    func updateNSView(_ container: MapContainerView, context: Context) {
        let controller = context.coordinator
        wire(controller, container)
        controller.apply(model, to: container.mapView)
    }

    // Cancel the telemetry consumers when the surface is permanently removed. The
    // recognizers go away with the map view; the tasks must be cancelled by hand.
    static func dismantleNSView(_ container: MapContainerView, coordinator: MapSurfaceController) {
        coordinator.cancelTelemetryConsumers()
    }

    // Re-point the controller/collaborator closures on every structural update so
    // they always capture the freshest caller state. Cheap, and never called at
    // telemetry rate (the dot bypasses `updateNSView` entirely).
    private func wire(_ controller: MapSurfaceController, _ container: MapContainerView) {
        controller.telemetryStreamProvider = telemetryStream
        controller.onFollowDisengagedByStream = { onFollowMirror(false) }
        director.onFollowDisengaged = { onFollowMirror(false) }
        bridge.onLongPress = onLongPress
        bridge.onRightClick = onRightClick
        bridge.onStroke = onStroke
        container.mapView.controlClickMenuProvider = controlClickMenu
    }
}

// Owns the `TMMapView` and guarantees it always fills the SwiftUI-proposed
// bounds. SwiftUI resizes THIS plain view; `layout()` force-syncs the map's
// frame to it — belt (autoresizing) and braces (explicit sync), because the
// map view's frame silently stopped tracking the hosting view's size when the
// representable returned the `MKMapView` directly (map pinned to a stale
// partial frame; gray bands elsewhere). It also reports the first nonzero
// layout so the initial camera region is applied only once the map has size.
final class MapContainerView: NSView {
    let mapView = TMMapView()
    var onFirstNonzeroLayout: (() -> Void)?
    private var reportedNonzeroLayout = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        autoresizesSubviews = true
        mapView.frame = bounds
        mapView.autoresizingMask = [.width, .height]
        addSubview(mapView)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func layout() {
        super.layout()
        if mapView.frame != bounds {
            mapView.frame = bounds
        }
        if !reportedNonzeroLayout, bounds.width > 0, bounds.height > 0 {
            reportedNonzeroLayout = true
            onFirstNonzeroLayout?()
        }
    }
}

// An `MKMapView` that also surfaces the native control+left-click context menu —
// the AppKit convention the right-click gesture recognizer (buttonMask 0x2)
// misses, because Control+left-click is a *left* button event. Right-click stays
// on the recognizer; this handles only the control-click path (gated on the
// `.control` modifier + a left-mouse event) so the menu is never presented twice.
final class TMMapView: MKMapView {
    var controlClickMenuProvider: ((CLLocationCoordinate2D, NSPoint) -> NSMenu?)?

    // MAP-SCOPED user camera-input tracking (PR #69 review, High 1). The
    // camera director must tell a real pan/zoom ON THIS MAP from its own
    // programmatic callbacks; an app-global NSApp.currentEvent heuristic could
    // misclassify unrelated input (e.g. a sidebar scroll coinciding with a
    // programmatic settle). Every camera-driving input that reaches this view
    // stamps a timestamp; the director treats a `regionWillChange` within the
    // live window as user-driven. The window outlasts one event so drag
    // sequences and scroll momentum (which keep restamping) stay covered.
    static let userInputLiveWindow: TimeInterval = 1.0
    private(set) var lastUserCameraInputUptime: TimeInterval = -.greatestFiniteMagnitude

    func noteUserCameraInput(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lastUserCameraInputUptime = uptime
    }

    func userCameraInputIsLive(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        now - lastUserCameraInputUptime < Self.userInputLiveWindow
    }

    override func scrollWheel(with event: NSEvent) { noteUserCameraInput(); super.scrollWheel(with: event) }
    override func magnify(with event: NSEvent) { noteUserCameraInput(); super.magnify(with: event) }
    override func rotate(with event: NSEvent) { noteUserCameraInput(); super.rotate(with: event) }
    override func smartMagnify(with event: NSEvent) { noteUserCameraInput(); super.smartMagnify(with: event) }
    override func mouseDown(with event: NSEvent) { noteUserCameraInput(); super.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { noteUserCameraInput(); super.mouseDragged(with: event) }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard event.modifierFlags.contains(.control),
              event.type == .leftMouseDown || event.type == .leftMouseUp else {
            return super.menu(for: event)
        }
        let point = convert(event.locationInWindow, from: nil)
        let coordinate = convert(point, toCoordinateFrom: self)
        return controlClickMenuProvider?(coordinate, point) ?? super.menu(for: event)
    }
}
