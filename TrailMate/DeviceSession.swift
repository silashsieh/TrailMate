import SwiftUI
import MapKit
import UniformTypeIdentifiers

// One connected (or connectable) device: its connection lifecycle, its
// off-MainActor SimulationActor, its UI projection, and its route/playback
// state. AppState (the manager) owns one of these today; at multi-device it
// will own N, keyed by UDID. App-global tuning (transport mode, speeds, noise
// σ, loop), shared libraries (saved routes/waypoints/recordings), the routing
// kernel, and the log all live on the manager and are read back through the
// `manager` back-reference — the manager strong-owns the session, so this is
// unowned to avoid a retain cycle.
@Observable
@MainActor
final class DeviceSession: Identifiable {
    unowned let manager: AppState

    // Stable identity for the session collection + the sidebar switcher's
    // selection. Not the UDID: an unbound (never-connected) slot has no UDID
    // yet, and two slots could briefly target the same device. Routing
    // correctness keys on `connectedUDID` (below), never on this id or list
    // position.
    let id = UUID()

    // Connection
    var connectionStatus: ConnectionStatus = .disconnected

    // The device this slot will connect to — the per-slot picker value (moved
    // off the manager so each slot targets its own device). Retained across a
    // disconnect so a reconnect is one click.
    var selectedDeviceUDID: String?

    // The device actually connected, or nil when disconnected. Snapshotted from
    // `selectedDeviceUDID` only on a *successful* connect, so AI dispatch can
    // match a command's UDID against the live connection without reading the
    // GUI's mutable picker selection. This is the structural routing key — the
    // session that owns this UDID is the only one a UDID-scoped command reaches.
    private(set) var connectedUDID: String?

    // Last-known device name, for the switcher row + menu bar. Resolved from
    // discovery at connect; retained across a disconnect so the row still names
    // the device it was bound to.
    var deviceName: String?

    // RSD address/port are resolved from the shared TunnelBroker on connect; not
    // user-facing inputs.
    private var rsdAddress: String = ""
    private var rsdPort: String = ""

    // MainActor projection of simulation state for SwiftUI to observe.
    let simState: SimulationStateBridge

    // Off-MainActor simulation core: aggregator loop, engines, integrator,
    // noise, idle jitter, deviation check.
    let sim: SimulationActor
    private var simEventsTask: Task<Void, Never>?

    // Route
    var fromSearch = LocationSearch()
    var toSearch = LocationSearch()
    var fromCoordinate: CLLocationCoordinate2D?
    var toCoordinate: CLLocationCoordinate2D?
    var stops: [RouteStop] = []
    var routeCoordinates: [CLLocationCoordinate2D] = []
    var isCalculatingRoute = false

    private var daemonBridge: (any SimulationBackend)?
    // A started backend whose mirror attach is queued but not yet published.
    // Teardown takes ownership of stopping it, so Disconnect cannot finish
    // before that daemon quits even if commit resumes after the detach.
    private var pendingBackend: (any SimulationBackend)?
    private var eventsTask: Task<Void, Never>?
    private var liveBackendID: ObjectIdentifier?
    // All sim mirror operations — attach on commit, detach + daemon stop on
    // teardown — run through this one chain, so they execute in the order the
    // session issued them regardless of actor scheduling: a teardown issued
    // while a commit's attach is in flight always detaches after that attach.
    private var mirrorChain: Task<Void, Never>?
    // Bumped by every teardown (Disconnect, loss, sleep, removal). A commit
    // captures it when its attempt starts and publishes only if it is
    // unchanged, so a backend started for a session that was torn down
    // meanwhile is stopped instead of published.
    private var backendEpoch = 0
    #if DEBUG
    // Deterministically park a test commit after its first actor hop and
    // before the final epoch check/attach. nil in the live app.
    var beforeMirrorAttachForTesting: (@MainActor () async -> Void)?
    #endif

