import CoreLocation
import Foundation

// Structural inputs to `MapSurface` — everything the map draws *except* the
// live simulated position. A position tick must never flow through here: it
// travels on the telemetry stream and reaches the map via
// `MapSurfaceController.setDotCoordinate`, so a moving dot evaluates no SwiftUI
// body (epic 037's load-bearing property). Anything that changes at telemetry
// rate belongs on the stream, not in this model.

// One session's contribution to the map, keyed by `id`. `routeVersion` is the
// diffing pivot: the controller compares this `Int` (never the coordinate
// array) to decide whether a session's route polyline must be rebuilt, so
// `updateNSView` stays O(sessions).
struct SessionRenderState {
    let id: UUID
    // Index into `AppState.sessionPalette`; the store wraps it modulo the
    // palette count, matching the shared-map color assignment.
    let colorIndex: Int
    let isSelected: Bool
    // Bumped upstream (`DeviceSession.routeVersion`) whenever `routeCoordinates`
    // is reassigned. Same version ⇒ same geometry ⇒ keep the existing overlay.
    let routeVersion: Int
    let routeCoordinates: [CLLocationCoordinate2D]

    init(
        id: UUID,
        colorIndex: Int,
        isSelected: Bool,
        routeVersion: Int,
        routeCoordinates: [CLLocationCoordinate2D]
    ) {
        self.id = id
        self.colorIndex = colorIndex
        self.isSelected = isSelected
        self.routeVersion = routeVersion
        self.routeCoordinates = routeCoordinates
    }
}

// The planning markers layered over the routes: route start/end, the numbered
// mid-route stops, and the pending teleport/route destination. These change
// only on user edits, so they live in the structural model rather than on the
// stream.
struct MapMarkers {
    // A numbered mid-route stop. `id` keeps the annotation object stable across
    // reorders/insertions so only its glyph number (derived from position)
    // updates in place; the coordinate is resolved (non-nil) by the caller.
    struct Stop {
        let id: UUID
        let coordinate: CLLocationCoordinate2D
    }

    var from: CLLocationCoordinate2D?
    var to: CLLocationCoordinate2D?
    var pendingDestination: CLLocationCoordinate2D?
    var stops: [Stop]

    init(
        from: CLLocationCoordinate2D? = nil,
        to: CLLocationCoordinate2D? = nil,
        pendingDestination: CLLocationCoordinate2D? = nil,
        stops: [Stop] = []
    ) {
        self.from = from
        self.to = to
        self.pendingDestination = pendingDestination
        self.stops = stops
    }
}

// The complete structural snapshot handed to `MapSurface` on each SwiftUI
// update. Redundant (unchanged) snapshots are safe — the controller's `apply`
// is idempotent — so callers need not deduplicate.
struct MapSurfaceModel {
    var sessions: [SessionRenderState]
    var markers: MapMarkers
    // The in-progress freehand route stroke (already world-anchored). Rendered
    // as its own overlay class; empty or single-point strokes draw nothing.
    var strokeCoordinates: [CLLocationCoordinate2D]
    // Draw-mode flag. Carried for the gesture bridge (WP5) / integration (WP6)
    // to gate map interaction while drawing; the surface core does not act on
    // it — stroke visibility is driven by `strokeCoordinates` alone.
    var isDrawingRoute: Bool

    init(
        sessions: [SessionRenderState] = [],
        markers: MapMarkers = MapMarkers(),
        strokeCoordinates: [CLLocationCoordinate2D] = [],
        isDrawingRoute: Bool = false
    ) {
        self.sessions = sessions
        self.markers = markers
        self.strokeCoordinates = strokeCoordinates
        self.isDrawingRoute = isDrawingRoute
    }
}
