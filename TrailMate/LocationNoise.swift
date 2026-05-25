import CoreLocation
import Foundation

// Owned exclusively by SimulationActor. Marked nonisolated because the
// project sets default actor isolation to MainActor.
nonisolated final class LocationNoise {
    var sigmaMeters: Double = 5.0

    private static let metersPerDegLat = 111_320.0

    func apply(to coord: CLLocationCoordinate2D) -> CLLocationCoordinate2D {
        guard sigmaMeters > 0 else { return coord }

        let dxMeters = gaussianSample() * sigmaMeters
        let dyMeters = gaussianSample() * sigmaMeters

        let latRad = coord.latitude * .pi / 180
        let metersPerDegLon = Self.metersPerDegLat * cos(latRad)

        return CLLocationCoordinate2D(
            latitude: coord.latitude + dyMeters / Self.metersPerDegLat,
            longitude: coord.longitude + dxMeters / metersPerDegLon
        )
    }

    // Box-Muller transform: two uniform draws → one standard-normal sample.
    // We discard the second output; sampling twice per call is cheap at <=20Hz.
    private func gaussianSample() -> Double {
        let u1 = max(Double.leastNonzeroMagnitude, Double.random(in: 0...1))
        let u2 = Double.random(in: 0...1)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
