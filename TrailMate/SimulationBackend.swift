import CoreLocation
import Foundation

// A device-control backend the SimulationActor talks to. The current concrete
// implementation is DaemonBridge (pymobiledevice3 over a privileged tunnel),
// but the protocol is shaped to admit future backends — ADB on Android,
// SSH-to-jailbroken-iOS, a record-only mock for tests, etc.
//
// setLocationQuiet is the hot-path call (10 Hz during playback) and is
// nonisolated so the simulation loop never has to await crossing into the
// backend's isolation domain. Conforming types must guarantee it's safe to
// call from any task — single-sender invariant from SimulationActor is what
// makes that tractable.
protocol SimulationBackend: AnyObject, Sendable {
    func start(rsdAddress: String, rsdPort: String) async throws
    func stop() async
    @discardableResult
    func sendCommand(_ command: String) async throws -> String
    nonisolated func setLocationQuiet(latitude: Double, longitude: Double)
    var events: AsyncStream<SimulationBackendEvent> { get }
}

enum SimulationBackendEvent: Sendable {
    // A backend publishes exactly one loss event for a live connection. The
    // reason is diagnostic; recovery policy belongs to DeviceSession (and,
    // for automatic retries, epic 043), not to the backend.
    case connectionLost(SimulationBackendFailure)
}

nonisolated enum SimulationBackendFailure: Equatable, Sendable {
    case brokenPipe
    case endOfFile
    case unexpectedExit(status: Int32, reason: ExitReason)
    case tunnelDown(line: String)
    case writeFailed(errno: Int32)

    var statusMessage: String {
        switch self {
        case .brokenPipe, .endOfFile:
            "Tunnel down"
        case .unexpectedExit(let status, let reason):
            switch (status, reason) {
            case (0, _):       "Daemon exited"
            case (_, .signal): "Daemon killed (signal)"
            default:           "Daemon crashed (exit \(status))"
            }
        case .tunnelDown:
            "Tunnel down"
        case .writeFailed(let code):
            "Daemon write failed (errno \(code))"
        }
    }

    var logMessage: String {
        switch self {
        case .brokenPipe:
            "Tunnel down: daemon input closed (EPIPE)"
        case .endOfFile:
            "Tunnel down: daemon output closed (EOF)"
        case .unexpectedExit:
            statusMessage
        case .tunnelDown(let line):
            "Tunnel down: \(line)"
        case .writeFailed(let code):
            "Daemon write failed (errno \(code))"
        }
    }
}

// Process.TerminationReason isn't Sendable under strict concurrency and is
// Darwin-specific; ExitReason is our own boundary type that future non-Process
// backends (a remote agent over SSH, say) can also populate.
nonisolated enum ExitReason: Equatable, Sendable {
    case normal
    case signal
}

// MainActor-side projection of the simulation state SwiftUI views read. Owned
// by AppState; populated either by AppState's didSet relays (PR 1) or by the
// SimulationActor's snapshot push (PR 2). Either way, views observe this and
// never touch the engines directly.
@Observable
@MainActor
final class SimulationStateBridge {
    private let defaults: UserDefaults

    var simulatedCoordinate: CLLocationCoordinate2D?
    var navigationPlaybackState: NavigationEngine.PlaybackState = .idle
    var navigationProgress: Double = 0
    var navigationElapsedDistance: Double = 0
    var navigationTotalDistance: Double = 0
    var navigationCompletedLoops: Int = 0
    var joystickIsActive: Bool = false
    var joystickControllerName: String?
    var routeDeviationMeters: Double = 0
    var recordingPointCount: Int = 0
    var isRecording: Bool = false

    // Joystick-only snapshots arrive at 10 Hz; persisting the position needs
    // none of that resolution, so writes are throttled here. The final
    // position at quit is saved unconditionally by the AppDelegate.
    @ObservationIgnored private var lastPositionSave: ContinuousClock.Instant?

    init(defaults: UserDefaults = AppProcessConfiguration.current.defaults) {
        self.defaults = defaults
    }

    func persistPositionThrottled() {
        guard let coord = simulatedCoordinate else { return }
        let now = ContinuousClock.now
        if let last = lastPositionSave, now - last < .seconds(1) { return }
        lastPositionSave = now
        SimulatedPositionPersistence.save(coord, to: defaults)
    }

    func persistPositionNow() {
        guard let coord = simulatedCoordinate else { return }
        SimulatedPositionPersistence.save(coord, to: defaults)
    }
}
