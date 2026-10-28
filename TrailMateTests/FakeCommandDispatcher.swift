import Foundation
@testable import TrailMate

// Records every command the socket hands to MainActor and answers with a
// sequence-numbered response, so socket-lifecycle tests can prove ordering
// without sessions, devices, or AppState.
@MainActor
final class FakeCommandDispatcher: CommandDispatching {
    private(set) var commands: [Command] = []
    private(set) var logs: [String] = []

    // When true, dispatch parks until releaseHeldDispatches() — the server's
    // dispatch-timeout path needs a call that never returns on its own.
    var holdDispatch = false
    private var held: [CheckedContinuation<Void, Never>] = []

    func dispatch(_ command: Command) async -> CommandResponse {
        commands.append(command)
        let sequence = commands.count - 1
        if holdDispatch {
            await withCheckedContinuation { held.append($0) }
        }
        return .success(.object(["seq": .int(sequence)]))
    }

    func addLog(_ message: String) {
        logs.append(message)
    }

    func releaseHeldDispatches() {
        let pending = held
        held.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}
