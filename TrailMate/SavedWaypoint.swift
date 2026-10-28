import CoreLocation
import Foundation

struct SavedWaypoint: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    // User-defined folder this waypoint lives under (epic 029). nil = ungrouped.
    // Keeping this optional preserves decoding of waypoints saved before folders.
    var category: String?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
