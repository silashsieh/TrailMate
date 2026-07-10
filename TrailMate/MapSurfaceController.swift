import CoreLocation
import MapKit
import os

// Signpost plane for the map surface (epic 037, WP7 verification). Intervals and
// events are trivially cheap when Instruments isn't recording, so they can sit on
// the hot paths: overlay reconciliation, per-frame dot moves, and camera
// commands (the last emitted from `MapCameraDirector`). Subsystem/category are
// stable so a WP7 trace can filter on `category:MapPerf`.
let mapPerfSignposter = OSSignposter(subsystem: "com.harry.trailmate", category: "MapPerf")

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

    // MARK: - Telemetry fan-out (WP6)

    // Injected per-session telemetry subscription (frozen contract §2): the
    // controller resolves a session's stream through this closure, so it never
    // imports `AppState`. Async because each resolution renews the actor's
    // single-consumer stream. Set at integration before the first `apply`.
    var telemetryStreamProvider: ((UUID) async -> AsyncStream<TelemetryFrame>)?

    // Fired when the SELECTED session's telemetry position clears (nil) while
    // following — the one follow-disengage path the SwiftUI layer can't observe
    // itself. WP6 mirrors its follow-button state here. (The director's own
    // `onFollowDisengaged` covers the user-gesture path.)
    var onFollowDisengagedByStream: (() -> Void)?

    // The single consumer task per session (keyed by id). Exactly one iterator
    // per single-consumer stream; started when a session first appears, cancelled
    // when it disappears or the surface is dismantled.
    private var telemetryConsumers: [UUID: Task<Void, Never>] = [:]

    // The session whose dot the camera follows — the selected one. Read per frame
    // by the consumer to decide whether to drive the director. Updated from the
    // structural model in `apply`.
    private var selectedSessionID: UUID?

    // MARK: - Attachment

    func attach(to mapView: MKMapView) {
        self.mapView = mapView
        // The controller owns the delegate — it is the single owner of the map's
        // content and callbacks, so wiring it here (not at the call site) keeps
        // that invariant in one place.
        mapView.delegate = self
    }

    // MARK: - Structural apply

    func apply(_ model: MapSurfaceModel, to mapView: MKMapView) {
        let interval = mapPerfSignposter.beginInterval("overlay-apply")
        defer { mapPerfSignposter.endInterval("overlay-apply", interval) }
        self.mapView = mapView
        overlayStore.apply(model, to: mapView)
        annotationStore.apply(model.sessions, to: mapView)
        selectedSessionID = model.sessions.first(where: { $0.isSelected })?.id
        syncTelemetryConsumers(for: model.sessions.map(\.id))
    }

    // MARK: - Telemetry seam

    // Slide one session's dot to a new position, or hide it (nil). Called off
    // the telemetry stream, outside `apply`, so it uses the retained `mapView`.
    func setDotCoordinate(sessionID: UUID, coordinate: CLLocationCoordinate2D?) {
        guard let mapView else { return }
        mapPerfSignposter.emitEvent("dot-move")
        annotationStore.setDotCoordinate(sessionID: sessionID, coordinate: coordinate, in: mapView)
    }

    // Start a consumer for each newly-present session and cancel the ones whose
    // session has gone away — so there is always exactly one iterator per stream.
    private func syncTelemetryConsumers(for ids: [UUID]) {
        let present = Set(ids)
        for (id, task) in telemetryConsumers where !present.contains(id) {
            task.cancel()
            telemetryConsumers[id] = nil
        }
        guard let provider = telemetryStreamProvider else { return }
        for id in ids where telemetryConsumers[id] == nil {
            telemetryConsumers[id] = Task { @MainActor [weak self] in
                let stream = await provider(id)
                for await frame in stream {
                    guard let self else { break }
                    self.consumeTelemetry(frame, sessionID: id)
                }
            }
        }
    }

    // The sole per-session fan-out: move the dot every frame, and — only for the
    // selected, followed session — drive the camera, or disengage follow when the
    // position clears.
    private func consumeTelemetry(_ frame: TelemetryFrame, sessionID: UUID) {
        setDotCoordinate(sessionID: sessionID, coordinate: frame.coordinate)
        guard sessionID == selectedSessionID, let director = cameraDirector else { return }
        if let coordinate = frame.coordinate {
            director.followTarget(moved: coordinate)   // self-gates on isFollowing
        } else if director.isFollowing {
            director.followTargetCleared()
            onFollowDisengagedByStream?()
        }
    }

    // Cancel every consumer — the surface is being dismantled (view teardown).
    func cancelTelemetryConsumers() {
        for (_, task) in telemetryConsumers { task.cancel() }
        telemetryConsumers.removeAll()
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
