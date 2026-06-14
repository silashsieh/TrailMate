import CoreLocation
import Foundation

// Persists the last simulated position (the red dot) across launches, plus the
// user preference for whether launch restores it. The position is always
// recorded; the preference only gates the restore — so flipping the toggle on
// later still has a position to restore (epic 005).
enum SimulatedPositionPersistence {
    private static let latKey = "SimulatedPosition.lat"
    private static let lonKey = "SimulatedPosition.lon"
    private static let restoreKey = "SimulatedPosition.restoreOnLaunch"

    // Fresh-install fallback — the same Taipei landmark MapCameraPersistence
    // centers the camera on, so the first-ever red dot appears on screen.
    static let defaultCoordinate = CLLocationCoordinate2D(latitude: 25.033, longitude: 121.565)

    // Default true: the maps-app convention is to never start blank (D9);
    // turning this off is the explicit opt-out back to a start-empty launch.
    static var restoreOnLaunch: Bool {
        get { restoreOnLaunch(in: .standard) }
        set { setRestoreOnLaunch(newValue, in: .standard) }
    }

    static func restoreOnLaunch(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: restoreKey) as? Bool ?? true
    }

    static func setRestoreOnLaunch(_ restore: Bool, in defaults: UserDefaults) {
        defaults.set(restore, forKey: restoreKey)
    }

    static func load(from defaults: UserDefaults = .standard) -> CLLocationCoordinate2D? {
        guard defaults.object(forKey: latKey) != nil else { return nil }
        return CLLocationCoordinate2D(
            latitude: defaults.double(forKey: latKey),
            longitude: defaults.double(forKey: lonKey)
        )
    }

    static func save(_ coordinate: CLLocationCoordinate2D, to defaults: UserDefaults = .standard) {
        defaults.set(coordinate.latitude, forKey: latKey)
        defaults.set(coordinate.longitude, forKey: lonKey)
    }
}
