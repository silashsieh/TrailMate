import Foundation

@Observable
@MainActor
final class SavedWaypointsStore {
    private static let storageKey = "savedWaypoints"

    private(set) var waypoints: [SavedWaypoint] = []
    let defaults: UserDefaults

    init(defaults: UserDefaults = AppProcessConfiguration.current.defaults) {
        self.defaults = defaults
    }

    func load() throws {
        guard let data = defaults.data(forKey: Self.storageKey) else {
            waypoints = []
            return
        }
        waypoints = try JSONDecoder().decode([SavedWaypoint].self, from: data)
    }

    func save(_ waypoint: SavedWaypoint) throws {
        if let index = waypoints.firstIndex(where: { $0.id == waypoint.id }) {
            waypoints[index] = waypoint
        } else {
            waypoints.append(waypoint)
        }
        try persist()
    }

    func delete(_ waypoint: SavedWaypoint) throws {
        waypoints.removeAll { $0.id == waypoint.id }
        try persist()
    }

    func rename(_ waypoint: SavedWaypoint, to newName: String) throws {
        guard let index = waypoints.firstIndex(where: { $0.id == waypoint.id }) else { return }
        waypoints[index].name = newName
        try persist()
    }

    func setCategory(_ category: String?, for waypoint: SavedWaypoint) throws {
        guard let index = waypoints.firstIndex(where: { $0.id == waypoint.id }) else { return }
        waypoints[index].category = category
        try persist()
    }

    func move(
        inCategory category: String?,
        movingIDs: [SavedWaypoint.ID],
        before destinationID: SavedWaypoint.ID?
    ) throws {
        let groupIDs = Set(waypoints.filter { $0.category == category }.map(\.id))
        waypoints = LibraryOrder.moveWithinGroup(
            waypoints,
            groupIDs: groupIDs,
            movingIDs: movingIDs,
            before: destinationID
        )
        try persist()
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(waypoints)
        defaults.set(data, forKey: Self.storageKey)
    }
}
