import CoreLocation
import Foundation

// One session's in-progress recording. SimulationActor owns this value and is
// the only code that mutates it, so emission can append synchronously without
// crossing executors. Persisted recordings leave the actor only as Draft values.
nonisolated struct RecordingCapture: Sendable {
    struct Status: Equatable, Sendable {
        let isActive: Bool
        let pointCount: Int
    }

    struct Point: Codable, Hashable, Sendable {
        let timestamp: Date
        let latitude: Double
        let longitude: Double

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    struct Draft: Identifiable, Hashable, Sendable {
        let id: UUID
        let startedAt: Date
        let points: [Point]
    }

    private struct ActiveDraft: Sendable {
        let id: UUID
        let wallStart: Date
        let monotonicStart: MonotonicTimeSource.Instant
        var lastElapsed: Duration
        var points: [Point]
    }

    private let monotonicTime: MonotonicTimeSource
    private let wallNow: @Sendable () -> Date
    private var activeDraft: ActiveDraft?

    init(
        monotonicTime: MonotonicTimeSource = .continuous,
        wallNow: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.monotonicTime = monotonicTime
        self.wallNow = wallNow
    }

    var isActive: Bool { activeDraft != nil }
    var pointCount: Int { activeDraft?.points.count ?? 0 }
    var status: Status { Status(isActive: isActive, pointCount: pointCount) }

    mutating func start() {
        guard activeDraft == nil else { return }
        activeDraft = ActiveDraft(
            id: UUID(),
            wallStart: wallNow(),
            monotonicStart: monotonicTime.now,
            lastElapsed: .zero,
            points: []
        )
    }

    mutating func append(_ coordinate: CLLocationCoordinate2D) {
        guard var activeDraft else { return }

        // A custom/test clock should be monotonic by contract, but clamping here
        // makes the persisted GPX invariant explicit even if a faulty source
        // briefly reports an earlier instant.
        let sampled = monotonicTime.elapsed(since: activeDraft.monotonicStart)
        let elapsed = max(sampled, activeDraft.lastElapsed)
        activeDraft.lastElapsed = elapsed
        activeDraft.points.append(Point(
            timestamp: activeDraft.wallStart.addingTimeInterval(elapsed.timeInterval),
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        ))
        self.activeDraft = activeDraft
    }

    mutating func stop() -> Draft? {
        guard let activeDraft else { return nil }
        self.activeDraft = nil
        return Draft(
            id: activeDraft.id,
            startedAt: activeDraft.wallStart,
            points: activeDraft.points
        )
    }

    mutating func discard() {
        activeDraft = nil
    }
}

private nonisolated extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
