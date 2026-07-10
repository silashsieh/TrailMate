import CoreLocation
import MapKit
import os

// The imperative owner of the `MKMapView`'s camera (epic 037, WP4). It replaces
// the SwiftUI camera code `MapArea` used to carry: the persisted region, follow
// mode + follow-span, follow-disengage on a user gesture, and focus-on-saved-
// item. Driving the camera from here — never through a SwiftUI two-way
// `position:` binding — is what lets a moving dot evaluate no SwiftUI body.
//
// Cadence policy (the load-bearing correction from the reviewed plan): a camera
// animation permanently in flight is exactly the CPU cost this epic removes, so
// steady-state follow issues UNANIMATED, dead-banded moves — coalesced
// independently of the dot's 10 Hz telemetry cadence — and animation is reserved
// for the two discrete commands: follow engage (first recenter) and focus.
//
// Follow-disengage without `positionedByUser`: AppKit's `MKMapView` has no
// SwiftUI-style "positioned by user" flag, so a `regionWillChange` alone can't
// tell our own camera moves from the user's. We count *outstanding programmatic
// moves*: every move we issue holds a token until its settling `regionDidChange`
// retires it, and a `regionWillChange` seen with zero tokens outstanding is a
// user gesture. A counter (not a bool) so overlapping programmatic moves — e.g.
// a steady recenter interrupting an in-flight engage animation — stay covered
// and never read as a gesture.
//
// The controller forwards the two delegate callbacks here (it owns the
// delegate); WP6 wires `attach`, `followTarget`, `focus`, the follow button, and
// the telemetry stream. No telemetry/AppState type is referenced from here.
@MainActor
final class MapCameraDirector {
    private weak var mapView: MKMapView?
    private let log = Logger(subsystem: "com.harry.trailmate", category: "MapCamera")

    // MARK: - Follow state

    // Session-only, like MapKit's user-tracking: never persisted across launches.
    private(set) var isFollowing = false

    // Fired only when a *user gesture* disengages follow — the one disengage path
    // WP6 can't observe itself (it happens inside the `MKMapView`). WP6 syncs its
    // follow-button state here. Programmatic disengages (`focus`,
    // `followTargetCleared`, `setFollowing(false)`) are initiated by WP6, which
    // updates its own button state at those call sites, so they don't fire this.
    var onFollowDisengaged: (() -> Void)?

    // Last settled zoom; follow recenters preserve it so following never changes
    // the user's zoom. Seeded from the persisted region and refreshed on every
    // camera settle — parity with the old `.onMapCameraChange(frequency: .onEnd)`.
    private(set) var followSpan = MapCameraPersistence.loadRegion().span

    // MARK: - Internal camera bookkeeping

    // Outstanding programmatic-move tokens (see the type comment). A
    // `regionWillChange` while this is > 0 is ours; == 0 means a user gesture.
    private var outstandingProgrammaticMoves = 0

    // Applied once, so a re-`attach` (or a rebuilt view) never yanks the camera
    // back to the saved region mid-session.
    private var didApplyInitialRegion = false

    // Armed by `setFollowing(true)`: the first `followTarget` after engaging
    // animates its recenter (a discrete command); steady-state ones do not.
    private var engagePending = false

    // Steady-state follow dead-band: skip a recenter until the target has drifted
    // more than this many points from the map center, so a 10 Hz dot doesn't
    // drive a 10 Hz camera move (and 10 Hz region persistence). Measured in
    // screen points, so it's zoom-independent; small enough that the residual
    // drift reads as the dot sitting still at center.
    private let followDeadBandPoints: CGFloat = 8

    // MARK: - Attachment

    // Wire the map and apply the persisted region once. WP6 calls this after the
    // controller has created its `MKMapView`.
    func attach(to mapView: MKMapView) {
        self.mapView = mapView
        guard !didApplyInitialRegion else { return }
        didApplyInitialRegion = true

        let region = MapCameraPersistence.loadRegion()
        followSpan = region.span
        // Not tokenized: follow is off at attach, so this move can never be
        // mistaken for a follow-disengaging gesture — and tokenizing it would
        // leak a token if the map's default region happens to equal the loaded
        // one (MKMapView then fires no settling callback to retire it), which
        // would swallow the first real user gesture after launch.
        mapView.setRegion(region, animated: false)
    }

    // MARK: - Follow

