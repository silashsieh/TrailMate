import CoreLocation
import Testing
@testable import TrailMate

// Sweeping-mode geometry (epic 030). The builder is pure and deterministic, so
// every expectation here is exact or bounded by a stated tolerance — no
// statistical slack. Distances are checked with CLLocation.distance rather than
// against the builder's own 111_320 m/deg projection, so the tests are an
// independent oracle: the 1% band is the CLAUDE.md known-good-reference rule and
// covers the flat-projection-vs-WGS84 gap at kilometre scale.
struct CoverageRouteBuilderTests {
    // Taipei 101 — the reference center the other coordinate suites use.
    private let center = CLLocationCoordinate2D(latitude: 25.0339, longitude: 121.5645)

    private func build(
        halfSide: Double,
        spacing: Double,
        maxPoints: Int = 4_000,
        center: CLLocationCoordinate2D? = nil
    ) throws -> CoverageRouteBuilder.Result {
        try CoverageRouteBuilder.build(options: CoverageRouteBuilder.Options(
            center: center ?? self.center,
            halfSideMeters: halfSide,
            laneSpacingMeters: spacing,
            maxPoints: maxPoints
        ))
    }

    private func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    private func totalLength(_ pts: [CLLocationCoordinate2D]) -> Double {
        zip(pts, pts.dropFirst()).reduce(0) { $0 + meters($1.0, $1.1) }
    }

    // Signed offsets from the center, measured along each axis with CoreLocation
    // so containment isn't checked against the projection under test.
    private func northing(_ p: CLLocationCoordinate2D) -> Double {
        let magnitude = meters(center, CLLocationCoordinate2D(latitude: p.latitude, longitude: center.longitude))
        return p.latitude >= center.latitude ? magnitude : -magnitude
    }

    private func easting(_ p: CLLocationCoordinate2D) -> Double {
        let magnitude = meters(center, CLLocationCoordinate2D(latitude: center.latitude, longitude: p.longitude))
        return p.longitude >= center.longitude ? magnitude : -magnitude
    }

    // MARK: - Serpentine order

    @Test func lanesAlternateDirectionAndStepNorth() throws {
        // 500 m half-side at 100 m spacing: 1000 / 100 = 10 gaps, so 11 lanes of
        // two points each.
        let result = try build(halfSide: 500, spacing: 100)
        #expect(result.laneCount == 11)
        #expect(result.coordinates.count == 22)

        for lane in 0..<result.laneCount {
            let start = result.coordinates[lane * 2]
            let end = result.coordinates[lane * 2 + 1]
            // A lane holds its latitude and crosses the full square.
            #expect(abs(start.latitude - end.latitude) < 1e-12)
            if lane.isMultiple(of: 2) {
                #expect(start.longitude < end.longitude)   // west to east
            } else {
                #expect(start.longitude > end.longitude)   // and back east to west
            }
            if lane > 0 {
                #expect(start.latitude > result.coordinates[(lane - 1) * 2].latitude)
            }
        }
    }

    // MARK: - The square

    @Test func squareIsCenteredWithSideTwiceTheRadius() throws {
        let result = try build(halfSide: 500, spacing: 100)
        let pts = result.coordinates

        // A lane spans the full side: 2 x 500 m within 1%.
        #expect(abs(meters(pts[0], pts[1]) - 1000) < 10)

        // At 100 m spacing the lanes divide 1000 m exactly, so they reach both
        // the south and north edges: the north-south extent is the side too.
        let latitudes = pts.map(\.latitude)
        let south = CLLocationCoordinate2D(latitude: latitudes.min()!, longitude: center.longitude)
        let north = CLLocationCoordinate2D(latitude: latitudes.max()!, longitude: center.longitude)
        #expect(abs(meters(south, north) - 1000) < 10)

        // ...and the whole thing is centered on the selected point.
        let longitudes = pts.map(\.longitude)
        #expect(abs((latitudes.min()! + latitudes.max()!) / 2 - center.latitude) < 1e-9)
        #expect(abs((longitudes.min()! + longitudes.max()!) / 2 - center.longitude) < 1e-9)
    }

    @Test func everyPointIsInsideTheSquareAndTheFirstSitsOnTheWestEdge() throws {
        let halfSide = 500.0
        let result = try build(halfSide: halfSide, spacing: 70)
        let tolerance = halfSide * 0.01 + 0.5   // 1% reference band plus float slack

        for point in result.coordinates {
            #expect(abs(northing(point)) <= halfSide + tolerance)
            #expect(abs(easting(point)) <= halfSide + tolerance)
        }

        // Reset-start teleports to this point, so it has to be a real boundary
        // point: the west end of the southernmost lane.
        let first = result.coordinates[0]
        #expect(abs(easting(first) + halfSide) < tolerance)
        #expect(first.latitude == result.coordinates.map(\.latitude).min()!)
    }

