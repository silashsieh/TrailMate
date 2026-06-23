import CoreLocation

// Owned exclusively by SimulationActor. Marked nonisolated because the
// project sets default actor isolation to MainActor; without this, the
// actor couldn't synchronously call into the engine.
nonisolated final class NavigationEngine {
    enum PlaybackState: Equatable {
        case idle
        case playing
        case paused
    }

    enum LoopMode: Equatable {
        case off
        case restart
        case pingPong
    }

    var playbackState: PlaybackState = .idle
    var progress: Double = 0
    var elapsedDistance: Double = 0
    var totalDistance: Double = 0

    // Loop configuration — pushed from AppState via SimulationActor. Survives
    // stop()/loadRoute() so swapping routes doesn't silently drop the user's
    // setting. A count of 0 means infinite; the unit is one A→B pass
    // (restart) or one A→B→A round trip (ping-pong).
    private(set) var loopMode: LoopMode = .off
    private(set) var loopCount: Int = 0

    // Runtime loop state — reset by play()/stop().
    private(set) var completedLoops: Int = 0
    private var isReturning = false

    // Set by a seek on an idle route so the next play() starts from the
    // sought point instead of re-arming from the top. Consumed by play(),
    // cleared by stop().
    private var hasPendingSeek = false

    private(set) var coordinates: [CLLocationCoordinate2D] = []
    private var cumulativeDistances: [Double] = []
    private var projectedRoutePoints: [(x: Double, y: Double)] = []
    private var projectionOrigin: CLLocationCoordinate2D?
    private var projectionMetersPerDegLon: Double = 111_320.0
    private var currentDistanceAlongRoute: Double = 0
    private var baseSpeedMPS: Double = 1.4
    private var speedMultiplier: Double = 1.0

    private static let metersPerDegLat = 111_320.0

    func loadRoute(coordinates: [CLLocationCoordinate2D], baseSpeed: Double) {
        stop()
        self.coordinates = coordinates
        self.baseSpeedMPS = baseSpeed
        cacheProjectedRoutePoints(for: coordinates)

        var cumulative: [Double] = [0]
        for i in 1..<coordinates.count {
            let from = CLLocation(latitude: coordinates[i - 1].latitude, longitude: coordinates[i - 1].longitude)
            let to = CLLocation(latitude: coordinates[i].latitude, longitude: coordinates[i].longitude)
            cumulative.append(cumulative.last! + from.distance(from: to))
        }
        cumulativeDistances = cumulative
        totalDistance = cumulative.last ?? 0
        currentDistanceAlongRoute = 0
        progress = 0
        elapsedDistance = 0
    }

    func play(multiplier: Double) {
        speedMultiplier = multiplier
        // Starting fresh (not resuming a pause) re-arms from the top — without
        // this, Play on a route that already ran to completion would re-idle
        // instantly at the far end. A seek on the idle route overrides the
        // re-arm: Play then starts from the sought point.
        if playbackState == .idle && !hasPendingSeek {
            currentDistanceAlongRoute = 0
            progress = 0
            elapsedDistance = 0
            isReturning = false
            completedLoops = 0
        }
        hasPendingSeek = false
        playbackState = .playing
    }

    func pause() {
        if playbackState == .playing {
            playbackState = .paused
        }
    }

    func resume(multiplier: Double) {
        guard playbackState == .paused else { return }
        speedMultiplier = multiplier
        playbackState = .playing
    }

    func stop() {
        playbackState = .idle
        currentDistanceAlongRoute = 0
        progress = 0
        elapsedDistance = 0
        isReturning = false
        completedLoops = 0
        hasPendingSeek = false
    }

    // Jump the playhead to `fraction` (clamped to 0...1) of the current leg
    // and return the on-route coordinate there. Progress runs 0→1 per leg, so
    // on a ping-pong return leg the fraction maps back toward the route start
    // — the scrubber seeks within the leg it is displaying. Leaves
    // playbackState untouched — whether a scrub holds or continues playback
    // is the caller's policy, not the engine's. Seeking an idle route lands
    // on the forward leg and arms play() to start from the sought point.
    func seek(toProgress fraction: Double) -> CLLocationCoordinate2D? {
        guard totalDistance > 0, coordinates.count >= 2 else { return nil }
        let p = min(max(0, fraction), 1)
        if playbackState == .idle {
            isReturning = false
            completedLoops = 0
            hasPendingSeek = true
        }
        currentDistanceAlongRoute = isReturning ? totalDistance * (1 - p) : totalDistance * p
        updateLegProgress()
        return interpolate(at: currentDistanceAlongRoute)
    }

    func updateSpeed(_ multiplier: Double) {
        speedMultiplier = multiplier
    }

    func updateBaseSpeed(_ baseSpeed: Double) {
        baseSpeedMPS = baseSpeed
    }

    // Live-updatable mid-playback; the engine consults the config at each
    // leg boundary, so a mode/count change takes effect at the next end.
    func updateLoop(mode: LoopMode, count: Int) {
        loopMode = mode
        loopCount = max(0, count)
    }

    // Called by AppState's aggregator. Advances distance-along-route by
    // base * mult * dt and returns the local-flat (vx, vy) velocity that
    // the integrator should apply this tick, plus a jump coordinate when a
    // restart loop wrapped and the integrator must teleport back to the
    // route start. Returns nil when not playing.
    func tick(dt: TimeInterval) -> (vx: Double, vy: Double, jump: CLLocationCoordinate2D?)? {
        guard playbackState == .playing else { return nil }
        guard totalDistance > 0, coordinates.count >= 2 else {
            playbackState = .idle
            return nil
        }

        let fullSpeed = baseSpeedMPS * speedMultiplier
        let remainingOnLeg = isReturning
            ? currentDistanceAlongRoute
            : totalDistance - currentDistanceAlongRoute

        // Clamp the leg's final tick so the integrator lands on the endpoint
        // instead of overshooting by up to one tick of advance — ping-pong
        // would otherwise visibly shoot past the turnaround before reversing.
        // One boundary per tick also keeps sub-tick-length routes at high
        // multipliers trivially correct (no multi-wrap accounting).
        let speed = dt > 0 ? min(fullSpeed, remainingOnLeg / dt) : fullSpeed
        let advance = speed * dt
        let reachedLegEnd = advance >= remainingOnLeg - 0.000_1

        let newDistance = isReturning
            ? max(0, currentDistanceAlongRoute - advance)
            : min(totalDistance, currentDistanceAlongRoute + advance)
        let segIdx = segmentIndex(for: newDistance)

        let from = coordinates[segIdx]
        let to = coordinates[segIdx + 1]

        // Tangent in m/s, scaled by current speed and negated on the
        // ping-pong return leg. Direction comes from the segment the engine
        // is currently traversing, which is independent of where the
        // integrator's actual position happens to be (joystick may have
        // pushed it off-route).
        let latRad = from.latitude * .pi / 180
        let metersPerDegLon = Self.metersPerDegLat * cos(latRad)
        let dxMeters = (to.longitude - from.longitude) * metersPerDegLon
        let dyMeters = (to.latitude - from.latitude) * Self.metersPerDegLat
        let mag = (dxMeters * dxMeters + dyMeters * dyMeters).squareRoot()

        let sign = isReturning ? -1.0 : 1.0
        var vx = mag > 0 ? dxMeters / mag * speed * sign : 0
        var vy = mag > 0 ? dyMeters / mag * speed * sign : 0
        var jump: CLLocationCoordinate2D?

        currentDistanceAlongRoute = newDistance
        updateLegProgress()

        if reachedLegEnd {
            if isReturning {
                // Back at A — one ping-pong round trip complete. Also the
                // graceful exit when the mode changed mid-return-leg: finish
                // the walk back, then stop or restart per the new mode.
                completedLoops += 1
                if loopMode == .off || loopTargetReached {
                    playbackState = .idle
                } else {
                    isReturning = false
                }
            } else {
                switch loopMode {
                case .off:
                    playbackState = .idle
                case .restart:
                    completedLoops += 1
                    if loopTargetReached {
                        playbackState = .idle
                    } else {
                        // Replay from A: a deliberate jump, so this tick
                        // carries a teleport and no velocity.
                        currentDistanceAlongRoute = 0
                        updateLegProgress()
                        jump = coordinates.first
                        vx = 0
                        vy = 0
                    }
                case .pingPong:
                    isReturning = true
                }
            }
        }

        return (vx, vy, jump)
    }

    private var loopTargetReached: Bool {
        loopCount > 0 && completedLoops >= loopCount
    }

    // Progress and elapsed distance are per-leg: every pass (and each
    // ping-pong leg) runs the bar 0 → 1, so progress consumers need no
    // direction awareness.
    private func updateLegProgress() {
        let legDistance = isReturning
            ? totalDistance - currentDistanceAlongRoute
            : currentDistanceAlongRoute
        elapsedDistance = legDistance
        progress = totalDistance > 0 ? legDistance / totalDistance : 0
    }

    // Where the route says the device should be right now. Used for "Rejoin".
    var expectedPosition: CLLocationCoordinate2D? {
        guard coordinates.count >= 2 else { return coordinates.first }
        return interpolate(at: currentDistanceAlongRoute)
    }

    // Min distance from `coord` to the loaded polyline, in meters. Used for
    // off-route indicator and the abort-on-sustained-deviation rule.
    func distanceFromRoute(_ coord: CLLocationCoordinate2D) -> Double {
        guard projectedRoutePoints.count >= 2,
              let probe = projectedPoint(for: coord) else { return 0 }

        var minDist = Double.greatestFiniteMagnitude
        for i in 0..<(projectedRoutePoints.count - 1) {
            let dist = distanceFromSegment(
                probe: probe,
                a: projectedRoutePoints[i],
                b: projectedRoutePoints[i + 1]
            )
            minDist = min(minDist, dist)
        }
        return minDist
    }

    private func segmentIndex(for distance: Double) -> Int {
        guard cumulativeDistances.count >= 2 else { return 0 }
        for i in 1..<cumulativeDistances.count {
            if cumulativeDistances[i] >= distance {
                return i - 1
            }
        }
        return cumulativeDistances.count - 2
    }

    private func interpolate(at distance: Double) -> CLLocationCoordinate2D {
        guard cumulativeDistances.count >= 2 else {
            return coordinates.first ?? CLLocationCoordinate2D()
        }

        let idx = segmentIndex(for: distance)
        let segStart = cumulativeDistances[idx]
        let segEnd = cumulativeDistances[idx + 1]
        let segLen = segEnd - segStart
        let fraction = segLen > 0 ? (distance - segStart) / segLen : 0

        let from = coordinates[idx]
        let to = coordinates[idx + 1]

        return CLLocationCoordinate2D(
            latitude: from.latitude + (to.latitude - from.latitude) * fraction,
            longitude: from.longitude + (to.longitude - from.longitude) * fraction
        )
    }

    // Route deviation runs at playback cadence, so the route vertices are
    // projected once at load time. A route-wide local frame keeps the full scan
    // safe after teleports or large joystick drift while avoiding per-segment
    // CoreLocation allocation in the hot path.
    private func cacheProjectedRoutePoints(for coordinates: [CLLocationCoordinate2D]) {
        guard let first = coordinates.first else {
            projectionOrigin = nil
            projectedRoutePoints = []
            return
        }

        projectionOrigin = first
        let averageLatitude = coordinates.reduce(0.0) { $0 + $1.latitude } / Double(coordinates.count)
        projectionMetersPerDegLon = Self.metersPerDegLat * cos(averageLatitude * .pi / 180)
        projectedRoutePoints = coordinates.compactMap { projectedPoint(for: $0) }
    }

    private func projectedPoint(for coord: CLLocationCoordinate2D) -> (x: Double, y: Double)? {
        guard let origin = projectionOrigin else { return nil }
        return (
            x: (coord.longitude - origin.longitude) * projectionMetersPerDegLon,
            y: (coord.latitude - origin.latitude) * Self.metersPerDegLat
        )
    }

    private func distanceFromSegment(
        probe: (x: Double, y: Double),
        a: (x: Double, y: Double),
        b: (x: Double, y: Double)
    ) -> Double {
        let abx = b.x - a.x
        let aby = b.y - a.y
        let apx = probe.x - a.x
        let apy = probe.y - a.y
        let abSq = abx * abx + aby * aby

        if abSq == 0 {
            return (apx * apx + apy * apy).squareRoot()
        }

        let t = max(0, min(1, (apx * abx + apy * aby) / abSq))
        let closestX = a.x + abx * t
        let closestY = a.y + aby * t
        let dx = probe.x - closestX
        let dy = probe.y - closestY
        return (dx * dx + dy * dy).squareRoot()
    }
}
