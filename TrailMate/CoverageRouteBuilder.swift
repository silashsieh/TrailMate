import CoreLocation

// Geometric boustrophedon ("mow the lawn") coverage of a north-up square
// centered on a map point — the Wander sheet's Sweeping mode. Direct movement
// like travelDirectly and hand-drawn routes: no MKDirections, nothing snaps to
// roads, and the output is a plain polyline the existing playback path consumes.
//
// Deterministic by construction — nothing is sampled, so identical inputs give
// identical coordinates. Lanes run east-west and step south to north, and the
// first coordinate is the west end of the southernmost lane; that is why loading
// the route with resetStart jumps the marker from the selected center out to the
// square's west edge before playback starts.
enum CoverageRouteBuilder {
    nonisolated struct Options: Sendable {
        var center: CLLocationCoordinate2D
        // The sheet's radius, read as the center-to-edge half-side: the square's
        // side is exactly 2 x this. Not a corner distance.
        var halfSideMeters: Double
        var laneSpacingMeters: Double
        // Practical size limit. 4 000 points is 2 000 lanes — orders of magnitude
        // past any useful sweep (radius 2 km at the 70 m default is 58 lanes), so
        // it only ever catches an absurd spacing, and it catches it before the
        // allocation rather than after.
        var maxPoints: Int = 4_000
    }

    nonisolated struct Result: Sendable {
        var coordinates: [CLLocationCoordinate2D]
        var distanceMeters: Double
        var laneCount: Int
    }

    // Log-only text, deliberately unlocalized — same call as WanderRouteBuilder's
    // BuilderError. The sheet surfaces its own localized warning instead.
    nonisolated enum BuilderError: Error, LocalizedError, Equatable, Sendable {
        case invalidGeometry
        case tooManyPoints(limit: Int)

        var errorDescription: String? {
            switch self {
            case .invalidGeometry:
                "Sweep aborted: center, radius, or lane spacing is not a usable value."
            case .tooManyPoints(let limit):
                "Sweep aborted: this radius and lane spacing need more than \(limit) points — widen the spacing."
            }
        }
    }

    private nonisolated static let metersPerDegLat = 111_320.0

    nonisolated static func build(options: Options) throws -> Result {
        let halfSide = options.halfSideMeters
        let spacing = options.laneSpacingMeters
        guard CLLocationCoordinate2DIsValid(options.center),
              options.center.latitude.isFinite, options.center.longitude.isFinite,
              halfSide.isFinite, halfSide > 0,
              spacing.isFinite, spacing > 0,
              options.maxPoints >= 2
        else { throw BuilderError.invalidGeometry }

        let side = halfSide * 2

        // Stay in Double until the count is known small: side/spacing can be
        // +inf for a subnormal spacing, and Int(+inf) / Int(1e30) trap.
        let gaps = (side / spacing).rounded(.down)
        guard gaps.isFinite else { throw BuilderError.invalidGeometry }
        guard (gaps + 1) * 2 <= Double(options.maxPoints) else {
            throw BuilderError.tooManyPoints(limit: options.maxPoints)
        }
        let laneCount = Int(gaps) + 1

        // Center the lane set between the south and north edges: the leftover
        // strip is split evenly, so a square narrower than one spacing collapses
        // to a single center lane running edge to edge instead of hugging the
        // south edge.
        let laneInset = (side - Double(laneCount - 1) * spacing) / 2

        // One projection for the whole square (longitude degrees shrink by
        // cos(lat)); the cos clamp mirrors MapRegionMath so a near-polar center
        // can't divide the easting by ~0.
        let metersPerDegLon = metersPerDegLat * max(0.01, cos(options.center.latitude * .pi / 180))

        var coordinates: [CLLocationCoordinate2D] = []
        coordinates.reserveCapacity(laneCount * 2)
        for lane in 0..<laneCount {
            let northing = -halfSide + laneInset + Double(lane) * spacing
            // Even lanes run west to east, odd lanes back east to west: every
            // lane reverses the last one, and the connectors between them ride
            // the west and east edges, so no segment is ever retraced.
            let startsWest = lane.isMultiple(of: 2)
            coordinates.append(coordinate(
                center: options.center, metersPerDegLon: metersPerDegLon,
                easting: startsWest ? -halfSide : halfSide, northing: northing
            ))
            coordinates.append(coordinate(
                center: options.center, metersPerDegLon: metersPerDegLon,
                easting: startsWest ? halfSide : -halfSide, northing: northing
            ))
        }

        // Measured over the emitted coordinates, not the ideal lane arithmetic,
        // so the sheet's estimate is the length the engine will actually walk.
        return Result(
            coordinates: coordinates,
            distanceMeters: RouteMath.totalLengthMeters(coordinates),
            laneCount: laneCount
        )
    }

    // Playback time for a geometric route: the engine advances by arc length at
    // the base speed, so length / speed is the whole story. nil rather than a
    // bogus number when the speed can't produce one.
    nonisolated static func estimatedSeconds(distanceMeters: Double, speedMPS: Double) -> TimeInterval? {
        guard distanceMeters.isFinite, distanceMeters >= 0,
              speedMPS.isFinite, speedMPS > 0 else { return nil }
        return distanceMeters / speedMPS
    }

    private nonisolated static func coordinate(
        center: CLLocationCoordinate2D,
        metersPerDegLon: Double,
        easting: Double,
        northing: Double
    ) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: center.latitude + northing / metersPerDegLat,
            longitude: center.longitude + easting / metersPerDegLon
        )
    }
}
