import CoreLocation

// Pure geometry for hand-drawn route strokes: Chaikin corner-cutting to take
// the hand jitter out of the path shape, then uniform arc-length resampling
// for even, non-degenerate vertices. Playback speed is steady regardless —
// NavigationEngine advances by arc length — so none of this is about timing.
enum StrokeGeometry {
    // The resampler never emits consecutive vertices closer than this.
    // NavigationEngine zero-guards degenerate segments (they stall a tick at
    // worst), but a clean contract here beats a downstream surprise. Meters-
    // based for the same reason as RouteMath.joinSegments.
    nonisolated static let minSeparationMeters = 0.5

    // Resample spacing tied to the transport speed: ~one vertex per second of
    // 1× playback. Pure vertex economy — finer spacing buys shape detail
    // exactly where slow playback (and a zoomed-in map) makes it visible.
    // Walk clamps to the 2 m floor; fast custom speeds cap at 15 m.
    nonisolated static func spacing(forSpeedMPS speed: Double) -> Double {
        min(max(speed * 1.0, 2.0), 15.0)
    }

    // One pass replaces every segment with cut points at its 1/4 and 3/4
    // marks, converging toward a quadratic B-spline; endpoints are kept
    // exactly. Linear blends on raw degrees are fine at stroke scale — the
    // local-flat error over a few km is far below GPS noise.
    nonisolated static func chaikin(
        _ points: [CLLocationCoordinate2D],
        iterations: Int = 2
    ) -> [CLLocationCoordinate2D] {
        guard points.count > 2, iterations > 0 else { return points }
        var result = points
        for _ in 0..<iterations {
            var next: [CLLocationCoordinate2D] = [result[0]]
            next.reserveCapacity(result.count * 2)
            for i in 0..<(result.count - 1) {
                let a = result[i]
                let b = result[i + 1]
                next.append(CLLocationCoordinate2D(
                    latitude: a.latitude * 0.75 + b.latitude * 0.25,
                    longitude: a.longitude * 0.75 + b.longitude * 0.25
                ))
                next.append(CLLocationCoordinate2D(
                    latitude: a.latitude * 0.25 + b.latitude * 0.75,
                    longitude: a.longitude * 0.25 + b.longitude * 0.75
                ))
            }
            next.append(result[result.count - 1])
            result = next
        }
        return result
    }

    // Emit one vertex every `spacingMeters` of arc length, keeping both
    // endpoints exactly. Returns nil for strokes that don't amount to a route
    // (total length under one spacing, or everything collapsing onto the
    // start point) — callers must never hand NavigationEngine a stroke that
    // was really a click or a jitter blob.
    nonisolated static func resampleUniform(
        _ points: [CLLocationCoordinate2D],
        spacingMeters: Double
    ) -> [CLLocationCoordinate2D]? {
        guard spacingMeters > 0, points.count >= 2 else { return nil }

        var cumulative: [Double] = [0]
        cumulative.reserveCapacity(points.count)
        for i in 1..<points.count {
            cumulative.append(cumulative[i - 1] + meters(points[i - 1], points[i]))
        }
        guard let total = cumulative.last, total >= spacingMeters else { return nil }

        var result: [CLLocationCoordinate2D] = [points[0]]
        var segment = 0
        var target = spacingMeters
        while target < total {
            while cumulative[segment + 1] < target { segment += 1 }
            let segLen = cumulative[segment + 1] - cumulative[segment]
            let fraction = segLen > 0 ? (target - cumulative[segment]) / segLen : 1
            let a = points[segment]
            let b = points[segment + 1]
            let sample = CLLocationCoordinate2D(
                latitude: a.latitude + (b.latitude - a.latitude) * fraction,
                longitude: a.longitude + (b.longitude - a.longitude) * fraction
            )
            // A switchback can fold samples a full spacing apart in arc length
            // onto nearly the same spot — skip rather than emit a degenerate
            // segment.
            if meters(result.last!, sample) >= minSeparationMeters {
                result.append(sample)
            }
            target += spacingMeters
        }

        // End exactly where the stroke ended.
        let end = points[points.count - 1]
        if meters(result.last!, end) >= minSeparationMeters {
            result.append(end)
        } else if result.count >= 2 {
            // The last sample crowds the endpoint — swap it out. The new tail
            // segment is strictly positive: its predecessor sits at least
            // minSeparation from the removed sample, the endpoint less.
            result.removeLast()
            result.append(end)
        } else {
            // Start and end collapse onto each other with nothing kept
            // between: a jitter blob, not a route.
            return nil
        }
        return result
    }

    private nonisolated static func meters(
        _ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D
    ) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }
}
