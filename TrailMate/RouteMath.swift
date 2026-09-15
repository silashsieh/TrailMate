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

    // Geodesic length of a polyline, in meters. CLLocation.distance per segment
    // for the same reason joinSegments compares in meters — and because a
    // geometric route's length is what the sheet's time estimate divides by the
    // base speed (decision D6: geodesic for whole-route totals, flat per tick).
    nonisolated static func totalLengthMeters(_ coordinates: [CLLocationCoordinate2D]) -> Double {
        guard coordinates.count >= 2 else { return 0 }
        var total = 0.0
        for i in 1..<coordinates.count {
            total += CLLocation(latitude: coordinates[i - 1].latitude, longitude: coordinates[i - 1].longitude)
                .distance(from: CLLocation(latitude: coordinates[i].latitude, longitude: coordinates[i].longitude))
        }
        return total
    }
}
