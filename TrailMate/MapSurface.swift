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

    // MAP-SCOPED user camera-input tracking (PR #69 reviews, High). The camera
    // director must tell a real pan/zoom ON THIS MAP from its own programmatic
    // callbacks. A monotonically increasing SEQUENCE — not a timestamp latch —
    // so the director can CONSUME what it has attributed: a time window would
    // stay "live" after a pan and misclassify the animated recenter of an
    // immediate Follow re-engage as another user gesture. Every camera-driving
    // input that reaches this view (pan drag, scroll incl. momentum, magnify,
    // rotate, smart-magnify — deliberately NOT a bare mouse-down, which is a
    // click, not a camera gesture) bumps the sequence; the director compares it
    // against the last sequence it consumed.
    private(set) var userCameraInputSequence: UInt64 = 0

    func noteUserCameraInput() {
        userCameraInputSequence &+= 1
    }

    // Events are observed with a LOCAL MONITOR, not responder overrides: the
    // built-in zoom stepper and compass are MapKit SUBVIEWS, so their clicks
    // hit-test to those subviews and never reach this view's responder methods
    // — a click-driven zoom would otherwise stay untracked and be swallowed
    // while a Follow move is outstanding (PR #69 review, High). The monitor
    // observes and never consumes; scoping is geometric: this map's window,
    // inside this map's bounds.
    private var inputMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor); self.inputMonitor = nil }
        guard window != nil else { return }
        inputMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .magnify, .rotate, .smartMagnify,
                       .leftMouseDown, .leftMouseUp, .leftMouseDragged, .otherMouseDragged]
        ) { [weak self] event in
            self?.classifyAndStampUserCameraInput(event)
            return event
        }
    }

    // No deinit teardown: leaving a window triggers viewDidMoveToWindow(nil),
    // which removes the monitor; and the monitor holds self weakly, so even a
    // torn-down view leaves only an inert observer (a view can't deallocate
    // while still installed in a window). A nonisolated deinit can't touch
    // MainActor state under strict concurrency anyway.

    // A left-button gesture is attributed by its ORIGIN: the SwiftUI overlays
    // (virtual joystick, destination bar, chips) render over the full-bleed
    // map, so a drag that starts on an overlay can wander across raw map
    // pixels mid-gesture — location-scoping alone would misread it as a map
    // pan and disengage Follow (PR #69 review, High). Set on mouse-down from
    // the hit-tested target, cleared on mouse-up.
    private var dragOriginatedInMap = false

    // The monitor's body. Scoping is by the event's actual HIT-TESTED TARGET
    // (resolved from the window's content view, so sibling/SwiftUI overlay
    // views win where they cover the map), never by raw map-bounds geometry.
    // Returns whether the event stamped the sequence.
    @discardableResult
    func classifyAndStampUserCameraInput(_ event: NSEvent) -> Bool {
        guard event.window === window, window != nil else { return false }

        switch event.type {
        case .scrollWheel, .magnify, .rotate, .smartMagnify, .otherMouseDragged:
            // Instantaneous camera inputs: attributed by their current target.
            guard hitTestedView(of: event)?.isDescendant(of: self) == true else { return false }
            noteUserCameraInput()
            return true
        case .leftMouseDown:
            let hit = hitTestedView(of: event)
            let inMap = hit?.isDescendant(of: self) == true
            dragOriginatedInMap = inMap
            guard inMap else { return false }
            // Clicks are camera input only when they drive the camera: a
            // double-click (zoom in / shift-zoom out) on the canvas, or a
            // click landing on one of MapKit's own control subviews (zoom
            // stepper, compass). A plain single click on the canvas — e.g.
            // selecting the dot or a marker — must NOT stamp, or it would
            // falsely disengage Follow at the next settle.
            if event.clickCount >= 2 {
                noteUserCameraInput()
                return true
            }
            if let hit, hit !== self, isMapControl(hit) {
                noteUserCameraInput()
                return true
            }
            return false
        case .leftMouseDragged:
            // A pan only if the gesture BEGAN in the map's own hierarchy.
            guard dragOriginatedInMap else { return false }
            noteUserCameraInput()
            return true
        case .leftMouseUp:
            dragOriginatedInMap = false
            return false
        default:
            return false
        }
    }

    // Deepest view under the event, resolved from the window's content view so
    // overlay siblings above the map win exactly as they do for real event
    // routing.
    private func hitTestedView(of event: NSEvent) -> NSView? {
        guard let root = window?.contentView else { return nil }
        let point = root.superview?.convert(event.locationInWindow, from: nil)
            ?? event.locationInWindow
        return root.hitTest(point)
    }

    // MapKit's built-in camera widgets: the zoom stepper is an NSControl; the
    // compass (and any pitch control) is matched by class name as a fallback.
    private func isMapControl(_ view: NSView) -> Bool {
        var v: NSView? = view
        while let current = v, current !== self {
            if current is NSControl { return true }
            let name = String(describing: type(of: current)).lowercased()
            if name.contains("zoom") || name.contains("compass") || name.contains("pitch") {
                return true
            }
            v = current.superview
        }
        return false
    }

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
