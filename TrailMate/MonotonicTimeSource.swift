import Foundation

// Type-erased monotonic time for code that needs a synchronous elapsed-time
// sample and a cancellable delay without depending on one concrete Clock type.
// Duration is relative to a private origin, so it cannot be confused with wall
// time; callers keep wall-clock Date anchors separately when persistence needs
// them.
nonisolated struct MonotonicTimeSource: Sendable {
    typealias Instant = Duration

    private let readNow: @Sendable () -> Instant
    private let sleepFor: @Sendable (Duration) async throws -> Void

    init(
        now: @escaping @Sendable () -> Instant,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.readNow = now
        self.sleepFor = sleep
    }

    var now: Instant { readNow() }

    func elapsed(since instant: Instant) -> Duration {
        now - instant
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        guard duration > .zero else { return }
        try await sleepFor(duration)
    }

    static var continuous: MonotonicTimeSource {
        let clock = ContinuousClock()
        let origin = clock.now
        return MonotonicTimeSource(
            now: { origin.duration(to: clock.now) },
            sleep: { duration in try await clock.sleep(for: duration) }
        )
    }
}