    // MARK: - Lane spacing

    @Test func laneSpacingMatchesCoreLocationReference() throws {
        let spacing = 70.0
        let result = try build(halfSide: 500, spacing: spacing)
        // floor(1000 / 70) = 14 gaps -> 15 lanes.
        #expect(result.laneCount == 15)

        // The connector between lanes is the pure north step, so it measures the
        // spacing directly: lane k's end to lane k+1's start.
        for lane in 0..<(result.laneCount - 1) {
            let step = meters(result.coordinates[lane * 2 + 1], result.coordinates[lane * 2 + 2])
            #expect(abs(step - spacing) < spacing * 0.01)
        }
    }

    // MARK: - Determinism

    @Test func identicalInputsProduceIdenticalCoordinates() throws {
        let a = try build(halfSide: 375, spacing: 55)
        let b = try build(halfSide: 375, spacing: 55)
        #expect(a.coordinates.count == b.coordinates.count)
        for (lhs, rhs) in zip(a.coordinates, b.coordinates) {
            #expect(lhs.latitude == rhs.latitude)
            #expect(lhs.longitude == rhs.longitude)
        }
        #expect(a.distanceMeters == b.distanceMeters)
        // Orientation is fixed, not derived from the inputs: still west-to-east
        // along the southernmost lane.
        #expect(a.coordinates[0].longitude < a.coordinates[1].longitude)
        #expect(a.coordinates[0].latitude == a.coordinates.map(\.latitude).min()!)
    }

    // MARK: - Edge cases

    @Test func squareNarrowerThanTheSpacingSweepsOneCenterLane() throws {
        // 200 m square, 500 m spacing: no room for a second lane, so the useful
        // answer is one edge-to-edge pass through the middle.
        let result = try build(halfSide: 100, spacing: 500)
        #expect(result.laneCount == 1)
        #expect(result.coordinates.count == 2)
        #expect(abs(result.coordinates[0].latitude - center.latitude) < 1e-12)
        #expect(abs(result.distanceMeters - 200) < 2)
    }

    @Test func invalidGeometryThrows() {
        let bad: [(Double, Double)] = [
            (0, 70), (-100, 70), (.nan, 70), (.infinity, 70),
            (500, 0), (500, -70), (500, .nan), (500, .infinity),
        ]
        for (halfSide, spacing) in bad {
            #expect(throws: CoverageRouteBuilder.BuilderError.invalidGeometry) {
                _ = try build(halfSide: halfSide, spacing: spacing)
            }
        }

        for badCenter in [
            CLLocationCoordinate2D(latitude: .nan, longitude: 121.5645),
            CLLocationCoordinate2D(latitude: 25.0339, longitude: .infinity),
            CLLocationCoordinate2D(latitude: 91, longitude: 121.5645),
        ] {
            #expect(throws: CoverageRouteBuilder.BuilderError.invalidGeometry) {
                _ = try build(halfSide: 500, spacing: 70, center: badCenter)
            }
        }

        // A spacing so small that side / spacing overflows to +inf: it has to
        // fail cleanly rather than trap on the Int conversion.
        #expect(throws: CoverageRouteBuilder.BuilderError.invalidGeometry) {
            _ = try build(halfSide: 500, spacing: .leastNonzeroMagnitude)
        }
    }

    @Test func noDuplicatePointsAndNoRepeatedSegment() throws {
        let result = try build(halfSide: 500, spacing: 70)

        var segments = Set<String>()
        for (a, b) in zip(result.coordinates, result.coordinates.dropFirst()) {
            #expect(meters(a, b) >= 0.5)
            // Unordered key: retracing a lane in reverse counts as a repeat.
            let ends = [
                String(format: "%.7f,%.7f", a.latitude, a.longitude),
                String(format: "%.7f,%.7f", b.latitude, b.longitude),
            ].sorted()
            #expect(segments.insert(ends.joined(separator: "|")).inserted)
        }
        #expect(segments.count == result.coordinates.count - 1)
    }

    @Test func absurdDensityHitsThePointCap() {
        // 4 km square at 5 cm spacing: 160 002 points, refused up front.
        #expect(throws: CoverageRouteBuilder.BuilderError.tooManyPoints(limit: 4_000)) {
            _ = try build(halfSide: 2_000, spacing: 0.05)
        }
        // The cap is a parameter, not a constant.
        #expect(throws: CoverageRouteBuilder.BuilderError.tooManyPoints(limit: 10)) {
            _ = try build(halfSide: 500, spacing: 70, maxPoints: 10)
        }
    }

    // MARK: - Length and time estimate

    @Test func routeLengthAndEstimateFollowTheEmittedCoordinates() throws {
        let result = try build(halfSide: 500, spacing: 100)
        // 11 lanes across a 1000 m square plus 10 connectors of 100 m.
        let expected = 11.0 * 1000 + 10.0 * 100
        #expect(abs(result.distanceMeters - expected) < expected * 0.01)
        // The reported length is measured off the coordinates themselves.
        #expect(abs(result.distanceMeters - totalLength(result.coordinates)) < 0.001)
        #expect(abs(result.distanceMeters - RouteMath.totalLengthMeters(result.coordinates)) < 0.001)

        let walk = 1.4
        let seconds = try #require(CoverageRouteBuilder.estimatedSeconds(
            distanceMeters: result.distanceMeters, speedMPS: walk
        ))
        #expect(abs(seconds - result.distanceMeters / walk) < 1e-9)

        for badSpeed in [0.0, -1.0, Double.nan, Double.infinity] {
            #expect(CoverageRouteBuilder.estimatedSeconds(distanceMeters: 1_000, speedMPS: badSpeed) == nil)
        }
        #expect(CoverageRouteBuilder.estimatedSeconds(distanceMeters: .nan, speedMPS: walk) == nil)
    }
}

