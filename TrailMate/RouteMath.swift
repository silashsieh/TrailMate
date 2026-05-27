import CoreLocation

enum RouteMath {
    // MKDirections quantizes segment endpoints at meter scale, so adjacent
    // route segments often have nearly-identical join vertices. Compare in
    // meters via CLLocation.distance — a degree-based tolerance over-dedupes
    // near the equator and under-dedupes near the poles.
    nonisolated static func joinSegments(
        _ a: [CLLocationCoordinate2D],
        _ b: [CLLocationCoordinate2D],
        toleranceMeters: Double = 2.0
    ) -> [CLLocationCoordinate2D] {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        let lastA = CLLocation(latitude: a.last!.latitude, longitude: a.last!.longitude)
        let firstB = CLLocation(latitude: b.first!.latitude, longitude: b.first!.longitude)
        if lastA.distance(from: firstB) <= toleranceMeters {
            return a + b.dropFirst()
        }
        return a + b
    }
}
