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
    private var eventsTask: Task<Void, Never>?

    init(manager: AppState) {
        self.manager = manager
        self.simState = SimulationStateBridge(defaults: manager.defaults)
        self.sim = SimulationActor(bridge: simState, recorder: manager.recorder)

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
    }

    // MARK: - Connection

    func connect() async {
        guard connectionStatus != .connecting else { return }
        guard let udid = selectedDeviceUDID, !udid.isEmpty else {
            manager.addLog("Pick a device first.")
            connectionStatus = .error("No device selected")
            return
        }
        // Resolve the display name now so the switcher row names the device
        // while connecting; keep the prior name if discovery doesn't know it.
        deviceName = manager.discovery.devices.first { $0.udid == udid }?.name ?? deviceName

        #if DEBUG
        // UI-test mock: skip the tunnel (admin prompt) and daemon entirely so
        // connected-only UI flows are testable with no device.
        if UITestSupport.mockConnection {
            let backend = MockSimulationBackend()
            daemonBridge = backend
            connectionStatus = .connected
            connectedUDID = udid
            manager.addLog("Connected (mock backend — UI test).")
            await sim.updateBaseSpeed(manager.effectiveBaseSpeedMPS)
            await sim.attach(backend: backend)
            // Joystick arming is centralized in AppState.syncActiveJoystick()
            // (selected device only); every connect path calls it after.
            return
        }
        #endif

        manager.sweepStaleDaemonsIfNeeded()

        connectionStatus = .connecting
        manager.addLog("Authenticating tunnel broker for device …\(udid.suffix(8))")
        do {
            // Shared broker: ensureRunning() prompts once per session (idempotent
            // thereafter).
            try await manager.tunnelBroker.ensureRunning()
        } catch {
            connectionStatus = .error(error.localizedDescription)
            manager.addLog("Tunnel failed: \(error.localizedDescription)")
            return
        }

        // Connect with retry. When a second device is freshly added, tunneld is
        // still settling its tunnel and keeps reassigning the device's RSD
        // address+port (they're ephemeral). A daemon spawned against an address
        // that then rotates wedges at the DVT handshake. So each attempt
        // re-queries a *settled* endpoint (rsdEndpoint waits for stability), and
        // on failure we fully release the (possibly wedged) daemon — freeing the
        // device's DVT session so it can't block the next try — then pause to let
        // tunneld settle and the device reclaim the session before retrying.
        let maxAttempts = 3
        var lastError: Error?
        for attempt in 1...maxAttempts {
            let info: TunnelBroker.TunnelInfo
            do {
                info = try await manager.tunnelBroker.rsdEndpoint(udid: udid)
            } catch {
                // No tunnel for this device at all — not a transient; stop.
                connectionStatus = .error(error.localizedDescription)
                manager.addLog("Tunnel failed: \(error.localizedDescription)")
                return
            }
            rsdAddress = info.address
            rsdPort = String(info.port)
            let suffix = attempt > 1 ? " (attempt \(attempt)/\(maxAttempts))" : ""
            manager.addLog("Connecting to [\(rsdAddress)]:\(rsdPort)…\(suffix)")

            let bridge = DaemonBridge()
            // Consume out-of-band events (daemon death, tunnel down) for THIS
            // bridge. The stream is Sendable so the iterator runs off MainActor;
            // each event hops back here to mutate UI-bound state.
            let stream = bridge.events
            let attemptEvents = Task { [weak self] in
                for await event in stream {
                    guard let self else { return }
                    await MainActor.run {
                        switch event {
                        case .unexpectedExit(let status, let reason):
                            self.handleDaemonExit(status: status, reason: reason)
                        case .tunnelDown(let line):
                            self.handleTunnelDown(line: line)
                        }
                    }
                }
            }

            do {
                try await bridge.start(rsdAddress: rsdAddress, rsdPort: rsdPort)
                // Success — commit this bridge as the live one.
                eventsTask?.cancel()
                eventsTask = attemptEvents
                daemonBridge = bridge
                connectionStatus = .connected
                connectedUDID = udid
                manager.addLog("Connected — ready for commands.")
                await sim.updateBaseSpeed(manager.effectiveBaseSpeedMPS)
                await sim.attach(backend: bridge)
                // Joystick arming is centralized in AppState.syncActiveJoystick()
                // (selected device only); every connect path calls it after.
                if simState.simulatedCoordinate == nil {
                    manager.addLog("Long-press the map to set a starting location")
                }
                return
            } catch {
                lastError = error
                attemptEvents.cancel()
                // start() already terminates+SIGKILLs the daemon on failure;
                // stop() is a no-op then but harmless, and covers any path that
                // left the process alive. Releases the device's DVT session.
                await bridge.stop()
                manager.addLog("Connect attempt \(attempt) failed: \(error.localizedDescription)")
                if attempt < maxAttempts {
                    // Let tunneld finish settling and the device reclaim its DVT
                    // session before re-querying a fresh endpoint.
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }

        connectionStatus = .error(lastError?.localizedDescription ?? "Connection failed")
        manager.addLog("Connection failed after \(maxAttempts) attempts.")
        daemonBridge = nil
        // Leave the broker running — it's shared across devices.
    }

    func disconnect() async {
        eventsTask?.cancel()
        eventsTask = nil
        await sim.detach()
        if let bridge = daemonBridge {
            await bridge.stop()
        }
        daemonBridge = nil
        // Don't stop the broker — it's app-global (other devices may use it, and
        // keeping it up makes reconnect promptless). It's torn down at app quit
        // (AppState.prepareForQuit). The daemon's QUIT/CLEAR ran above over the
        // still-live tunnel.
        connectionStatus = .disconnected
        connectedUDID = nil
        manager.addLog("Disconnected.")
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
        guard connectionStatus.isConnected else { return }
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
        guard connectionStatus.isConnected else { return }
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
        guard connectionStatus.isConnected else { return }
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
        guard connectionStatus.isConnected else { return }

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
        guard !routeCoordinates.isEmpty, connectionStatus.isConnected else { return }
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
                    if let url = try await sim.stopRecording() {
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

    func replayRecording(_ recording: RecorderService.Session) {
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

    func handleSystemSleep() async {
        guard daemonBridge != nil else { return }
        manager.addLog("Pausing — system sleeping (DVT session would drop)")
        await disconnect()
    }

    // MARK: - Private

    // Invoked from the events stream when the daemon dies on its own (crash,
    // kill, our SIGKILL escalator). Tear down Swift-side state that assumed
    // the daemon was alive. Don't auto-restart — the user clicks Connect.
    private func handleDaemonExit(status: Int32, reason: ExitReason) {
        let detail: String
        switch (status, reason) {
        case (0, _):        detail = "Daemon exited"
        case (_, .signal):  detail = "Daemon killed (signal)"
        default:            detail = "Daemon crashed (exit \(status))"
        }
        manager.addLog(detail)
        teardownLiveState(statusMessage: detail)
    }

    private func handleTunnelDown(line: String) {
        manager.addLog("Tunnel down: \(line)")
        teardownLiveState(statusMessage: "Tunnel down")
    }

    private func teardownLiveState(statusMessage: String) {
        eventsTask?.cancel(); eventsTask = nil
        daemonBridge = nil
        connectedUDID = nil
        // Detach this device's sim; leave the shared broker up (tunneld may
        // re-establish the tunnel, and other devices still need it).
        Task { await sim.detach() }
        connectionStatus = .error(statusMessage)
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
}
#endif