// The Sweeping/Random choice is persisted as a rawValue, so the decode side needs
// to survive an unset key and anything hand-edited into it.
struct WanderModePersistenceTests {
    @Test func knownRawValuesRoundTrip() {
        #expect(WanderMode(persisted: "sweeping") == .sweeping)
        #expect(WanderMode(persisted: "random") == .random)
        #expect(WanderMode.sweeping.rawValue == "sweeping")
    }

    @Test func unsetOrUnknownFallsBackToRandom() {
        #expect(WanderMode(persisted: nil) == .random)
        #expect(WanderMode(persisted: "") == .random)
        #expect(WanderMode(persisted: "Sweeping") == .random)   // rawValues are lowercase
        #expect(WanderMode(persisted: "garbage") == .random)
    }
}

// The other half of Sweeping: the route has to reach the session and playback has
// to start from the square's edge, not from the point the user clicked. Runs with
// no device — the sweep drives the local red dot like every other route source.
@MainActor
struct SweepAreaHandoffTests {
    @Test func sweepLoadsTheRouteAndStartsFromTheFirstEdgePoint() async throws {
        let suiteName = "com.sh.TrailMateTests.SweepArea.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        SimulatedPositionPersistence.setRestoreOnLaunch(false, in: defaults)

        let app = AppState(defaults: defaults)
        // Keep dispatch's lazy discovery scan from shelling out to the real lister.
        app.discovery.hasScanned = true
        let session = app.sessions[0]

        let center = CLLocationCoordinate2D(latitude: 25.0339, longitude: 121.5645)
        let halfSide = 300.0
        await app.sweepArea(center: center, halfSideMeters: halfSide, laneSpacingMeters: 100)
        app.stopPlayback()   // sweepArea auto-plays; don't leave a loop running

        let expected = try CoverageRouteBuilder.build(options: CoverageRouteBuilder.Options(
            center: center, halfSideMeters: halfSide, laneSpacingMeters: 100
        ))
        #expect(session.routeCoordinates.count == expected.coordinates.count)
        let first = try #require(session.routeCoordinates.first)
        #expect(first.latitude == expected.coordinates[0].latitude)
        #expect(first.longitude == expected.coordinates[0].longitude)

        // The marker teleported out to the west edge rather than staying on the
        // selected center — the jump reset-start performs before playback.
        let position = try #require(await session.sim.integratorPosition)
        let toFirst = CLLocation(latitude: position.latitude, longitude: position.longitude)
            .distance(from: CLLocation(latitude: first.latitude, longitude: first.longitude))
        let toCenter = CLLocation(latitude: position.latitude, longitude: position.longitude)
            .distance(from: CLLocation(latitude: center.latitude, longitude: center.longitude))
        #expect(toFirst < 10)                  // at the edge point (a tick of travel at most)
        #expect(toCenter > halfSide * 0.9)     // and nowhere near the center
    }

    @Test func aFailedSweepLeavesTheLoadedRouteAlone() async throws {
        let suiteName = "com.sh.TrailMateTests.SweepAreaInvalid.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        SimulatedPositionPersistence.setRestoreOnLaunch(false, in: defaults)

        let app = AppState(defaults: defaults)
        app.discovery.hasScanned = true
        let session = app.sessions[0]

        let center = CLLocationCoordinate2D(latitude: 25.0339, longitude: 121.5645)
        await app.sweepArea(center: center, halfSideMeters: 0, laneSpacingMeters: 100)
        #expect(session.routeCoordinates.isEmpty)
        #expect(app.logMessages.contains { $0.contains("Sweep failed") })
    }
}
