import CoreLocation
import Foundation

struct SavedRoute: Identifiable, Codable, Hashable {
    struct Coord: Codable, Hashable {
        let lat: Double
        let lon: Double
    }

    // Planner-editable input snapshot. Distinct from `coordinates` (the flat
    // playback polyline) so a saved route can be re-loaded into From/To/stops
    // fields and re-calculated. Nil on routes saved before this field existed
    // and on routes whose source has no editable inputs (recorded / imported).
    struct NamedCoord: Codable, Hashable {
        let lat: Double
        let lon: Double
        let label: String?
    }

    let id: UUID
    var name: String
    let createdAt: Date
    let transportModeRaw: String
    let customSpeedKmh: Double?
    let coordinates: [Coord]
    // "calculated" | "direct" | "recorded" | "imported"
    let source: String
    let sourceDetail: String?
    let fromWaypoint: NamedCoord?
    let toWaypoint: NamedCoord?
    let stopWaypoints: [NamedCoord]?

    var transportMode: TransportMode {
        TransportMode(rawValue: transportModeRaw) ?? .walk
    }

    var clCoordinates: [CLLocationCoordinate2D] {
        coordinates.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
    }

    var distanceMeters: Double {
        guard coordinates.count >= 2 else { return 0 }
        var total = 0.0
        for i in 1..<coordinates.count {
            let a = CLLocation(latitude: coordinates[i - 1].lat, longitude: coordinates[i - 1].lon)
            let b = CLLocation(latitude: coordinates[i].lat, longitude: coordinates[i].lon)
            total += a.distance(from: b)
        }
        return total
    }
}

@Observable
@MainActor
final class SavedRoutesStore {
    private(set) var routes: [SavedRoute] = []

    nonisolated static var baseURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("TrailMate").appendingPathComponent("routes")
    }

    func load() {
        let base = Self.baseURL
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else {
            routes = []
            return
        }
        let decoder = JSONDecoder()
        var loaded: [SavedRoute] = []
        for file in files where file.pathExtension.lowercased() == "json" {
            if let data = try? Data(contentsOf: file),
               let route = try? decoder.decode(SavedRoute.self, from: data) {
                loaded.append(route)
            }
        }
        routes = loaded.sorted(by: { $0.createdAt > $1.createdAt })
    }

    func save(_ route: SavedRoute) throws {
        let base = Self.baseURL
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let url = base.appendingPathComponent("\(route.id.uuidString).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(route)
        try data.write(to: url, options: .atomic)
        load()
    }

    func delete(_ route: SavedRoute) {
        let url = Self.baseURL.appendingPathComponent("\(route.id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
        routes.removeAll { $0.id == route.id }
    }
}