    // Engage/disengage follow. Engaging arms an animated first recenter, applied
    // by the next `followTarget(moved:)`; WP6 calls that immediately with the
    // current position to reproduce the old "center now" on tapping Follow.
    // Disengaging here is caller-initiated, so `onFollowDisengaged` does not fire.
    func setFollowing(_ following: Bool) {
        guard following != isFollowing else { return }
        isFollowing = following
        engagePending = following
        if following {
            // Start the token count fresh: only follow's own moves matter now, so
            // discard any token a pre-engage programmatic move may have leaked
            // (e.g. a focus onto a region equal to the current one, which fires
            // no settling callback). Otherwise it could swallow the user's first
            // gesture of this follow session.
            outstandingProgrammaticMoves = 0
        }
    }

    // The followed target moved (called off the telemetry stream at integration).
    // No-op unless following. The first call after engaging animates a recenter
    // and bypasses the dead-band; steady-state calls recenter UNANIMATED and only
    // once the target has drifted past the dead-band. Every recenter keeps
    // `span == followSpan`, so following never changes the user's zoom.
    func followTarget(moved coordinate: CLLocationCoordinate2D) {
        guard isFollowing, let mapView else { return }

        if engagePending {
            engagePending = false
            let region = MKCoordinateRegion(center: coordinate, span: followSpan)
            performProgrammaticMove { mapView.setRegion(region, animated: true) }
            return
        }

        guard shouldRecenter(for: coordinate, in: mapView) else { return }
        let region = MKCoordinateRegion(center: coordinate, span: followSpan)
        performProgrammaticMove { mapView.setRegion(region, animated: false) }
    }

    // The followed target is gone (e.g. the simulated location was cleared back
    // to real GPS). Disengage with no camera move; caller-initiated, so
    // `onFollowDisengaged` does not fire.
    func followTargetCleared() {
        isFollowing = false
        engagePending = false
    }

    // MARK: - Focus

    // Frame a saved location/route (the old `mapFocus`). Focusing takes camera
    // control, so any active follow ends first — programmatically, so
    // `onFollowDisengaged` does not fire (WP6 clears its follow-button state at
    // the focus call site, as the old `mapFocus` `onChange` did inline).
    func focus(on region: MKCoordinateRegion) {
        isFollowing = false
        engagePending = false
        guard let mapView else { return }
        performProgrammaticMove { mapView.setRegion(region, animated: true) }
    }

    // MARK: - Delegate forwarding (from `MapSurfaceController`)

    // A region change is starting. With no programmatic token outstanding it's a
    // user pan/zoom, which hands camera control back — mirroring MapKit's
    // user-tracking semantics.
    func regionWillChange(animated: Bool) {
        guard outstandingProgrammaticMoves == 0 else { return }
        guard isFollowing else { return }
        isFollowing = false
        engagePending = false
        log.debug("Follow disengaged by user camera gesture")
        onFollowDisengaged?()
    }

    // A region change settled. Retire one programmatic token (if any) and mirror
    // the old `.onMapCameraChange(frequency: .onEnd)`: persist the region and
    // refresh the follow zoom.
    func regionDidChange(animated: Bool) {
        if outstandingProgrammaticMoves > 0 {
            outstandingProgrammaticMoves -= 1
        }
        guard let region = mapView?.region else { return }
        MapCameraPersistence.save(region: region)
        followSpan = region.span
    }

    // MARK: - Helpers

    private func performProgrammaticMove(_ body: () -> Void) {
        // The single choke point for every camera command the director issues
        // (engage, steady-follow recenter, focus). Signposting here gives WP7 the
        // actual camera-command cadence — which the dead-band coalesces well below
        // the dot's 10 Hz — on the `MapPerf` plane.
        mapPerfSignposter.emitEvent("camera-move")
        outstandingProgrammaticMoves += 1
        body()
    }

    // Dead-band test in screen space: has the target drifted past the dead-band
    // from the map center? Before layout (empty bounds) there's no meaningful
    // point space, so always recenter.
    private func shouldRecenter(for coordinate: CLLocationCoordinate2D, in mapView: MKMapView) -> Bool {
        let bounds = mapView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return true }
        let target = mapView.convert(coordinate, toPointTo: mapView)
        let dx = target.x - bounds.midX
        let dy = target.y - bounds.midY
        return (dx * dx + dy * dy) >= (followDeadBandPoints * followDeadBandPoints)
    }
}
