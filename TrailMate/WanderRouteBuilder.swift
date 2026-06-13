import CoreLocation
import MapKit

// Builds a meandering polyline by chaining MKDirections hops between random
// points sampled around `center`. The user picks duration; total walked
// distance is duration × speed. Hops may leak slightly outside the disc by
// design — the result is a loose wander, not strict containment.
enum WanderRouteBuilder {
    struct Result {
        var coordinates: [CLLocationCoordinate2D]
        var distanceMeters: Double
        var hopFailures: Int
    }

    struct Options {
        var center: CLLocationCoordinate2D
        var radiusMeters: Double
        var durationSeconds: TimeInterval
        var speedMPS: Double
        var transportType: MKDirectionsTransportType
        var sampleRadiusScale: Double = 1.5
        var maxHops: Int = 100
        var maxConsecutiveFailures: Int = 3
        var bearingRejectDegrees: Double = 45
        var bearingRetries: Int = 5
        var trimOvershootFraction: Double = 0.05
    }

    enum BuilderError: Error, LocalizedError {
        case noHopsSucceeded

        var errorDescription: String? {
            switch self {
            case .noHopsSucceeded: "Wander aborted: no walkable routes nearby."
            }
        }
    }

    private static let metersPerDegLat = 111_320.0

    static func build(options: Options, router: any RoutingService) async throws -> Result {
        let targetMeters = max(0, options.speedMPS * options.durationSeconds)
        let sampleRadius = options.radiusMeters * options.sampleRadiusScale

        var polyline: [CLLocationCoordinate2D] = [options.center]
        var current = options.center
        var prevBearing: Double? = nil
        var accumulated: Double = 0
        var hops = 0
        var consecutiveFailures = 0
        var totalFailures = 0
        var successes = 0

        while accumulated < targetMeters && hops < options.maxHops {
            let target = sampleTarget(
                center: options.center,
                sampleRadius: sampleRadius,
                from: current,
                prevBearing: prevBearing,
                rejectDeltaDegrees: options.bearingRejectDegrees,
                maxRetries: options.bearingRetries
            )

            do {
                let hop = try await router.calculateHop(
                    from: current,
                    to: target,
                    transportType: options.transportType
                )
                let segment = hop.coordinates
                let distance = hop.distanceMeters
                if segment.count > 1 {
                    polyline.append(contentsOf: segment.dropFirst())
                    accumulated += distance
                    prevBearing = bearing(from: current, to: target)
                    current = target
                    successes += 1
                    consecutiveFailures = 0
                } else {
                    consecutiveFailures += 1
                    totalFailures += 1
                }
            } catch {
                consecutiveFailures += 1
                totalFailures += 1
                if consecutiveFailures >= options.maxConsecutiveFailures { break }
            }
            hops += 1
        }

        guard successes > 0 else { throw BuilderError.noHopsSucceeded }

        let overshootCap = targetMeters * (1 + options.trimOvershootFraction)
        if accumulated > overshootCap, polyline.count > 2 {
            (polyline, accumulated) = trimTail(polyline: polyline, target: targetMeters)
        }

        return Result(coordinates: polyline, distanceMeters: accumulated, hopFailures: totalFailures)
    }

    // MARK: - Sampling

    private static func sampleTarget(
        center: CLLocationCoordinate2D,
        sampleRadius: Double,
        from: CLLocationCoordinate2D,
        prevBearing: Double?,
        rejectDeltaDegrees: Double,
        maxRetries: Int
    ) -> CLLocationCoordinate2D {
        let rejectDelta = rejectDeltaDegrees * .pi / 180
        var candidate = uniformPointInDisc(center: center, radius: sampleRadius)
        guard let prev = prevBearing else { return candidate }

        // The bearing-bias rule prevents the wander from oscillating between
        // two nearby points: reject candidates whose direction from `from` is
        // within ±rejectDelta of the prior hop's bearing. After a few rejects
        // we accept anyway so the loop always makes progress.
        for _ in 0..<maxRetries {
            let candidateBearing = bearing(from: from, to: candidate)
            if angularDifference(candidateBearing, prev) >= rejectDelta {
                return candidate
            }
            candidate = uniformPointInDisc(center: center, radius: sampleRadius)
        }
        return candidate
    }

    static func uniformPointInDisc(
        center: CLLocationCoordinate2D,
        radius: Double
    ) -> CLLocationCoordinate2D {
        // r = R·√u, θ = 2πv gives uniform sampling over the disc area.
        let u = Double.random(in: 0..<1)
        let v = Double.random(in: 0..<1)
        let r = radius * u.squareRoot()
        let theta = 2 * .pi * v

        let dxMeters = r * cos(theta)
        let dyMeters = r * sin(theta)

        let metersPerDegLon = metersPerDegLat * cos(center.latitude * .pi / 180)
        let dLat = dyMeters / metersPerDegLat
        let dLon = metersPerDegLon > 0 ? dxMeters / metersPerDegLon : 0
        return CLLocationCoordinate2D(latitude: center.latitude + dLat, longitude: center.longitude + dLon)
    }

    // MARK: - Geometry

    static func bearing(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) -> Double {
        let lat1 = from.latitude * .pi / 180
        let lat2 = to.latitude * .pi / 180
        let dLon = (to.longitude - from.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let theta = atan2(y, x)
        return theta < 0 ? theta + 2 * .pi : theta
    }

    static func angularDifference(_ a: Double, _ b: Double) -> Double {
        let diff = abs(a - b).truncatingRemainder(dividingBy: 2 * .pi)
        return min(diff, 2 * .pi - diff)
    }

    // MARK: - Tail trim

    private static func trimTail(
        polyline: [CLLocationCoordinate2D],
        target: Double
    ) -> ([CLLocationCoordinate2D], Double) {
        var cumulative: Double = 0
        var lastIdx = polyline.count - 1
        for i in 1..<polyline.count {
            let segLen = CLLocation(latitude: polyline[i - 1].latitude, longitude: polyline[i - 1].longitude)
                .distance(from: CLLocation(latitude: polyline[i].latitude, longitude: polyline[i].longitude))
            if cumulative + segLen >= target {
                lastIdx = i
                cumulative += segLen
                break
            }
            cumulative += segLen
        }
        guard lastIdx >= 1 else { return (polyline, cumulative) }
        return (Array(polyline.prefix(lastIdx + 1)), cumulative)
    }
}
