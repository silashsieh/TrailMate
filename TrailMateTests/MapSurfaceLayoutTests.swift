import AppKit
import MapKit
import SwiftUI
import Testing
@testable import TrailMate

// Regression coverage for the Part 2-B walkthrough sizing failure (2026-07-11):
// the hosted MKMapView stopped tracking the SwiftUI-proposed size — map pinned
// to a stale partial frame with gray bands elsewhere, and the initial region
// applied at 0×0 rendered blank tiles until the first drag. MapContainerView
// now force-syncs the map's frame in layout() and defers the initial region to
// the first nonzero layout.
@MainActor
struct MapSurfaceLayoutTests {
    private func makeSurface() -> MapSurface {
        MapSurface(
            model: MapSurfaceModel(),
            director: MapCameraDirector(),
            bridge: MapGestureBridge(),
            telemetryStream: { _ in AsyncStream { $0.finish() } },
            onFollowMirror: { _ in },
            onLongPress: { _ in },
            onRightClick: { _, _ in },
            onStroke: { _ in },
            controlClickMenu: { _, _ in nil }
        )
    }

    private func findMapView(in view: NSView) -> TMMapView? {
        if let map = view as? TMMapView { return map }
        for sub in view.subviews {
            if let found = findMapView(in: sub) { return found }
        }
        return nil
    }

    // The walkthrough repro: host the surface at a real size, then resize —
    // the map view must fill the hosted bounds both times.
    @Test func hostedMapFillsAndTracksProposedSize() {
        let host = NSHostingView(rootView: makeSurface())
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        defer { window.orderOut(nil) }   // never shown; keep it that way
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        guard let map = findMapView(in: host) else {
            Issue.record("no TMMapView in the hosted hierarchy")
            return
        }
        #expect(abs(map.frame.width - 800) < 2 && abs(map.frame.height - 600) < 2,
                "map \(map.frame) should fill 800×600")
        #expect(map.frame.size == map.superview?.bounds.size)

        window.setContentSize(NSSize(width: 1000, height: 700))
        host.layoutSubtreeIfNeeded()
        #expect(abs(map.frame.width - 1000) < 2 && abs(map.frame.height - 700) < 2,
                "map \(map.frame) should track resize to 1000×700")
    }

    // The container reports its first nonzero layout exactly once (the deferred
    // initial-region hook), and never at zero size.
    @Test func firstNonzeroLayoutFiresOnce() {
        let container = MapContainerView(frame: .zero)
        var fires = 0
        container.onFirstNonzeroLayout = { fires += 1 }

        container.layoutSubtreeIfNeeded()
        #expect(fires == 0, "zero-size layout must not fire the hook")

        container.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        container.layoutSubtreeIfNeeded()
        container.frame = NSRect(x: 0, y: 0, width: 500, height: 350)
        container.layoutSubtreeIfNeeded()
        #expect(fires == 1, "hook fires exactly once, on the first real layout")
        #expect(container.mapView.frame.size == container.bounds.size)
    }

    // Deferred initial region: attach at 0×0 applies nothing; the explicit
    // apply sets the persisted region once and never re-applies (a rebuilt view
    // must not yank the camera back).
    @Test func initialRegionDeferredAtZeroSizeAndAppliedOnce() {
        let map = MKMapView(frame: .zero)
        let director = MapCameraDirector()
        director.attach(to: map)   // 0×0 → deferred

        map.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        director.applyInitialRegionIfNeeded()
        let expected = MapCameraPersistence.loadRegion()
        #expect(abs(map.region.center.latitude - expected.center.latitude) < 0.5)
        #expect(abs(map.region.center.longitude - expected.center.longitude) < 0.5)

        // Pan elsewhere; a second apply must be a no-op.
        let elsewhere = CLLocationCoordinate2D(latitude: -33.86, longitude: 151.21)
        map.setRegion(MKCoordinateRegion(
            center: elsewhere,
            span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
        ), animated: false)
        director.applyInitialRegionIfNeeded()
        #expect(abs(map.region.center.latitude - elsewhere.latitude) < 0.5,
                "second apply must not yank the camera back")
    }
}
