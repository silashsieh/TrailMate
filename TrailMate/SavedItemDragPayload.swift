import Foundation

// Namespaced text payloads let SwiftUI own the drag session while TrailMate
// commits only stable IDs at drop time. Keeping location and route namespaces
// distinct prevents an otherwise valid UUID from crossing library types.
enum SavedItemDragPayload {
    private nonisolated static let waypointPrefix = "com.sh.TrailMate.saved-waypoint:"
    private nonisolated static let routePrefix = "com.sh.TrailMate.saved-route:"

    nonisolated static func waypoint(_ id: UUID) -> String {
        waypointPrefix + id.uuidString
    }

    nonisolated static func route(_ id: UUID) -> String {
        routePrefix + id.uuidString
    }

    nonisolated static func waypointID(from payload: String) -> UUID? {
        id(from: payload, prefix: waypointPrefix)
    }

    nonisolated static func routeID(from payload: String) -> UUID? {
        id(from: payload, prefix: routePrefix)
    }

    private nonisolated static func id(from payload: String, prefix: String) -> UUID? {
        guard payload.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(payload.dropFirst(prefix.count)))
    }
}
