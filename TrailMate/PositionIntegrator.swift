import CoreLocation

// Owned exclusively by SimulationActor. Marked nonisolated because the
// project sets default actor isolation to MainActor.
nonisolated final class PositionIntegrator {
    private(set) var position: CLLocationCoordinate2D?

    private static let metersPerDegLat = 111_320.0

    func reset(to coord: CLLocationCoordinate2D) {
        position = coord
    }

    func clear() {
        position = nil
    }

    // Velocity is in m/s on the local-flat ENU frame (vx = east, vy = north).
    func step(vx: Double, vy: Double, dt: TimeInterval) {
        guard var pos = position else { return }
        guard vx != 0 || vy != 0 else { return }

        let dxMeters = vx * dt
        let dyMeters = vy * dt

        let latRad = pos.latitude * .pi / 180
        let metersPerDegLon = Self.metersPerDegLat * cos(latRad)

        pos.latitude += dyMeters / Self.metersPerDegLat
        pos.longitude += dxMeters / metersPerDegLon
        position = pos
    }
}
