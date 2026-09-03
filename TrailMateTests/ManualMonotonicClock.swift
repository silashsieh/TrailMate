import Foundation
@testable import TrailMate

// Deterministic driver for production code that consumes MonotonicTimeSource.
// It uses a lock because `now` must stay synchronous while sleepers are async.
nonisolated final class ManualMonotonicClock: @unchecked Sendable {
    private struct Sleeper {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private enum SleepState {
        case registering
        case waiting(Sleeper)
    }

    private let lock = NSLock()
    private let beforeContinuationRegistration: (@Sendable () async -> Void)?
    private var current: Duration = .zero
    private var sleeps: [UUID: SleepState] = [:]

    init(beforeContinuationRegistration: (@Sendable () async -> Void)? = nil) {
        self.beforeContinuationRegistration = beforeContinuationRegistration
    }

    var now: Duration {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    var pendingSleepCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleeps.values.reduce(into: 0) { count, state in
            if case .waiting = state { count += 1 }
        }
    }

    var outstandingSleepCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleeps.count
    }

    var timeSource: MonotonicTimeSource {
        MonotonicTimeSource(
            now: { [self] in now },
            sleep: { [self] duration in try await sleep(for: duration) }
        )
    }

    func advance(by duration: Duration) {
        precondition(duration >= .zero)

        let ready: [CheckedContinuation<Void, any Error>]
        lock.lock()
        current += duration
        let readyIDs = sleeps.compactMap { id, state -> UUID? in
            guard case .waiting(let sleeper) = state else { return nil }
            return sleeper.deadline <= current ? id : nil
        }
        ready = readyIDs.compactMap { id in
            guard case .waiting(let sleeper) = sleeps.removeValue(forKey: id) else { return nil }
            return sleeper.continuation
        }
        lock.unlock()

        for continuation in ready {
            continuation.resume()
        }
    }

    private func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        guard duration > .zero else { return }

        let id = UUID()
        lock.lock()
        sleeps[id] = .registering
        lock.unlock()

        try await withTaskCancellationHandler {
            if let beforeContinuationRegistration {
                await beforeContinuationRegistration()
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                guard case .registering = sleeps[id] else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                sleeps[id] = .waiting(Sleeper(deadline: current + duration, continuation: continuation))
                lock.unlock()
            }
        } onCancel: {
            self.cancelSleep(id: id)
        }
    }

    private func cancelSleep(id: UUID) {
        let continuation: CheckedContinuation<Void, any Error>?
        lock.lock()
        switch sleeps.removeValue(forKey: id) {
        case .waiting(let sleeper):
            continuation = sleeper.continuation
        case .registering, nil:
            // Removing `.registering` records cancellation before its checked
            // continuation exists. Registration then observes the missing id
            // and resumes immediately with CancellationError.
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}