    init(manager: AppState) {
        self.manager = manager
        self.simState = SimulationStateBridge(defaults: manager.defaults)
        self.sim = SimulationActor(bridge: simState, monotonicTime: manager.simulationMonotonicTime)

        // Consume simulation events (route abort) for log writes.
        let stream = sim.events
        simEventsTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await MainActor.run {
                    switch event {
                    case .routeAborted(let meters, let seconds):
                        self.manager.addLog("Route aborted — drifted >\(Int(meters)) m for \(Int(seconds)) s")
                    }
                }
            }
        }

        // The simulation runs for the session's whole lifetime, not just while a
        // device is connected — the red dot is a live local state that a device,
        // once attached, mirrors. Torn down in shutdown() at removal / app quit.
        Task { await sim.startEngine() }
    }

    // Full teardown: drop the device (if any) and stop the local engine. Used on
    // session removal and app quit — disconnect() alone now leaves the engine
    // running so the red dot survives a disconnect.
    func shutdown() async {
        await disconnect()
        await sim.stopEngine()
    }

    // MARK: - Connection

    // Auto-reconnect policy (epic 043): a fixed post-failure delay before each
    // of at most ten single attempts. Attempt runtime is not part of the delay,
    // so this is a cadence, not a fixed wall-clock window.
    static let autoReconnectMaxAttempts = 10
    static let autoReconnectDelay: Duration = .seconds(5)

    // Explicit Connect keeps its own startup policy: a freshly added device's
    // tunnel can still be rotating its RSD endpoint, so a failed daemon start is
    // retried a few times before the user is told it failed.
    private static let startupMaxAttempts = 3
    private static let startupRetryDelay: Duration = .seconds(3)

    // Armed by a successful explicit Connect; disarmed by explicit Disconnect,
    // Cancel retry, exhaustion, or a recovery that would need a new admin
    // prompt. Only an armed session recovers a connection it loses on its own.
    private(set) var autoReconnectArmed = false

    private enum RecoveryPhase: Equatable {
        case idle
        case delaying(attempt: Int)
        case attempting(attempt: Int)
        case cancelling(attempt: Int)
    }
    private var recoveryPhase: RecoveryPhase = .idle
    // Identity of the running recovery window. Every await in the loop
    // re-checks it, so a window abandoned by disconnect, removal, or sleep can
    // neither commit a late backend nor overwrite the settled status.
    private var recoveryID: UUID?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryUDID: String?
    private var lastRecoveryFailureReason = ""
    // The device to recover on wake, set at sleep for an armed, enabled session.
    private var wakeRecoveryUDID: String?

    func connect() async {
        // A recovery window owns the connection controls until it settles; the
        // explicit path only starts from a settled state.
        guard connectionStatus != .connecting, !connectionStatus.isRecovering else { return }
        guard let udid = selectedDeviceUDID, !udid.isEmpty else {
            manager.addLog("Pick a device first.")
            connectionStatus = .error("No device selected")
            return
        }
        // Resolve the display name now so the switcher row names the device
        // while connecting; keep the prior name if discovery doesn't know it.
        deviceName = manager.discovery.devices.first { $0.udid == udid }?.name ?? deviceName

        // Claim the connecting state and this connect's epoch before the first
        // await: a second Connect is refused by the guard above from here on,
        // and a teardown (quit, removal, sleep) at any point after this bumps
        // the epoch and owns the status — every resumption below checks it
        // and, on mismatch, leaves quietly.
        connectionStatus = .connecting
        let epoch = backendEpoch
        // The last teardown's detach/stop must finish before a replacement
        // backend can attach; otherwise the old cleanup could detach it.
        await mirrorChain?.value
        guard backendEpoch == epoch else { return }

        #if DEBUG
        // UI-test mock: skip the tunnel (admin prompt) and daemon entirely so
        // connected-only UI flows are testable with no device.
        if UITestSupport.mockConnection {
            guard await commitLiveBackend(MockSimulationBackend(), udid: udid, epoch: epoch) else { return }
            autoReconnectArmed = true
            manager.addLog("Connected (mock backend — UI test).")
            // Joystick arming is centralized in AppState.syncActiveJoystick()
            // (selected device only); every connect path calls it after.
            return
        }
        #endif

        manager.sweepStaleDaemonsIfNeeded()

        // Startup retry: each try is one connectOnce, re-querying a settled
        // endpoint and fully releasing a wedged daemon on failure so it can't
        // block the next try, then pausing to let tunneld settle.
        var lastError: (any Error)?
        for attempt in 1...Self.startupMaxAttempts {
            do {
                let backend = try await connectOnce(udid: udid, promptPolicy: .allowPrompt)
                guard await commitLiveBackend(backend, udid: udid, epoch: epoch) else { return }
                // An explicit Connect arms recovery for everything the app
                // loses on its own from here until an explicit Disconnect.
                autoReconnectArmed = true
                manager.addLog("Connected — ready for commands.")
                if simState.simulatedCoordinate == nil {
                    manager.addLog("Long-press the map to set a starting location")
                }
                return
            } catch ConnectionAttemptFailure.daemonStartFailed(let underlying) {
                guard backendEpoch == epoch else { return }
                lastError = underlying
                manager.addLog("Connect attempt \(attempt) failed: \(underlying.localizedDescription)")
                if attempt < Self.startupMaxAttempts {
                    try? await manager.monotonicTime.sleep(for: Self.startupRetryDelay)
                    guard backendEpoch == epoch else { return }
                }
            } catch {
                guard backendEpoch == epoch else { return }
                // No tunnel for this device, or authorization declined — not a
                // transient; stop.
                connectionStatus = .error(error.localizedDescription)
                manager.addLog("Tunnel failed: \(error.localizedDescription)")
                return
            }
        }

        guard backendEpoch == epoch else { return }
        connectionStatus = .error(lastError?.localizedDescription ?? "Connection failed")
        manager.addLog("Connection failed after \(Self.startupMaxAttempts) attempts.")
        // Leave the broker running — it's shared across devices.
    }

    // Exactly one tunnel/daemon attempt for `udid`, returning the started
    // backend for the caller to commit. This is the primitive both policies
    // wrap — explicit Connect's startup loop and every numbered auto-reconnect
    // attempt — so a displayed "n/10" always maps to one daemon/tunnel try.
    // `promptPolicy` decides whether the broker may raise the admin dialog;
    // automatic recovery never allows it.
    private func connectOnce(
        udid: String,
        promptPolicy: ConnectionPromptPolicy
    ) async throws -> any SimulationBackend {
        try await manager.connectionAttempter.attempt(
            udid: udid,
            promptPolicy: promptPolicy,
            log: { manager.addLog($0) }
        )
    }

    // Make a started backend the live one. The sim's mirror is wired first and
    // the backend published only afterwards — synchronously, in one MainActor
    // turn — so the session never claims a connection whose mirror is not up.
    // `epoch` is the caller's snapshot from before its attempt: any teardown
    // since then (Disconnect, removal, sleep) bumped it, and the backend is then
    // stopped instead of published. A teardown that lands while the attach is
    // in flight chained its detach behind that attach, so the mirror ends
    // detached without this commit having to undo anything. The same commit
    // serves explicit connects, reconnects, and the UI-test mock, so a session
    // keeps one actor and one recording capture across every reconnect.
    private func commitLiveBackend(
        _ backend: any SimulationBackend,
        udid: String,
        epoch: Int
    ) async -> Bool {
        guard backendEpoch == epoch else {
            await backend.stop()
            return false
        }
        await sim.updateBaseSpeed(manager.effectiveBaseSpeedMPS)
        #if DEBUG
        await beforeMirrorAttachForTesting?()
        #endif
        // A teardown during that hop already chained its detach; an attach
        // queued behind it would re-mirror a backend nobody owns. Recheck
        // here, in the same turn that queues the attach.
        guard backendEpoch == epoch else {
            await backend.stop()
            return false
        }
        pendingBackend = backend
        await enqueueMirrorOperation { [sim] in
            await sim.attach(backend: backend)
        }.value
        guard backendEpoch == epoch else {
            // Teardown took the pending backend into its detach/stop operation.
            // Its caller waits for that operation; do not queue a late stop
            // that a new Connect could overtake.
            return false
        }
        pendingBackend = nil
        eventsTask?.cancel()
        daemonBridge = backend
        liveBackendID = ObjectIdentifier(backend)
        connectionStatus = .connected
        connectedUDID = udid
        // Subscribe only now. The stream buffers any loss since READY, so an
        // immediate exit cannot be discarded while the mirror was being wired.
        eventsTask = makeEventsTask(for: backend)
        return true
    }

    // Forget the live backend synchronously — stop listening, drop the
    // routing key — and hand it back for stopping. No await in here, so no
    // other lifecycle event can interleave with these flips.
    private func unpublishLiveBackend() -> (any SimulationBackend)? {
        eventsTask?.cancel()
        eventsTask = nil
        liveBackendID = nil
        let bridge = daemonBridge
        daemonBridge = nil
        connectedUDID = nil
        return bridge
    }

    // Every teardown passes here: it invalidates any commit still wiring the
    // mirror and chains the detach + daemon stop behind whatever the chain
    // already holds. The shared broker stays up (other devices use it, and a
    // live tunnel is what keeps reconnects promptless); the local engine and
    // recording keep running. The daemon's QUIT/CLEAR runs over the still-live
    // tunnel.
    private func invalidateMirror(stopping bridge: (any SimulationBackend)?) {
        backendEpoch += 1
        let pending = pendingBackend
        pendingBackend = nil
        enqueueMirrorOperation { [sim] in
            await sim.detach()
            await bridge?.stop()
            if let pending, bridge.map({ ObjectIdentifier($0) }) != ObjectIdentifier(pending) {
                await pending.stop()
            }
        }
    }

    @discardableResult
    private func enqueueMirrorOperation(
        _ operation: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        let previous = mirrorChain
        let task = Task {
            await previous?.value
            await operation()
        }
        mirrorChain = task
        return task
    }

    func disconnect() async {
        // An explicit Disconnect is the user's decision: it ends the armed
        // window, abandons any recovery in progress, and never reconnects.
        // Every flip is synchronous; the trailing await only lets quit and
        // removal wait for the daemon's QUIT/CLEAR handshake, and nothing is
        // written after it, so a Connect issued meanwhile cannot be overwritten.
        autoReconnectArmed = false
        wakeRecoveryUDID = nil
        abandonRecovery()
        invalidateMirror(stopping: unpublishLiveBackend())
        connectionStatus = .disconnected
        manager.addLog("Disconnected.")
        await mirrorChain?.value
    }

    // MARK: - Auto-reconnect (epic 043)

    // Cancel retry: stop scheduling attempts and disarm the session. During a
    // delay it settles immediately; during an in-flight attempt it lets only
    // that attempt finish — the control reads a disabled "Cancelling…" until
    // then — and schedules neither a delay nor another attempt afterward.
    func cancelRetry() {
        guard recoveryID != nil else { return }
        autoReconnectArmed = false
        switch recoveryPhase {
        case .delaying:
            recoveryTask?.cancel()
            finishRecovery(reason: lastRecoveryFailureReason, log: "Reconnect cancelled.")
        case .attempting(let attempt):
            recoveryPhase = .cancelling(attempt: attempt)
            connectionStatus = .cancellingRetry
            manager.addLog("Cancelling reconnect — letting attempt \(attempt) finish.")
        case .cancelling, .idle:
            break
        }
    }

    private func beginRecovery(udid: String, reason: String) {
        let id = UUID()
        recoveryID = id
        recoveryUDID = udid
        lastRecoveryFailureReason = reason
        recoveryPhase = .delaying(attempt: 1)
        connectionStatus = .reconnecting(attempt: 1, maxAttempts: Self.autoReconnectMaxAttempts)
        manager.addLog("Reconnecting in \(Self.autoReconnectDelay.components.seconds) s (attempt 1/\(Self.autoReconnectMaxAttempts))…")
        recoveryTask = Task { [weak self] in
            await self?.runRecovery(id: id)
        }
    }

    // The retry loop. Runs on MainActor like the rest of the session, so every
    // state transition below is ordered against Cancel retry, Disconnect, and
    // sleep; the awaits are the only places another actor can interleave.
    private func runRecovery(id: UUID) async {
        let maxAttempts = Self.autoReconnectMaxAttempts
        var attempt = 1
        while attempt <= maxAttempts {
            // The five seconds are a post-failure delay: after the triggering
            // loss before attempt 1, and after each failed attempt before the
            // next. Cancel retry during a delay cancels this sleep outright.
            do {
                try await manager.monotonicTime.sleep(for: Self.autoReconnectDelay)
            } catch {
                return
            }
            guard recoveryID == id, let udid = recoveryUDID else { return }
            await mirrorChain?.value
            guard recoveryID == id else { return }

            recoveryPhase = .attempting(attempt: attempt)
            let epoch = backendEpoch
            manager.addLog("Reconnect attempt \(attempt)/\(maxAttempts)…")
            do {
                let backend = try await connectOnce(udid: udid, promptPolicy: .neverPrompt)
                guard recoveryID == id else {
                    // Abandoned (disconnect, removal, or sleep) while in flight.
                    await backend.stop()
                    return
                }
                guard await commitLiveBackend(backend, udid: udid, epoch: epoch) else {
                    // Torn down while the mirror was being wired; that teardown
                    // cleared the window and owns the status.
                    if recoveryID == id { clearRecovery() }
                    return
                }
                guard recoveryID == id else { return }
                let cancelledMeanwhile = recoveryPhase == .cancelling(attempt: attempt)
                clearRecovery()
                if cancelledMeanwhile {
                    // Cancel was a deliberate disarm; honoring it does not mean
                    // throwing away a connection that landed anyway.
                    manager.addLog("Reconnected on attempt \(attempt)/\(maxAttempts) — retry was cancelled, so auto-reconnect stays off until the next Connect.")
                } else {
                    manager.addLog("Reconnected on attempt \(attempt)/\(maxAttempts).")
                }
                manager.syncActiveJoystick()
                return
            } catch ConnectionAttemptFailure.authorizationRequired {
                guard recoveryID == id else { return }
                finishRecovery(
                    reason: ConnectionAttemptFailure.authorizationRequired.localizedDescription,
                    log: "Reconnect needs admin access — press Connect to authorize."
                )
                return
            } catch {
                guard recoveryID == id else { return }
                let reason = error.localizedDescription
                lastRecoveryFailureReason = reason
                manager.addLog("Reconnect attempt \(attempt)/\(maxAttempts) failed: \(reason)")
                if case .cancelling = recoveryPhase {
                    finishRecovery(reason: reason, log: "Reconnect cancelled.")
                    return
                }
                if attempt == maxAttempts {
                    // Exhaustion is not an error state of its own: it lands in
                    // the ordinary disconnected state, no final delay.
                    finishRecovery(reason: reason, log: "Reconnect gave up after \(maxAttempts) attempts — press Connect to try again.")
                    return
                }
                attempt += 1
                recoveryPhase = .delaying(attempt: attempt)
                connectionStatus = .reconnecting(attempt: attempt, maxAttempts: maxAttempts)
            }
        }
    }

    // Settle a recovery window into the ordinary disconnected state with the
    // most recent failure as the reason. Connect works out of it like any
    // other failure.
    private func finishRecovery(reason: String, log: String) {
        clearRecovery()
        autoReconnectArmed = false
        connectionStatus = .error(reason)
        manager.addLog(log)
    }

    // Drop the recovery window without settling it as a failure. A delay is
    // cancelled outright; an in-flight attempt is never cancelled (the live
    // tunnel query and daemon start are not cancellation-safe) — it settles on
    // its own and the stale id discards whatever it produced.
    private func abandonRecovery() {
        guard recoveryID != nil else { return }
        if case .delaying = recoveryPhase {
            recoveryTask?.cancel()
        }
        clearRecovery()
    }

    private func clearRecovery() {
        recoveryID = nil
        recoveryTask = nil
        recoveryPhase = .idle
        recoveryUDID = nil
    }

    // MARK: - Joystick arming (centralized: selected device only)

    // Arm or disarm this session's joystick engine. AppState.syncActiveJoystick()
    // is the single caller; it keeps exactly the selected, connected session
    // armed so one physical controller drives one device. A disarmed engine
    // contributes no velocity even though its actor still reads the controller,
    // so non-selected devices never move from joystick input.
    func setJoystickArmed(_ armed: Bool) {
        let speed = manager.effectiveBaseSpeedMPS
        Task {
            if armed {
                await sim.startJoystick(baseSpeed: speed)
            } else {
                await sim.stopJoystick()
            }
        }
    }

    // MARK: - Teleport

    func teleport(to coordinate: CLLocationCoordinate2D) {
        // No connection gate: teleport moves the local red dot. With a device
        // attached the actor mirrors it; disconnected it's a local preview that
        // the device snaps to on the next connect.
        Task {
            await sim.teleport(to: coordinate)
            manager.addLog(String(format: "Teleported to %.6f, %.6f", coordinate.latitude, coordinate.longitude))
        }
    }

    func clearLocation() async {
        guard connectionStatus.isConnected, let bridge = daemonBridge else { return }
        do {
            try await bridge.sendCommand("CLEAR")
            await sim.clearForLocationCleared()
            manager.addLog("Location cleared.")
        } catch {
            manager.addLog("Clear failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Route

    func selectFrom(_ completion: MKLocalSearchCompletion) async {
        fromSearch.select(completion)
        fromCoordinate = await fromSearch.resolve(completion)
    }

    // One-tap fill: route from the red dot. Formatted coordinates rather than
    // a "Current Location" label so the field stays truthful if the dot has
    // moved on by the time the route is calculated.
    func useCurrentLocationAsFrom() {
        guard let coord = simState.simulatedCoordinate else { return }
        fromCoordinate = coord
        fromSearch.setQuery(String(format: "%.5f, %.5f", coord.latitude, coord.longitude))
    }

    func selectTo(_ completion: MKLocalSearchCompletion) async {
        toSearch.select(completion)
        toCoordinate = await toSearch.resolve(completion)
    }

    func addStop() {
        guard stops.count < 50 else { return }
        stops.append(RouteStop())
    }

    func removeStop(id: UUID) {
        stops.removeAll { $0.id == id }
    }

    func selectStop(id: UUID, completion: MKLocalSearchCompletion) async {
        guard let stop = stops.first(where: { $0.id == id }) else { return }
        stop.search.select(completion)
        stop.coordinate = await stop.search.resolve(completion)
    }

    // Defined now so the model supports reorder; UI wiring (.onMove) is deferred.
    func moveStop(fromOffsets: IndexSet, toOffset: Int) {
        stops.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    var canCalculateRoute: Bool {
        fromCoordinate != nil
            && toCoordinate != nil
            && stops.allSatisfy { $0.coordinate != nil }
            && !isCalculatingRoute
    }

    func calculateRoute() async {
        guard let from = fromCoordinate, let to = toCoordinate else {
            manager.addLog("Select both From and To locations first.")
            return
        }
        let via = stops.compactMap { $0.coordinate }
        guard via.count == stops.count else {
            manager.addLog("Resolve all stop locations first.")
            return
        }
        if stops.count > 10 {
            manager.addLog("Note: routing \(stops.count) stops — Apple Maps may throttle.")
        }

        isCalculatingRoute = true
        defer { isCalculatingRoute = false }
        manager.addLog("Calculating route...")

        guard let result = await buildRoute(from: from, via: via, to: to) else { return }
        routeCoordinates = result.coords
        await sim.loadRoute(coordinates: result.coords, baseSpeed: manager.effectiveBaseSpeedMPS, resetStart: true)

        let suffix = stops.isEmpty ? "" : " · via \(stops.count) \(stops.count == 1 ? "stop" : "stops")"
        let distKm = result.distance / 1000
        let timeMin = result.time / 60
        manager.addLog(String(format: "Route: %.1f km, ~%.0f min (%@)%@", distKm, timeMin, manager.transportLabel, suffix))
    }

    // Straight-line travel from the current simulated position to `dest`. Uses
    // NavigationEngine's two-point case (it already handles linear interpolation).
    func travelDirectly(to dest: CLLocationCoordinate2D) {
        guard let from = simState.simulatedCoordinate else {
            manager.addLog("Set an origin first — long-press the map to teleport.")
            return
        }

        let coords = [from, dest]
        routeCoordinates = coords
        let mult = manager.speedMultiplier
        let speed = manager.effectiveBaseSpeedMPS
        let meters = CLLocation(latitude: from.latitude, longitude: from.longitude)
            .distance(from: CLLocation(latitude: dest.latitude, longitude: dest.longitude))
        manager.addLog(String(format: "Direct travel: %.0f m at %@", meters, manager.transportLabel))
        Task {
            await sim.loadRoute(coordinates: coords, baseSpeed: speed, resetStart: true)
            await sim.play(multiplier: mult)
        }
    }

    // Extend the current route with a straight-line segment from its last
    // point to `dest`. Preserves playback state (no resetStart, no auto-play)
    // so a user can grow a route mid-playback.
    func appendDirectly(to dest: CLLocationCoordinate2D) async {
        guard let tail = routeCoordinates.last else {
            manager.addLog("No route to append to.")
            return
        }
        let tailLoc = CLLocation(latitude: tail.latitude, longitude: tail.longitude)
        let destLoc = CLLocation(latitude: dest.latitude, longitude: dest.longitude)
        let meters = tailLoc.distance(from: destLoc)
        routeCoordinates.append(dest)
        await sim.loadRoute(coordinates: routeCoordinates, baseSpeed: manager.effectiveBaseSpeedMPS, resetStart: false)
        manager.addLog(String(format: "Appended direct segment: +%.0f m", meters))
    }

    // Extend the current route via MKDirections from its last point to `dest`.
    // Preserves playback state. Ignores side-panel stops (same reasoning as
    // routeFromCurrent).
    func appendRoute(to dest: CLLocationCoordinate2D) async {
        guard let tail = routeCoordinates.last else {
            manager.addLog("No route to append to.")
            return
        }
        isCalculatingRoute = true
        defer { isCalculatingRoute = false }
        manager.addLog("Appending route segment...")

        guard let result = await buildRoute(from: tail, via: [], to: dest) else { return }
        routeCoordinates = RouteMath.joinSegments(routeCoordinates, result.coords)
        await sim.loadRoute(coordinates: routeCoordinates, baseSpeed: manager.effectiveBaseSpeedMPS, resetStart: false)
        manager.addLog(String(format: "Appended routed segment: +%.1f km, +%.0f min", result.distance / 1000, result.time / 60))
    }

    // Apple Maps routing from current simulated position to `dest`. Auto-plays.
    // Intentionally ignores the side-panel stops: long-press is an ad-hoc flow
    // with a different start point, and silently injecting panel stops would
    // surprise the user.
    func routeFromCurrent(to dest: CLLocationCoordinate2D) async {
        guard let from = simState.simulatedCoordinate else {
            manager.addLog("Set an origin first — long-press the map to teleport.")
            return
        }

        isCalculatingRoute = true
        defer { isCalculatingRoute = false }
        manager.addLog("Routing from current position...")

        guard let result = await buildRoute(from: from, via: [], to: dest) else { return }
        routeCoordinates = result.coords
        await sim.loadRoute(coordinates: result.coords, baseSpeed: manager.effectiveBaseSpeedMPS, resetStart: true)

        let distKm = result.distance / 1000
        let timeMin = result.time / 60
        manager.addLog(String(format: "Route: %.1f km, ~%.0f min (%@)", distKm, timeMin, manager.transportLabel))
        await sim.play(multiplier: manager.speedMultiplier)
    }

    // Builds a meandering polyline of length ≈ speed × duration via chained
    // MKDirections hops, then plays it back. The long-pressed point seeds the
    // disc center and is the playback start; the wander may leak slightly
    // outside the disc by design.
    func wanderNearby(center: CLLocationCoordinate2D, radius: Double, duration: TimeInterval) async {
        isCalculatingRoute = true
        manager.addLog("Generating wander route…")

        let speed = manager.effectiveBaseSpeedMPS
        let options = WanderRouteBuilder.Options(
            center: center,
            radiusMeters: radius,
            durationSeconds: duration,
            speedMPS: speed,
            transportType: manager.effectiveDirectionsTransportType
        )

        do {
            let result = try await WanderRouteBuilder.build(options: options, router: manager.router)
            routeCoordinates = result.coordinates
            await sim.loadRoute(coordinates: result.coordinates, baseSpeed: speed, resetStart: true)

            let distKm = result.distanceMeters / 1000
            let estMin = speed > 0 ? result.distanceMeters / speed / 60 : 0
            manager.addLog(String(format: "Wander route: %.1f km, ~%.0f min (%@)", distKm, estMin, manager.transportLabel))
            if result.hopFailures > 0 {
                manager.addLog("Wander hop failures: \(result.hopFailures)")
            }
            await sim.play(multiplier: manager.speedMultiplier)
        } catch {
            manager.addLog("Wander failed: \(error.localizedDescription)")
        }

        isCalculatingRoute = false
    }

    // Geometric serpentine sweep of a square centered on the selected map point
    // (Sweeping mode). Direct movement like travelDirectly — no MKDirections,
    // nothing snaps to roads — so generation is instant and there's no routing
    // spinner to raise. resetStart does the rest: it teleports the marker from
    // the selected center out to the route's first edge point, and that jump is
    // deliberately outside the route, so it costs no distance or time.
    func sweepArea(center: CLLocationCoordinate2D, halfSideMeters: Double, laneSpacingMeters: Double) async {
        let options = CoverageRouteBuilder.Options(
            center: center,
            halfSideMeters: halfSideMeters,
            laneSpacingMeters: laneSpacingMeters
        )

        do {
            let result = try CoverageRouteBuilder.build(options: options)
            routeCoordinates = result.coordinates
            let speed = manager.effectiveBaseSpeedMPS
            await sim.loadRoute(coordinates: result.coordinates, baseSpeed: speed, resetStart: true)

            let estMin = (CoverageRouteBuilder.estimatedSeconds(
                distanceMeters: result.distanceMeters, speedMPS: speed
            ) ?? 0) / 60
            manager.addLog(String(
                format: "Sweep route: %.1f km, %d lanes at %.0f m, ~%.0f min (%@)",
                result.distanceMeters / 1000, result.laneCount, laneSpacingMeters, estMin, manager.transportLabel
            ))
            await sim.play(multiplier: manager.speedMultiplier)
        } catch {
            manager.addLog("Sweep failed: \(error.localizedDescription)")
        }
    }

    // Hand-drawn route from the map's draw mode. The stroke arrives already
    // smoothed and resampled by the view layer (StrokeGeometry guarantees no
    // degenerate segments); this is just the hand-off into the same playback
    // path every other route source uses. No auto-play — a mouse-up is too
    // accidental a trigger, unlike an explicit "Route here".
    func loadDrawnRoute(_ coords: [CLLocationCoordinate2D]) async {
        guard coords.count >= 2 else { return }
        routeCoordinates = coords
        await sim.loadRoute(coordinates: coords, baseSpeed: manager.effectiveBaseSpeedMPS, resetStart: true)

        var meters = 0.0
        for i in 1..<coords.count {
            meters += CLLocation(latitude: coords[i - 1].latitude, longitude: coords[i - 1].longitude)
                .distance(from: CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude))
        }
        let estMin = manager.effectiveBaseSpeedMPS > 0 ? meters / manager.effectiveBaseSpeedMPS / 60 : 0
        manager.addLog(String(format: "Drawn route: %.1f km, ~%.0f min (%@)", meters / 1000, estMin, manager.transportLabel))
    }

    func startPlayback() {
        guard !routeCoordinates.isEmpty else { return }
        let mult = manager.speedMultiplier
        manager.addLog(String(format: "Playing route at %.0f×%@...", mult, loopLogSuffix))
        Task { await sim.play(multiplier: mult) }
    }

    private var loopLogSuffix: String {
        let count = manager.loopCount == 0 ? "∞" : "\(manager.loopCount)"
        switch manager.loopMode {
        case .off: return ""
        case .restart: return " (restart loop, \(count))"
        case .pingPong: return " (ping-pong loop, \(count))"
        }
    }

    func pausePlayback() {
        Task {
            await sim.pause()
            manager.addLog("Playback paused.")
        }
    }

    func resumePlayback() {
        let mult = manager.speedMultiplier
        Task {
            await sim.resume(multiplier: mult)
            manager.addLog("Playback resumed.")
        }
    }

    func stopPlayback() {
        Task {
            await sim.stopPlayback()
            manager.addLog("Playback stopped.")
        }
    }

    // MARK: - Timeline scrub

    func beginPlaybackScrub() {
        Task { await sim.beginScrub() }
    }

    func scrubPlayback(toProgress progress: Double) {
        Task { await sim.scrub(toProgress: progress) }
    }

    // Authoritative seek: scrub release and discrete jumps (track click,
    // keyboard arrows).
    func seekPlayback(toProgress progress: Double) {
        let meters = simState.navigationTotalDistance * progress
        let distance = meters >= 1000
            ? String(format: "%.1f km", meters / 1000)
            : String(format: "%.0f m", meters)
        Task {
            await sim.seek(toProgress: progress)
            manager.addLog(String(format: "Seeked to %d%% (%@).", Int((progress * 100).rounded()), distance))
        }
    }

    // Releases a scrub whose value never changed (plain click, no drag).
    func endPlaybackScrub() {
        Task { await sim.endScrub() }
    }

    // MARK: - Joystick

    func rejoinRoute() {
        Task {
            await sim.rejoinRoute()
            manager.addLog("Rejoined route")
        }
    }

    // Forwarded from ContentView's joystick input handling — routes through the
    // actor that owns the engine.
    func updateStickInput(x: Float, y: Float) {
        Task { await sim.updateStickInput(x: x, y: y) }
    }

    func pressDirection(_ direction: JoystickEngine.Direction) {
        Task { await sim.pressDirection(direction) }
    }

    func releaseDirection(_ direction: JoystickEngine.Direction) {
        Task { await sim.releaseDirection(direction) }
    }

    // MARK: - GPX

    func importGPX() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "gpx") ?? .xml]
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let coords = GPXService.parse(data: data)
            guard !coords.isEmpty else {
                manager.addLog("GPX file contains no coordinates.")
                return
            }

            routeCoordinates = coords
            let speed = manager.effectiveBaseSpeedMPS
            Task { await sim.loadRoute(coordinates: coords, baseSpeed: speed, resetStart: false) }
            manager.addLog("Imported \(coords.count) points from \(url.lastPathComponent)")
        } catch {
            manager.addLog("Failed to read GPX: \(error.localizedDescription)")
        }
    }

    func exportGPX() {
        guard !routeCoordinates.isEmpty else {
            manager.addLog("No route to export.")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "gpx") ?? .xml]
        panel.nameFieldStringValue = "route.gpx"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let gpx = GPXService.generate(coordinates: routeCoordinates, speedMPS: manager.effectiveBaseSpeedMPS)
        do {
            try gpx.write(to: url, atomically: true, encoding: .utf8)
            manager.addLog("Exported \(routeCoordinates.count) points to \(url.lastPathComponent)")
        } catch {
            manager.addLog("Failed to write GPX: \(error.localizedDescription)")
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        if simState.isRecording {
            Task {
                do {
                    if let draft = await sim.stopRecording(),
                       let url = try manager.recordingsLibrary.persist(draft) {
                        manager.addLog("Recording saved: \(url.lastPathComponent)")
                    } else {
                        manager.addLog("Recording stopped (no points captured).")
                    }
                } catch {
                    manager.addLog("Failed to save recording: \(error.localizedDescription)")
                }
            }
        } else {
            Task {
                await sim.startRecording()
                manager.addLog("Recording started.")
            }
        }
    }

    func replayRecording(_ recording: RecordingsLibrary.Session) {
        guard connectionStatus.isConnected else {
            manager.addLog("Connect to a device before replaying.")
            return
        }
        let coords = recording.points.map { $0.coordinate }
        guard !coords.isEmpty else { return }
        routeCoordinates = coords
        let speed = manager.effectiveBaseSpeedMPS
        let mult = manager.speedMultiplier
        manager.addLog("Replaying recording (\(recording.points.count) points)")
        Task {
            await sim.stopPlayback()
            await sim.loadRoute(coordinates: coords, baseSpeed: speed, resetStart: true)
            await sim.play(multiplier: mult)
        }
    }

    // MARK: - System sleep

    // Sleep is an app-initiated drop, not an intentional Disconnect: the DVT
    // session cannot survive it, so the backend is released cleanly, but the
    // armed window stays open and wake runs the same recovery policy.
    func handleSystemSleep() async {
        let resumeUDID = (autoReconnectArmed && manager.autoReconnectEnabled)
            ? (connectedUDID ?? recoveryUDID ?? selectedDeviceUDID)
            : nil
        if daemonBridge != nil {
            manager.addLog("Pausing — system sleeping (DVT session would drop)")
            // Every flip happens before the first await, so a wake that lands
            // while the daemon is still quitting sees its target and a settled
            // status — and nothing here writes state after that wake could
            // have started a window.
            wakeRecoveryUDID = resumeUDID
            invalidateMirror(stopping: unpublishLiveBackend())
            connectionStatus = .disconnected
            manager.addLog("Disconnected.")
            await mirrorChain?.value
        } else if recoveryID != nil {
            // A window interrupted by sleep is stale on wake (tunneld reassigns
            // every endpoint), so wake starts a fresh ten instead of resuming.
            // Invalidating the mirror discards a commit this window may have
            // in flight.
            wakeRecoveryUDID = resumeUDID
            abandonRecovery()
            invalidateMirror(stopping: nil)
            connectionStatus = .disconnected
            manager.addLog("Reconnect paused — system sleeping")
        } else if connectionStatus == .connecting {
            // An explicit Connect still in flight would publish a backend the
            // sleeping Mac is about to drop; invalidating it makes connect()
            // discard whatever its attempt returns. Never armed, so no wake
            // recovery — the user presses Connect again.
            invalidateMirror(stopping: nil)
            connectionStatus = .disconnected
            manager.addLog("Connect abandoned — system sleeping")
        }
    }

    func handleSystemWake() {
        guard let udid = wakeRecoveryUDID else { return }
        wakeRecoveryUDID = nil
        guard autoReconnectArmed, manager.autoReconnectEnabled, !udid.isEmpty else { return }
        manager.addLog("System woke — reconnecting")
        beginRecovery(udid: udid, reason: "Disconnected during sleep")
    }

    // MARK: - Private

    private func makeEventsTask(for backend: any SimulationBackend) -> Task<Void, Never> {
        let stream = backend.events
        let backendID = ObjectIdentifier(backend)
        return Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await MainActor.run {
                    switch event {
                    case .connectionLost(let failure):
                        self.handleConnectionLoss(failure, backendID: backendID)
                    }
                }
            }
        }
    }

    // First failure for the currently attached backend wins. Stale or racing
    // callbacks cannot tear down a replacement backend or overwrite its reason.
    private func handleConnectionLoss(
        _ failure: SimulationBackendFailure,
        backendID: ObjectIdentifier
    ) {
        guard liveBackendID == backendID else { return }
        manager.addLog(failure.logMessage)
        let lostUDID = connectedUDID
        // Detach this device's sim and stop the failed daemon; leave the shared
        // broker up (tunneld may re-establish the tunnel, and other devices
        // still need it). Neither stops the local actor or its recording.
        invalidateMirror(stopping: unpublishLiveBackend())
        // Recovery policy (epic 043): an armed session recovers a loss it did
        // not choose while the Settings policy allows it; otherwise this is the
        // plain manual-reconnect state. The toggle is read here, at the moment
        // recovery would start, not re-read mid-window.
        if autoReconnectArmed, manager.autoReconnectEnabled, let udid = lostUDID ?? selectedDeviceUDID {
            beginRecovery(udid: udid, reason: failure.statusMessage)
        } else {
            connectionStatus = .error(failure.statusMessage)
        }
    }

    // MARK: - Routing

    // Thin wrapper over the routing kernel: forwards to the manager's router,
    // then maps the typed RoutingError back to the same per-leg log lines this
    // used to emit inline.
    private func buildRoute(
        from: CLLocationCoordinate2D,
        via: [CLLocationCoordinate2D],
        to: CLLocationCoordinate2D
    ) async -> (coords: [CLLocationCoordinate2D], distance: Double, time: TimeInterval)? {
        let waypoints = [from] + via + [to]
        do {
            let plan = try await manager.router.calculateRoute(
                waypoints: waypoints,
                transportType: manager.effectiveDirectionsTransportType
            )
            return (plan.coordinates, plan.distanceMeters, plan.travelTimeSeconds)
        } catch let RoutingError.legNotFound(index) {
            let f = stopLabel(at: index, total: waypoints.count)
            let t = stopLabel(at: index + 1, total: waypoints.count)
            manager.addLog("Route failed: \(f) → \(t): no route found.")
            return nil
        } catch let RoutingError.legFailed(index, underlying) {
            let f = stopLabel(at: index, total: waypoints.count)
            let t = stopLabel(at: index + 1, total: waypoints.count)
            manager.addLog("Route failed: \(f) → \(t): \(underlying.localizedDescription)")
            return nil
        } catch RoutingError.degenerate {
            manager.addLog("Start and end are the same location.")
            return nil
        } catch {
            manager.addLog("Route failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func stopLabel(at index: Int, total: Int) -> String {
        if index == 0 { return "From" }
        if index == total - 1 { return "To" }
        return "Stop \(index)"
    }
}

#if DEBUG
extension DeviceSession {
    // Test seam (same file, so it can set the private(set) connectedUDID): mark
    // this session connected to a UDID without a tunnel or daemon, so
    // CommandDispatchTests can prove dispatch routes a command to exactly the
    // named device's session. No backend attached — teleport's integrator move
    // doesn't need one (emit tolerates a nil backend).
    func bindConnectedForTesting(udid: String) {
        selectedDeviceUDID = udid
        connectedUDID = udid
        connectionStatus = .connected
    }

    // Unit-test connection seam: attach an injected backend through the same
    // mirror chain, event-consumption, and publication order as a successful
    // daemon launch. Unarmed by default so pipe-failure tests see the
    // manual-reconnect state; `armAutoReconnect` stands in for the explicit
    // Connect that arms recovery.
    func bindConnectedForTesting(
        udid: String,
        backend: any SimulationBackend,
        armAutoReconnect: Bool = false
    ) async {
        let epoch = backendEpoch
        await mirrorChain?.value
        selectedDeviceUDID = udid
        guard backendEpoch == epoch else {
            await backend.stop()
            return
        }
        await enqueueMirrorOperation { [sim] in
            await sim.attach(backend: backend)
        }.value
        guard backendEpoch == epoch else {
            await enqueueMirrorOperation {
                await backend.stop()
            }.value
            return
        }
        eventsTask?.cancel()
        daemonBridge = backend
        liveBackendID = ObjectIdentifier(backend)
        connectedUDID = udid
        connectionStatus = .connected
        autoReconnectArmed = armAutoReconnect
        eventsTask = makeEventsTask(for: backend)
    }
}
#endif
