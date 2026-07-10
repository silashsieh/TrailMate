import AppKit
import MapKit
import SwiftUI

// Owns everything the map draws as an *overlay* or a *planning marker*: one
// route `MKPolyline` per session, the freehand stroke polyline, and the
// start/stop/end/destination markers. It diffs structurally — a session's
// route is rebuilt only when its `routeVersion` (an `Int`) changes, never by
// comparing coordinate arrays — so an unchanged model re-applied causes zero
// overlay/annotation churn (same object identities, no add/remove).
//
// The dot annotations are *not* here: they move at telemetry rate and live in
// `MapAnnotationStore`. Rendering/styling is delegated back to this store by
// `MapSurfaceController` (see `renderer(for:)` / `view(for:in:)`).
//
// One-type-per-file is relaxed for this file: `RoutePolyline`, `StrokePolyline`
// and `MarkerAnnotation` are private data-carrying MapKit subclasses that exist
// only so the delegate can style overlays it owns. Co-locating them keeps the
// WP3 surface to the file set the work package specifies and keeps them out of
// the API other work packages build against.
final class MapOverlayStore {
    // Route polyline per session, keyed by session id; the polyline itself
    // records the version it was built from.
    private var routeOverlays: [UUID: RoutePolyline] = [:]

    // The single freehand stroke overlay, plus the coordinates it was built
    // from. The stroke is one small overlay, so a cheap element-wise compare
    // (not the per-session array compare the diffing rule forbids) is enough to
    // keep it stable across identical applies.
    private var strokeOverlay: StrokePolyline?
    private var strokeSource: [CLLocationCoordinate2D] = []

    // Stable planning-marker annotations, so an unchanged model reuses them.
    private var startMarker: MarkerAnnotation?
    private var endMarker: MarkerAnnotation?
    private var destinationMarker: MarkerAnnotation?
    private var stopMarkers: [UUID: MarkerAnnotation] = [:]

    // MARK: - Apply (structural)

    func apply(_ model: MapSurfaceModel, to mapView: MKMapView) {
        applyRoutes(model.sessions, to: mapView)
        applyStroke(model.strokeCoordinates, to: mapView)
        applyMarkers(model.markers, to: mapView)
    }

    private func applyRoutes(_ sessions: [SessionRenderState], to mapView: MKMapView) {
        let present = Set(sessions.map { $0.id })
        for (id, overlay) in routeOverlays where !present.contains(id) {
            mapView.removeOverlay(overlay)
            routeOverlays[id] = nil
        }

        for session in sessions {
            guard !session.routeCoordinates.isEmpty else {
                if let stale = routeOverlays[session.id] {
                    mapView.removeOverlay(stale)
                    routeOverlays[session.id] = nil
                }
                continue
            }

            if let existing = routeOverlays[session.id], existing.routeVersion == session.routeVersion {
                // Same geometry — keep the overlay object; only restyle if the
                // session's color or selection changed, updating the live
                // renderer in place so selection never churns the overlay.
                if existing.colorIndex != session.colorIndex || existing.isSelected != session.isSelected {
                    existing.colorIndex = session.colorIndex
                    existing.isSelected = session.isSelected
                    if let renderer = mapView.renderer(for: existing) as? MKPolylineRenderer {
                        Self.styleRoute(renderer, colorIndex: existing.colorIndex, isSelected: existing.isSelected)
                        renderer.setNeedsDisplay()
                    }
                }
                continue
            }

            // New session, or the route geometry actually changed: rebuild just
            // this session's polyline.
            if let stale = routeOverlays[session.id] {
                mapView.removeOverlay(stale)
            }
            let overlay = RoutePolyline(coordinates: session.routeCoordinates, count: session.routeCoordinates.count)
            overlay.sessionID = session.id
            overlay.colorIndex = session.colorIndex
            overlay.isSelected = session.isSelected
            overlay.routeVersion = session.routeVersion
            routeOverlays[session.id] = overlay
            mapView.addOverlay(overlay, level: .aboveRoads)
        }
    }

    private func applyStroke(_ coordinates: [CLLocationCoordinate2D], to mapView: MKMapView) {
        guard coordinates.count >= 2 else {
            if let stroke = strokeOverlay {
                mapView.removeOverlay(stroke)
                strokeOverlay = nil
                strokeSource = []
            }
            return
        }
        guard !Self.coordinatesEqual(strokeSource, coordinates) else { return }

        if let stroke = strokeOverlay {
            mapView.removeOverlay(stroke)
        }
        let stroke = StrokePolyline(coordinates: coordinates, count: coordinates.count)
        strokeOverlay = stroke
        strokeSource = coordinates
        // Above labels so the in-progress stroke stays visible over routes.
        mapView.addOverlay(stroke, level: .aboveLabels)
    }

    private func applyMarkers(_ markers: MapMarkers, to mapView: MKMapView) {
        updateSingle(markers.from, storage: &startMarker, kind: .start, in: mapView)
        updateSingle(markers.to, storage: &endMarker, kind: .end, in: mapView)
        updateSingle(markers.pendingDestination, storage: &destinationMarker, kind: .destination, in: mapView)

        let incoming = Set(markers.stops.map { $0.id })
        for (id, marker) in stopMarkers where !incoming.contains(id) {
            mapView.removeAnnotation(marker)
            stopMarkers[id] = nil
        }
        for stop in markers.stops {
            let number = stop.number
            if let marker = stopMarkers[stop.id] {
                if !Self.coordinateEqual(marker.coordinate, stop.coordinate) {
                    marker.coordinate = stop.coordinate
                }
                if marker.kind != .stop(number: number) {
                    marker.kind = .stop(number: number)
                    refreshMarkerGlyph(marker, in: mapView)
                }
            } else {
                let marker = MarkerAnnotation(kind: .stop(number: number), coordinate: stop.coordinate)
                stopMarkers[stop.id] = marker
                mapView.addAnnotation(marker)
            }
        }
    }

