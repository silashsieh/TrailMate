import CoreLocation

@Observable
@MainActor
final class NavigationEngine {
    enum PlaybackState: Equatable {
        case idle
        case playing
        case paused
    }

    var playbackState: PlaybackState = .idle
    var currentCoordinate: CLLocationCoordinate2D?
    var progress: Double = 0
    var elapsedDistance: Double = 0
    var totalDistance: Double = 0

    var onPositionUpdate: ((CLLocationCoordinate2D) -> Void)?

    private var coordinates: [CLLocationCoordinate2D] = []
    private var cumulativeDistances: [Double] = []
    private var currentDistanceAlongRoute: Double = 0
    private var baseSpeedMPS: Double = 1.4
    private var speedMultiplier: Double = 1.0
    private var playbackTask: Task<Void, Never>?

    func loadRoute(coordinates: [CLLocationCoordinate2D], baseSpeed: Double) {
        stop()
        self.coordinates = coordinates
        self.baseSpeedMPS = baseSpeed

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
        currentCoordinate = coordinates.first
    }

    func play(multiplier: Double) {
        speedMultiplier = multiplier
        playbackState = .playing

        playbackTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.playbackState == .playing else { return }
                self.tick()
                if self.playbackState != .playing { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func pause() {
        playbackState = .paused
        playbackTask?.cancel()
        playbackTask = nil
    }

    func resume(multiplier: Double) {
        guard playbackState == .paused else { return }
        play(multiplier: multiplier)
    }

    func stop() {
        playbackTask?.cancel()
        playbackTask = nil
        playbackState = .idle
        currentDistanceAlongRoute = 0
        progress = 0
        elapsedDistance = 0
        currentCoordinate = coordinates.first
    }

    func updateSpeed(_ multiplier: Double) {
        speedMultiplier = multiplier
    }

    private func tick() {
        let dt = 0.1
        currentDistanceAlongRoute += baseSpeedMPS * speedMultiplier * dt

        if currentDistanceAlongRoute >= totalDistance {
            currentDistanceAlongRoute = totalDistance
            currentCoordinate = coordinates.last
            progress = 1.0
            elapsedDistance = totalDistance
            playbackTask?.cancel()
            playbackTask = nil
            playbackState = .idle
            if let coord = currentCoordinate {
                onPositionUpdate?(coord)
            }
            return
        }

        currentCoordinate = interpolate(at: currentDistanceAlongRoute)
        progress = totalDistance > 0 ? currentDistanceAlongRoute / totalDistance : 0
        elapsedDistance = currentDistanceAlongRoute

        if let coord = currentCoordinate {
            onPositionUpdate?(coord)
        }
    }

    private func interpolate(at distance: Double) -> CLLocationCoordinate2D {
        guard cumulativeDistances.count >= 2 else {
            return coordinates.first ?? CLLocationCoordinate2D()
        }

        var idx = 0
        for i in 1..<cumulativeDistances.count {
            if cumulativeDistances[i] >= distance {
                idx = i - 1
                break
            }
        }

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
}
