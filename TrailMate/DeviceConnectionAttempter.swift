import Foundation

// Whether one connection attempt may raise the admin dialog. Explicit Connect
// may (that is the one auth prompt per session); automatic recovery never
// may — it reuses the already-authorized tunnel or settles disconnected.
nonisolated enum ConnectionPromptPolicy: Equatable, Sendable {
    case allowPrompt
    case neverPrompt
}

// Why one attempt failed, classified for the callers' policies: explicit
// Connect retries only a daemon start (tunneld may still be rotating a fresh
// device's endpoint), while auto-reconnect counts every failure as one attempt
// and ends the window outright when authorization would be needed.
nonisolated enum ConnectionAttemptFailure: LocalizedError {
    case authorizationRequired
    case tunnelUnavailable(underlying: any Error)
    case daemonStartFailed(underlying: any Error)

    var errorDescription: String? {
        switch self {
        case .authorizationRequired:
            "Authentication required"
        case .tunnelUnavailable(let underlying), .daemonStartFailed(let underlying):
            underlying.localizedDescription
        }
    }
}

// Exactly one tunnel-endpoint + daemon-start attempt for a device, returning a
// started backend the session then commits. This is the seam DeviceSession's
// connectOnce primitive stands on: the live implementation talks to the shared
// TunnelBroker and spawns a DaemonBridge; tests inject a scriptable fake so
// retry timing, cancellation, and prompt policy are provable with no tunnel,
// daemon, or admin dialog. `log` receives the same progress lines the sidebar
// log showed before the split.
@MainActor
protocol DeviceConnectionAttempter: AnyObject {
    func attempt(
        udid: String,
        promptPolicy: ConnectionPromptPolicy,
        log: (String) -> Void
    ) async throws -> any SimulationBackend
}

@MainActor
final class LiveDeviceConnectionAttempter: DeviceConnectionAttempter {
    private let tunnelBroker: TunnelBroker
    private let makeBackend: @MainActor () -> any SimulationBackend

    init(
        tunnelBroker: TunnelBroker,
        makeBackend: @escaping @MainActor () -> any SimulationBackend = { DaemonBridge() }
    ) {
        self.tunnelBroker = tunnelBroker
        self.makeBackend = makeBackend
    }

    func attempt(
        udid: String,
        promptPolicy: ConnectionPromptPolicy,
        log: (String) -> Void
    ) async throws -> any SimulationBackend {
        switch promptPolicy {
        case .allowPrompt:
            // Shared broker: ensureRunning() prompts once per session and is
            // idempotent thereafter, so a reconnect over a live tunnel is free.
            log("Authenticating tunnel broker for device …\(udid.suffix(8))")
            do {
                try await tunnelBroker.ensureRunning()
            } catch {
                throw ConnectionAttemptFailure.tunnelUnavailable(underlying: error)
            }
        case .neverPrompt:
            // Recovery never expands authorization: without a live tunnel it
            // settles disconnected and waits for an explicit Connect.
            guard tunnelBroker.isRunning else {
                throw ConnectionAttemptFailure.authorizationRequired
            }
        }

        // The RSD endpoint is ephemeral and re-queried on every attempt; a
        // device with no tunnel at all is not a transient failure.
        let info: TunnelBroker.TunnelInfo
        do {
            info = try await tunnelBroker.rsdEndpoint(udid: udid)
        } catch {
            throw ConnectionAttemptFailure.tunnelUnavailable(underlying: error)
        }
        log("Connecting to [\(info.address)]:\(info.port)…")

        let backend = makeBackend()
        do {
            try await backend.start(rsdAddress: info.address, rsdPort: String(info.port))
        } catch {
            // start() already reaps the daemon on failure; stop() is then a
            // harmless no-op that also covers any path that left it alive, and
            // it releases the device's DVT session for the next attempt.
            await backend.stop()
            throw ConnectionAttemptFailure.daemonStartFailed(underlying: error)
        }
        return backend
    }
}