    private func updateSingle(
        _ coordinate: CLLocationCoordinate2D?,
        storage: inout MarkerAnnotation?,
        kind: MarkerAnnotation.Kind,
        in mapView: MKMapView
    ) {
        if let coordinate {
            if let marker = storage {
                if !Self.coordinateEqual(marker.coordinate, coordinate) {
                    marker.coordinate = coordinate
                }
            } else {
                let marker = MarkerAnnotation(kind: kind, coordinate: coordinate)
                storage = marker
                mapView.addAnnotation(marker)
            }
        } else if let marker = storage {
            mapView.removeAnnotation(marker)
            storage = nil
        }
    }

    private func refreshMarkerGlyph(_ marker: MarkerAnnotation, in mapView: MKMapView) {
        guard let view = mapView.view(for: marker) as? MKMarkerAnnotationView else { return }
        view.glyphImage = NSImage(systemSymbolName: marker.kind.glyphSymbolName, accessibilityDescription: marker.kind.title)
    }

    // MARK: - Rendering (delegated from MapSurfaceController)

    func renderer(for overlay: any MKOverlay) -> MKOverlayRenderer? {
        if let stroke = overlay as? StrokePolyline {
            let renderer = MKPolylineRenderer(polyline: stroke)
            renderer.strokeColor = .systemOrange
            renderer.lineWidth = 3
            renderer.lineCap = .round
            renderer.lineDashPattern = [6, 4]
            return renderer
        }
        if let route = overlay as? RoutePolyline {
            let renderer = MKPolylineRenderer(polyline: route)
            Self.styleRoute(renderer, colorIndex: route.colorIndex, isSelected: route.isSelected)
            return renderer
        }
        return nil
    }

    func view(for annotation: any MKAnnotation, in mapView: MKMapView) -> MKAnnotationView? {
        guard let marker = annotation as? MarkerAnnotation else { return nil }
        let identifier = "TMMarker"
        let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? MKMarkerAnnotationView)
            ?? MKMarkerAnnotationView(annotation: marker, reuseIdentifier: identifier)
        view.annotation = marker
        view.markerTintColor = marker.kind.tintColor
        view.glyphImage = NSImage(systemSymbolName: marker.kind.glyphSymbolName, accessibilityDescription: marker.kind.title)
        // All planning markers must stay visible (parity with SwiftUI `Marker`,
        // which never clusters); MapKit would otherwise hide colliding ones.
        view.displayPriority = .required
        view.animatesWhenAdded = false
        return view
    }

    private static func styleRoute(_ renderer: MKPolylineRenderer, colorIndex: Int, isSelected: Bool) {
        let base = NSColor(AppState.sessionPalette[colorIndex % AppState.sessionPalette.count])
        renderer.strokeColor = base.withAlphaComponent(isSelected ? 1.0 : 0.7)
        renderer.lineWidth = isSelected ? 4 : 3
    }

    private static func coordinateEqual(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Bool {
        a.latitude == b.latitude && a.longitude == b.longitude
    }

    private static func coordinatesEqual(_ a: [CLLocationCoordinate2D], _ b: [CLLocationCoordinate2D]) -> Bool {
        guard a.count == b.count else { return false }
        for index in a.indices where !coordinateEqual(a[index], b[index]) { return false }
        return true
    }
}

// A route polyline that carries the metadata the renderer and diff need. It's a
// plain `MKPolyline` subclass (all added properties defaulted, so the
// `init(coordinates:count:)` convenience initializer is inherited). `nonisolated`
// keeps it free of actor isolation — MapKit only ever reads the inherited point
// data; the added properties are touched solely from the MainActor store.
nonisolated final class RoutePolyline: MKPolyline {
    var sessionID: UUID?
    var colorIndex: Int = 0
    var isSelected: Bool = false
    var routeVersion: Int = 0
}

// The freehand draw stroke as a distinct class, so `renderer(for:)` can style
// it (orange, dashed) without confusing it for a route.
nonisolated final class StrokePolyline: MKPolyline {}

// A planning marker (start/stop/end/destination). `coordinate` is KVO-compliant
// so MapKit repositions the marker view in place when it changes; `kind`
// carries the glyph/tint/title and, for stops, the number.
nonisolated final class MarkerAnnotation: NSObject, MKAnnotation {
    enum Kind: Equatable {
        case start
        case end
        case destination
        case stop(number: Int)

        var glyphSymbolName: String {
            switch self {
            case .start: "flag.fill"
            case .end: "mappin"
            case .destination: "mappin.and.ellipse"
            case .stop(let number): "\(number).circle.fill"
            }
        }

        var tintColor: NSColor {
            switch self {
            case .start: .systemGreen
            case .end: .systemOrange
            case .destination: .systemPurple
            case .stop: .systemBlue
            }
        }

        var title: String {
            switch self {
            case .start: "Start"
            case .end: "End"
            case .destination: "Destination"
            case .stop(let number): "Stop \(number)"
            }
        }
    }

    @objc dynamic var coordinate: CLLocationCoordinate2D
    var kind: Kind

    var title: String? { kind.title }

    init(kind: Kind, coordinate: CLLocationCoordinate2D) {
        self.kind = kind
        self.coordinate = coordinate
        super.init()
    }
}
