import Foundation
@testable import TrailMate

// Scriptable stand-in for the tunnel + daemon attempt, so retry policy is
// provable with no tunnel, daemon, or admin prompt. Each attempt either resolves
// from the scripted queue at once or parks until the test settles it — which is
// how "cancel while an attempt is in flight" is driven deterministically.
@MainActor
final class FakeDeviceConnectionAttempter: DeviceConnectionAttempter {
    struct Call: Equatable {
        let udid: String
        let promptPolicy: ConnectionPromptPolicy
    }

    enum Outcome {
        case succeed(FakeSimulationBackend)
        case fail(any Error)
    }

    struct AttemptError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
        static let unreachable = AttemptError(message: "device unreachable")
    }

    private(set) var calls: [Call] = []
    private(set) var logLines: [String] = []
    private var scripted: [Outcome] = []
    private var parked: [CheckedContinuation<any SimulationBackend, any Error>] = []

    // Attempts currently awaiting a settle() call.
    var inFlightCount: Int { parked.count }

    func script(_ outcomes: Outcome...) {
        scripted.append(contentsOf: outcomes)
    }

    func attempt(
        udid: String,
        promptPolicy: ConnectionPromptPolicy,
        log: (String) -> Void
    ) async throws -> any SimulationBackend {
        calls.append(Call(udid: udid, promptPolicy: promptPolicy))
        log("Fake attempt \(calls.count) for \(udid)")
        logLines.append("attempt \(calls.count)")
        if !scripted.isEmpty {
            switch scripted.removeFirst() {
            case .succeed(let backend): return backend
            case .fail(let error): throw error
            }
        }
        return try await withCheckedThrowingContinuation { parked.append($0) }
    }

    // Settle the oldest in-flight attempt as a failure.
    func failInFlight(_ error: any Error = AttemptError.unreachable) {
        guard !parked.isEmpty else { return }
        parked.removeFirst().resume(throwing: error)
    }

    // Settle the oldest in-flight attempt with a started backend.
    func succeedInFlight(with backend: FakeSimulationBackend) {
        guard !parked.isEmpty else { return }
        parked.removeFirst().resume(returning: backend)
    }
}
