import CoreLocation
import MapKit

// Camera-framing math for the auto-pan-on-select feature (epic 029, #53).
// Pure functions over coordinates so they're unit-testable without a live Map.
enum MapRegionMath {
    // A modest box centered on a single point — enough context around a saved
    // location without yanking the zoom to street level.
    nonisolated static func region(
        around center: CLLocationCoordinate2D,
        edgeMeters: Double = 1_200
    ) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: center,
            latitudinalMeters: edgeMeters,
            longitudinalMeters: edgeMeters
        )
    }

    // The smallest lat/lon-aligned region that contains every coordinate, plus
    // padding so the polyline isn't flush against the edges. A degenerate input
    // (one point, or all-coincident points) falls back to the fixed point box so
    // the span never collapses to zero. nil for empty input.
    nonisolated static func boundingRegion(
        _ coordinates: [CLLocationCoordinate2D],
        paddingFactor: Double = 1.3,
        minimumEdgeMeters: Double = 400
    ) -> MKCoordinateRegion? {
        guard let first = coordinates.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coordinates.dropFirst() {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        // Floor each axis at a meters-based minimum so a tiny/degenerate route
        // still gets a sensible zoom. Convert the meters floor into degrees at
        // this latitude (longitude degrees shrink by cos(lat)).
        let minLatDelta = minimumEdgeMeters / 111_320.0
        let cosLat = max(0.01, cos(center.latitude * .pi / 180))
        let minLonDelta = minimumEdgeMeters / (111_320.0 * cosLat)

        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * paddingFactor, minLatDelta),
            longitudeDelta: max((maxLon - minLon) * paddingFactor, minLonDelta)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}
