import CoreLocation
import Testing
@testable import TrailMate

// LocationNoise's RNG is not injectable, so these are statistical tests.
// Tolerances sit at ≥10 standard errors for N = 10_000 (stderr of the mean
// is σ/√N ≈ 0.05 m; stderr of the sample σ is σ/√(2N) ≈ 0.035 m), which puts
// the flake probability far below anything CI could ever hit.
struct LocationNoiseTests {
    private let base = CLLocationCoordinate2D(latitude: 25.0, longitude: 121.5)
    private static let metersPerDegLat = 111_320.0

    private func meterOffsets(sigma: Double, samples: Int) -> (dx: [Double], dy: [Double]) {
        let noise = LocationNoise()
        noise.sigmaMeters = sigma
        let metersPerDegLon = Self.metersPerDegLat * cos(base.latitude * .pi / 180)
        var dx: [Double] = []
        var dy: [Double] = []
        for _ in 0..<samples {
            let jittered = noise.apply(to: base)
            dy.append((jittered.latitude - base.latitude) * Self.metersPerDegLat)
            dx.append((jittered.longitude - base.longitude) * metersPerDegLon)
        }
        return (dx, dy)
    }

    private func sampleStd(_ values: [Double]) -> Double {
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        return variance.squareRoot()
    }

    @Test func zeroSigmaIsIdentity() {
        let noise = LocationNoise()
        noise.sigmaMeters = 0
        let result = noise.apply(to: base)
        #expect(result.latitude == base.latitude)
        #expect(result.longitude == base.longitude)
    }

    @Test func meanOffsetNearZero() {
        let (dx, dy) = meterOffsets(sigma: 5, samples: 10_000)
        #expect(abs(dx.reduce(0, +) / Double(dx.count)) < 0.5)
        #expect(abs(dy.reduce(0, +) / Double(dy.count)) < 0.5)
    }

    @Test func sampleStdMatchesSigma() {
        let (dx, dy) = meterOffsets(sigma: 5, samples: 10_000)
        #expect(sampleStd(dx) > 4.5 && sampleStd(dx) < 5.5)
        #expect(sampleStd(dy) > 4.5 && sampleStd(dy) < 5.5)
    }

    @Test func spreadScalesWithSigma() {
        let (dx, dy) = meterOffsets(sigma: 20, samples: 10_000)
        #expect(sampleStd(dx) > 18 && sampleStd(dx) < 22)
        #expect(sampleStd(dy) > 18 && sampleStd(dy) < 22)
    }
}
