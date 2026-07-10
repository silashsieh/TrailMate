import CoreLocation
import Foundation
import MapKit

// Persists the map camera's region (center + span) across launches, so the map
// reopens where the user left it. The default is a Taipei landmark — the same
// point `SimulatedPositionPersistence` falls back to — so a fresh install opens
// framed on the first-ever red dot.
//
// Extracted verbatim from `ContentView` (epic 037, WP4): the imperative
// `MapCameraDirector` — which now owns all camera behavior — must reference it
// from its own file, and one-type-per-file keeps the single source of truth for
// camera persistence out of the 2k-line view. Behavior and keys are unchanged.
enum MapCameraPersistence {
    private static let centerLatKey = "MapCamera.centerLat"
    private static let centerLonKey = "MapCamera.centerLon"
    private static let spanLatKey = "MapCamera.spanLatDelta"
    private static let spanLonKey = "MapCamera.spanLonDelta"

    private static let defaultCenter = CLLocationCoordinate2D(latitude: 25.033, longitude: 121.565)
    private static let defaultSpan = MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)

    static func loadRegion() -> MKCoordinateRegion {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: centerLatKey) != nil else {
            return MKCoordinateRegion(center: defaultCenter, span: defaultSpan)
        }
        let center = CLLocationCoordinate2D(
            latitude: defaults.double(forKey: centerLatKey),
            longitude: defaults.double(forKey: centerLonKey)
        )
        let span = MKCoordinateSpan(
            latitudeDelta: defaults.double(forKey: spanLatKey),
            longitudeDelta: defaults.double(forKey: spanLonKey)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    static func save(region: MKCoordinateRegion) {
        let defaults = UserDefaults.standard
        defaults.set(region.center.latitude, forKey: centerLatKey)
        defaults.set(region.center.longitude, forKey: centerLonKey)
        defaults.set(region.span.latitudeDelta, forKey: spanLatKey)
        defaults.set(region.span.longitudeDelta, forKey: spanLonKey)
    }
}
