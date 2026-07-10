import AppKit
import MapKit
import SwiftUI

// Owns the per-session simulated-position dots — the one part of the map that
// moves at telemetry rate. There is exactly one stable `SessionDotAnnotation`
// object per session for its whole lifetime: structural `apply` adds/removes it
// and updates its color/selection emphasis, while `setDotCoordinate` (driven by
// the telemetry stream) only mutates its `coordinate`. Because the object
// identity never changes and `coordinate` is KVO-compliant, MapKit slides the
// existing annotation view instead of rebuilding it — so a position tick
// evaluates no SwiftUI body and rebuilds no view (epic 037).
//
// One-type-per-file is relaxed here (see `MapOverlayStore` for the rationale):
// `SessionDotAnnotation` and `SessionDotAnnotationView` are the store's private
// collaborators.
final class MapAnnotationStore {
    private var dots: [UUID: SessionDotAnnotation] = [:]

    // MARK: - Apply (structural)

    // Keep one dot per current session. The dot is added to the map as soon as
    // its session exists (its view stays hidden until a position arrives, so
    // the placeholder coordinate never shows), and removed when the session
    // goes away. Color/selection changes update the existing object — and its
    // live view — without recreating either.
    func apply(_ sessions: [SessionRenderState], to mapView: MKMapView) {
        let present = Set(sessions.map { $0.id })
        for (id, dot) in dots where !present.contains(id) {
            mapView.removeAnnotation(dot)
            dots[id] = nil
        }

        for session in sessions {
            if let dot = dots[session.id] {
                guard dot.colorIndex != session.colorIndex || dot.isSelected != session.isSelected else { continue }
                dot.colorIndex = session.colorIndex
                dot.isSelected = session.isSelected
                if let view = mapView.view(for: dot) as? SessionDotAnnotationView {
                    view.configure(color: Self.paletteColor(session.colorIndex), isSelected: session.isSelected)
                }
            } else {
                let dot = SessionDotAnnotation()
                dot.sessionID = session.id
                dot.colorIndex = session.colorIndex
                dot.isSelected = session.isSelected
                dots[session.id] = dot
                mapView.addAnnotation(dot)
            }
        }
    }

    // MARK: - Telemetry seam

    // Move a session's dot in place; `nil` hides it (position cleared back to
    // real GPS). The annotation object is never added/removed here, so its
    // identity stays stable across the whole nil↔position cycle.
    func setDotCoordinate(sessionID: UUID, coordinate: CLLocationCoordinate2D?, in mapView: MKMapView) {
        guard let dot = dots[sessionID] else { return }
        if let coordinate {
            dot.coordinate = coordinate
            dot.hasPosition = true
            (mapView.view(for: dot) as? SessionDotAnnotationView)?.isHidden = false
        } else {
            dot.hasPosition = false
            (mapView.view(for: dot) as? SessionDotAnnotationView)?.isHidden = true
        }
    }

    // MARK: - Rendering (delegated from MapSurfaceController)

    func view(for annotation: any MKAnnotation, in mapView: MKMapView) -> MKAnnotationView? {
        guard let dot = annotation as? SessionDotAnnotation else { return nil }
        let identifier = "TMSessionDot"
        let view = (mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? SessionDotAnnotationView)
            ?? SessionDotAnnotationView(annotation: dot, reuseIdentifier: identifier)
        view.annotation = dot
        view.configure(color: Self.paletteColor(dot.colorIndex), isSelected: dot.isSelected)
        view.isHidden = !dot.hasPosition
        return view
    }

    private static func paletteColor(_ colorIndex: Int) -> NSColor {
        NSColor(AppState.sessionPalette[colorIndex % AppState.sessionPalette.count])
    }
}

// The stable simulated-position dot for one session. `coordinate` is
// `@objc dynamic` so MapKit's KVO repositions the view in place; `hasPosition`
// gates visibility while keeping the object (and its identity) alive across
// clears. `nonisolated` because MapKit reads `coordinate` via KVO and the
// added state is otherwise only touched from the MainActor store.
nonisolated final class SessionDotAnnotation: NSObject, MKAnnotation {
    // Placeholder until the first telemetry position; the view is hidden while
    // `hasPosition` is false, so (0,0) never renders.
    @objc dynamic var coordinate = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    var sessionID: UUID?
    var colorIndex: Int = 0
    var isSelected: Bool = false
    var hasPosition: Bool = false
}

// Reproduces today's SwiftUI dot: a filled circle in the session color inside a
// white ring, larger and thicker-ringed when selected. Built once and
// reconfigured in place — selection emphasis never recreates the view.
//
// Geometry mirrors the SwiftUI original exactly. There a colored `Circle` of
// diameter `d` carries a centered `stroke` of width `w`: the stroke straddles
// the edge, so the visible ring spans diameters `d-w … d+w` and the visible
// fill is `d-w`. Reproduced with a white disc of diameter `d+w` under a colored
// disc of diameter `d-w`.
final class SessionDotAnnotationView: MKAnnotationView {
    private let ringLayer = CALayer()
    private let fillLayer = CALayer()

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        wantsLayer = true
        // Center the dot on the coordinate (no pin-style bottom anchor).
        centerOffset = .zero
        layer?.addSublayer(ringLayer)
        layer?.addSublayer(fillLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(color: NSColor, isSelected: Bool) {
        let fillDesign: CGFloat = isSelected ? 16 : 12
        let ringWidth: CGFloat = isSelected ? 3 : 2
        let container = fillDesign + ringWidth
        let visibleFill = fillDesign - ringWidth

        frame = CGRect(x: 0, y: 0, width: container, height: container)

        ringLayer.frame = bounds
        ringLayer.cornerRadius = container / 2
        ringLayer.backgroundColor = NSColor.white.cgColor

        let inset = (container - visibleFill) / 2
        fillLayer.frame = CGRect(x: inset, y: inset, width: visibleFill, height: visibleFill)
        fillLayer.cornerRadius = visibleFill / 2
        fillLayer.backgroundColor = color.cgColor
    }
}
