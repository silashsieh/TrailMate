import SwiftUI
import MapKit
import UniformTypeIdentifiers

enum ConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)

    var isConnected: Bool { self == .connected }
}

enum TransportMode: String, CaseIterable {
    case walk = "Walk"
    case cycle = "Cycle"
    case drive = "Drive"
    case custom = "Custom"

    var directionsTransportType: MKDirectionsTransportType {
        switch self {
        case .walk, .cycle: .walking
        case .drive, .custom: .automobile
        }
    }

    // nil for .custom — AppState supplies the user-entered km/h.
    var fixedSpeedKmh: Double? {
        switch self {
        case .walk: 5.0
        case .cycle: 15.0
        case .drive: 50.0
        case .custom: nil
        }
    }
}

struct SavedWaypoint: Codable, Identifiable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

@Observable
@MainActor
final class AppState {
    // Connection
    var connectionStatus: ConnectionStatus = .disconnected
    // RSD address/port are populated by TunnelSupervisor on connect; not
    // user-facing inputs.
    private var rsdAddress: String = ""
    private var rsdPort: String = ""

    // MainActor projection of simulation state for SwiftUI to observe.
    // SimulationActor pushes snapshots into this; views never touch the
    // engines directly.
    let simState = SimulationStateBridge()

    // Route
    var fromSearch = LocationSearch()
    var toSearch = LocationSearch()
    var fromCoordinate: CLLocationCoordinate2D?
    var toCoordinate: CLLocationCoordinate2D?
    var stops: [RouteStop] = []
    var transportMode: TransportMode = .walk {
        didSet { Task { await syncEngineSpeeds() } }
    }
    var customSpeedKmh: Double = 15.0 {
        didSet { Task { await syncEngineSpeeds() } }
    }
    var speedMultiplier: Double = 1.0
    // Loop playback. Session-scoped like speedMultiplier; count 0 = infinite.
    // Engine-wide config, so it applies to every play entry point (planned
    // routes, direct travel, wander, recording replays).
    var loopMode: NavigationEngine.LoopMode = .off {
        didSet { pushLoopConfig() }
    }
    var loopCount: Int = 0 {
        didSet { pushLoopConfig() }
    }
    var routeCoordinates: [CLLocationCoordinate2D] = []
    var isCalculatingRoute = false

    // Discovery
    let discovery = DeviceDiscoveryService()
    var selectedDeviceUDID: String?

    // Recording
    let recorder = RecorderService()

    // Saved Routes
    let savedRoutes = SavedRoutesStore()

    // Off-MainActor simulation core: aggregator loop, engines, integrator,
    // noise, idle jitter, deviation check. Initialized in init() since it
    // needs `simState` and `recorder` already constructed.
    let sim: SimulationActor
    private var simEventsTask: Task<Void, Never>?

    // Saved Locations
    var savedWaypoints: [SavedWaypoint] = []

    // Realism
    var noiseSigmaMeters: Double = 5.0 {
        didSet {
            let sigma = noiseSigmaMeters
            Task { await sim.updateNoiseSigma(sigma) }
        }
    }

    // Launch behavior (epic 005). The position is always saved; this only
    // gates whether the next launch restores it or starts empty.
    var restoreLastSimulatedLocation: Bool = SimulatedPositionPersistence.restoreOnLaunch {
        didSet { SimulatedPositionPersistence.restoreOnLaunch = restoreLastSimulatedLocation }
    }

    // Log
    var logMessages: [String] = []
    var showLogSheet = false

    // Wander sheet
    var showWanderSheet = false
    var pendingWanderCenter: CLLocationCoordinate2D?

    private var daemonBridge: (any SimulationBackend)?
    private var eventsTask: Task<Void, Never>?
    private let tunnelSupervisor = TunnelSupervisor()
    private var didSweepStaleDaemons = false

    var effectiveBaseSpeedMPS: Double {
        let kmh = transportMode.fixedSpeedKmh ?? max(0.1, customSpeedKmh)
        return kmh / 3.6
    }

    var effectiveDirectionsTransportType: MKDirectionsTransportType {
        if transportMode == .custom {
            return customSpeedKmh >= 20 ? .automobile : .walking
        }
        return transportMode.directionsTransportType
    }

    init() {
        // Stored property `sim` must be initialized before any reference to
        // self. `simState` and `recorder` are already initialized by their
        // default values at this point.
        self.sim = SimulationActor(bridge: simState, recorder: recorder)

        let storedCustom = UserDefaults.standard.double(forKey: "customSpeedKmh")
        self.customSpeedKmh = storedCustom > 0 ? storedCustom : 15.0

        if UserDefaults.standard.object(forKey: "noiseSigmaMeters") != nil {
            self.noiseSigmaMeters = UserDefaults.standard.double(forKey: "noiseSigmaMeters")
        }

        if let raw = UserDefaults.standard.string(forKey: "transportMode"),
           let mode = TransportMode(rawValue: raw) {
            self.transportMode = mode
        }
        let initialSigma = noiseSigmaMeters
        Task { await sim.updateNoiseSigma(initialSigma) }

        // System sleep tears down the DVT session unconditionally (Apple's
        // design — see v2-features.md). Drop our connection cleanly so the
        // UI doesn't claim we're still connected after wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleSystemSleep()
            }
        }

        loadWaypoints()
        recorder.loadIndex()
        savedRoutes.load()

        // Seed the red dot from the last session (display only — emit()
        // reaches no backend until connect; attach() broadcasts it then).
        // Bypasses the UI teleport's isConnected guard deliberately.
        if restoreLastSimulatedLocation {
            let restored = SimulatedPositionPersistence.load()
                ?? SimulatedPositionPersistence.defaultCoordinate
            Task { await sim.teleport(to: restored) }
        }

        #if DEBUG
        if UITestSupport.openWander {
            pendingWanderCenter = CLLocationCoordinate2D(latitude: 25.0339, longitude: 121.5645)
            showWanderSheet = true
        }
        #endif

        // Consume simulation events (route abort) for log writes.
        let stream = sim.events
        simEventsTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await MainActor.run {
                    switch event {
                    case .routeAborted(let meters, let seconds):
                        self.addLog("Route aborted — drifted >\(Int(meters)) m for \(Int(seconds)) s")
                    }
                }
            }
        }
    }

    func persistTuning() {
        UserDefaults.standard.set(customSpeedKmh, forKey: "customSpeedKmh")
        UserDefaults.standard.set(noiseSigmaMeters, forKey: "noiseSigmaMeters")
        UserDefaults.standard.set(transportMode.rawValue, forKey: "transportMode")
    }

    private func syncEngineSpeeds() async {
        await sim.updateBaseSpeed(effectiveBaseSpeedMPS)
    }

    private func pushLoopConfig() {
        let mode = loopMode
        let count = loopCount
        Task { await sim.updateLoop(mode: mode, count: count) }
    }

    // MARK: - Connection

    func connect() async {
        guard connectionStatus != .connecting else { return }
        guard let udid = selectedDeviceUDID, !udid.isEmpty else {
            addLog("Pick a device first.")
            connectionStatus = .error("No device selected")
            return
        }

        #if DEBUG
        // UI-test mock: skip the tunnel (admin prompt) and daemon entirely so
        // connected-only UI flows are testable with no device.
        if UITestSupport.mockConnection {
            let backend = MockSimulationBackend()
            daemonBridge = backend
            connectionStatus = .connected
            addLog("Connected (mock backend — UI test).")
            await sim.updateBaseSpeed(effectiveBaseSpeedMPS)
            await sim.attach(backend: backend)
            await sim.startJoystick(baseSpeed: effectiveBaseSpeedMPS)
            return
        }
        #endif

        sweepStaleDaemonsIfNeeded()

        connectionStatus = .connecting
        addLog("Authenticating to start tunnel for device …\(udid.suffix(8))")
        do {
            let info = try await tunnelSupervisor.start(udid: udid)
            rsdAddress = info.address
            rsdPort = String(info.port)
            addLog("Tunnel up: [\(info.address)]:\(info.port)")
        } catch {
            connectionStatus = .error(error.localizedDescription)
            addLog("Tunnel failed: \(error.localizedDescription)")
            return
        }

        addLog("Connecting to [\(rsdAddress)]:\(rsdPort)...")

        let bridge = DaemonBridge()
        self.daemonBridge = bridge

        // Consume out-of-band events (daemon death, tunnel down). The stream is
        // Sendable so the iterator runs off MainActor; each event hops back
        // here to mutate UI-bound state. Cancelled in disconnect/teardown.
        eventsTask?.cancel()
        let stream = bridge.events
        eventsTask = Task { [weak self] in
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
            connectionStatus = .connected
            addLog("Connected — ready for commands.")
            await sim.updateBaseSpeed(effectiveBaseSpeedMPS)
            await sim.attach(backend: bridge)
            await sim.startJoystick(baseSpeed: effectiveBaseSpeedMPS)
            if simState.simulatedCoordinate == nil {
                addLog("Joystick armed (\(transportLabel) speed) — long-press the map to set a starting location")
            } else {
                addLog("Joystick armed (\(transportLabel) speed)")
            }
        } catch {
            connectionStatus = .error(error.localizedDescription)
            addLog("Connection failed: \(error.localizedDescription)")
            eventsTask?.cancel()
            eventsTask = nil
            self.daemonBridge = nil
            // The bridge failed but the tunnel may be up — tear it down so a
            // retry gets a fresh tunnel.
            await tunnelSupervisor.stop()
        }
    }

    func disconnect() async {
        eventsTask?.cancel()
        eventsTask = nil
        await sim.detach()
        if let bridge = daemonBridge {
            await bridge.stop()
        }
        daemonBridge = nil
        // Tear the tunnel down *after* the daemon — the daemon's QUIT path
        // calls location.clear() over the DVT session, which requires the
        // tunnel to still be alive.
        await tunnelSupervisor.stop()
        connectionStatus = .disconnected
        addLog("Disconnected.")
    }

    // MARK: - Teleport

    func teleport(to coordinate: CLLocationCoordinate2D) {
        guard connectionStatus.isConnected else { return }
        Task {
            await sim.teleport(to: coordinate)
            addLog(String(format: "Teleported to %.6f, %.6f", coordinate.latitude, coordinate.longitude))
        }
    }

    func clearLocation() async {
        guard connectionStatus.isConnected, let bridge = daemonBridge else { return }
        do {
            try await bridge.sendCommand("CLEAR")
            await sim.clearForLocationCleared()
            addLog("Location cleared.")
        } catch {
            addLog("Clear failed: \(error.localizedDescription)")
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
            addLog("Select both From and To locations first.")
            return
        }
        let via = stops.compactMap { $0.coordinate }
        guard via.count == stops.count else {
            addLog("Resolve all stop locations first.")
            return
        }
        if stops.count > 10 {
            addLog("Note: routing \(stops.count) stops — Apple Maps may throttle.")
        }

        isCalculatingRoute = true
        defer { isCalculatingRoute = false }
        addLog("Calculating route...")

        guard let result = await buildRoute(from: from, via: via, to: to) else { return }
        routeCoordinates = result.coords
        await sim.loadRoute(coordinates: result.coords, baseSpeed: effectiveBaseSpeedMPS, resetStart: true)

        let suffix = stops.isEmpty ? "" : " · via \(stops.count) \(stops.count == 1 ? "stop" : "stops")"
        let distKm = result.distance / 1000
        let timeMin = result.time / 60
        addLog(String(format: "Route: %.1f km, ~%.0f min (%@)%@", distKm, timeMin, transportLabel, suffix))
    }

    // Straight-line travel from the current simulated position to `dest`. Uses
    // NavigationEngine's two-point case (it already handles linear interpolation).
    func travelDirectly(to dest: CLLocationCoordinate2D) {
        guard connectionStatus.isConnected else { return }
        guard let from = simState.simulatedCoordinate else {
            addLog("Set an origin first — long-press the map to teleport.")
            return
        }

        let coords = [from, dest]
        routeCoordinates = coords
        let mult = speedMultiplier
        let speed = effectiveBaseSpeedMPS
        let meters = CLLocation(latitude: from.latitude, longitude: from.longitude)
            .distance(from: CLLocation(latitude: dest.latitude, longitude: dest.longitude))
        addLog(String(format: "Direct travel: %.0f m at %@", meters, transportLabel))
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
            addLog("No route to append to.")
            return
        }
        let tailLoc = CLLocation(latitude: tail.latitude, longitude: tail.longitude)
        let destLoc = CLLocation(latitude: dest.latitude, longitude: dest.longitude)
        let meters = tailLoc.distance(from: destLoc)
        routeCoordinates.append(dest)
        await sim.loadRoute(coordinates: routeCoordinates, baseSpeed: effectiveBaseSpeedMPS, resetStart: false)
        addLog(String(format: "Appended direct segment: +%.0f m", meters))
    }

    // Extend the current route via MKDirections from its last point to `dest`.
    // Preserves playback state. Ignores side-panel stops (same reasoning as
    // routeFromCurrent).
    func appendRoute(to dest: CLLocationCoordinate2D) async {
        guard let tail = routeCoordinates.last else {
            addLog("No route to append to.")
            return
        }
        isCalculatingRoute = true
        defer { isCalculatingRoute = false }
        addLog("Appending route segment...")

        guard let result = await buildRoute(from: tail, via: [], to: dest) else { return }
        routeCoordinates = RouteMath.joinSegments(routeCoordinates, result.coords)
        await sim.loadRoute(coordinates: routeCoordinates, baseSpeed: effectiveBaseSpeedMPS, resetStart: false)
        addLog(String(format: "Appended routed segment: +%.1f km, +%.0f min", result.distance / 1000, result.time / 60))
    }

    // Apple Maps routing from current simulated position to `dest`. Auto-plays.
    // Intentionally ignores the side-panel stops: long-press is an ad-hoc flow
    // with a different start point, and silently injecting panel stops would
    // surprise the user.
    func routeFromCurrent(to dest: CLLocationCoordinate2D) async {
        guard connectionStatus.isConnected else { return }
        guard let from = simState.simulatedCoordinate else {
            addLog("Set an origin first — long-press the map to teleport.")
            return
        }

        isCalculatingRoute = true
        defer { isCalculatingRoute = false }
        addLog("Routing from current position...")

        guard let result = await buildRoute(from: from, via: [], to: dest) else { return }
        routeCoordinates = result.coords
        await sim.loadRoute(coordinates: result.coords, baseSpeed: effectiveBaseSpeedMPS, resetStart: true)

        let distKm = result.distance / 1000
        let timeMin = result.time / 60
        addLog(String(format: "Route: %.1f km, ~%.0f min (%@)", distKm, timeMin, transportLabel))
        await sim.play(multiplier: speedMultiplier)
    }

    // Builds a meandering polyline of length ≈ speed × duration via chained
    // MKDirections hops, then plays it back. The long-pressed point seeds the
    // disc center and is the playback start; the wander may leak slightly
    // outside the disc by design.
    func wanderNearby(center: CLLocationCoordinate2D, radius: Double, duration: TimeInterval) async {
        guard connectionStatus.isConnected else { return }

        isCalculatingRoute = true
        addLog("Generating wander route…")

        let speed = effectiveBaseSpeedMPS
        let options = WanderRouteBuilder.Options(
            center: center,
            radiusMeters: radius,
            durationSeconds: duration,
            speedMPS: speed,
            transportType: effectiveDirectionsTransportType
        )

        do {
            let result = try await WanderRouteBuilder.build(options: options)
            routeCoordinates = result.coordinates
            await sim.loadRoute(coordinates: result.coordinates, baseSpeed: speed, resetStart: true)

            let distKm = result.distanceMeters / 1000
            let estMin = speed > 0 ? result.distanceMeters / speed / 60 : 0
            addLog(String(format: "Wander route: %.1f km, ~%.0f min (%@)", distKm, estMin, transportLabel))
            if result.hopFailures > 0 {
                addLog("Wander hop failures: \(result.hopFailures)")
            }
            await sim.play(multiplier: speedMultiplier)
        } catch {
            addLog("Wander failed: \(error.localizedDescription)")
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
        await sim.loadRoute(coordinates: coords, baseSpeed: effectiveBaseSpeedMPS, resetStart: true)

        var meters = 0.0
        for i in 1..<coords.count {
            meters += CLLocation(latitude: coords[i - 1].latitude, longitude: coords[i - 1].longitude)
                .distance(from: CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude))
        }
        let estMin = effectiveBaseSpeedMPS > 0 ? meters / effectiveBaseSpeedMPS / 60 : 0
        addLog(String(format: "Drawn route: %.1f km, ~%.0f min (%@)", meters / 1000, estMin, transportLabel))
    }

    func startPlayback() {
        guard !routeCoordinates.isEmpty, connectionStatus.isConnected else { return }
        let mult = speedMultiplier
        addLog(String(format: "Playing route at %.0f×%@...", mult, loopLogSuffix))
        Task { await sim.play(multiplier: mult) }
    }

    private var loopLogSuffix: String {
        let count = loopCount == 0 ? "∞" : "\(loopCount)"
        switch loopMode {
        case .off: return ""
        case .restart: return " (restart loop, \(count))"
        case .pingPong: return " (ping-pong loop, \(count))"
        }
    }

    func pausePlayback() {
        Task {
            await sim.pause()
            addLog("Playback paused.")
        }
    }

    func resumePlayback() {
        let mult = speedMultiplier
        Task {
            await sim.resume(multiplier: mult)
            addLog("Playback resumed.")
        }
    }

    func stopPlayback() {
        Task {
            await sim.stopPlayback()
            addLog("Playback stopped.")
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
            addLog(String(format: "Seeked to %d%% (%@).", Int((progress * 100).rounded()), distance))
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
            addLog("Rejoined route")
        }
    }

    // Forwarded from ContentView's joystick input handling — previously direct
    // engine calls; now route through the actor that owns the engine.
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
                addLog("GPX file contains no coordinates.")
                return
            }

            routeCoordinates = coords
            let speed = effectiveBaseSpeedMPS
            Task { await sim.loadRoute(coordinates: coords, baseSpeed: speed, resetStart: false) }
            addLog("Imported \(coords.count) points from \(url.lastPathComponent)")
        } catch {
            addLog("Failed to read GPX: \(error.localizedDescription)")
        }
    }

    func exportGPX() {
        guard !routeCoordinates.isEmpty else {
            addLog("No route to export.")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "gpx") ?? .xml]
        panel.nameFieldStringValue = "route.gpx"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let gpx = GPXService.generate(coordinates: routeCoordinates, speedMPS: effectiveBaseSpeedMPS)
        do {
            try gpx.write(to: url, atomically: true, encoding: .utf8)
            addLog("Exported \(routeCoordinates.count) points to \(url.lastPathComponent)")
        } catch {
            addLog("Failed to write GPX: \(error.localizedDescription)")
        }
    }

    // MARK: - Saved Locations

    func saveCurrentLocation(name: String) {
        guard let coord = simState.simulatedCoordinate else { return }
        let waypoint = SavedWaypoint(name: name, latitude: coord.latitude, longitude: coord.longitude)
        savedWaypoints.append(waypoint)
        persistWaypoints()
        addLog("Saved location: \(name)")
    }

    func deleteWaypoint(_ waypoint: SavedWaypoint) {
        savedWaypoints.removeAll { $0.id == waypoint.id }
        persistWaypoints()
    }

    func renameWaypoint(_ waypoint: SavedWaypoint, to newName: String) {
        guard let index = savedWaypoints.firstIndex(where: { $0.id == waypoint.id }) else { return }
        savedWaypoints[index].name = newName
        persistWaypoints()
    }

    func teleportToWaypoint(_ waypoint: SavedWaypoint) {
        teleport(to: waypoint.coordinate)
    }

    // MARK: - Recording

    func toggleRecording() {
        if simState.isRecording {
            Task {
                do {
                    if let url = try await sim.stopRecording() {
                        addLog("Recording saved: \(url.lastPathComponent)")
                    } else {
                        addLog("Recording stopped (no points captured).")
                    }
                } catch {
                    addLog("Failed to save recording: \(error.localizedDescription)")
                }
            }
        } else {
            Task {
                await sim.startRecording()
                addLog("Recording started.")
            }
        }
    }

    func replayRecording(_ session: RecorderService.Session) {
        guard connectionStatus.isConnected else {
            addLog("Connect to a device before replaying.")
            return
        }
        let coords = session.points.map { $0.coordinate }
        guard !coords.isEmpty else { return }
        routeCoordinates = coords
        let speed = effectiveBaseSpeedMPS
        let mult = speedMultiplier
        addLog("Replaying recording (\(session.points.count) points)")
        Task {
            await sim.stopPlayback()
            await sim.loadRoute(coordinates: coords, baseSpeed: speed, resetStart: true)
            await sim.play(multiplier: mult)
        }
    }

    func exportRecording(_ session: RecorderService.Session) {
        guard let src = session.fileURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "gpx") ?? .xml]
        panel.nameFieldStringValue = src.lastPathComponent

        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: src, to: dest)
            addLog("Exported recording to \(dest.lastPathComponent)")
        } catch {
            addLog("Export failed: \(error.localizedDescription)")
        }
    }

    func deleteRecording(_ session: RecorderService.Session) {
        recorder.delete(session)
    }

    // MARK: - Saved Routes

    func saveCurrentRoute(name: String, source: String = "calculated", sourceDetail: String? = nil) {
        guard !routeCoordinates.isEmpty else {
            addLog("No route to save.")
            return
        }
        // Capture the planner inputs only when this route came from the planner;
        // direct/recorded/imported sources have no editable inputs to round-trip.
        let plannerFrom: SavedRoute.NamedCoord? = source == "calculated"
            ? fromCoordinate.map { SavedRoute.NamedCoord(lat: $0.latitude, lon: $0.longitude, label: fromSearch.query) }
            : nil
        let plannerTo: SavedRoute.NamedCoord? = source == "calculated"
            ? toCoordinate.map { SavedRoute.NamedCoord(lat: $0.latitude, lon: $0.longitude, label: toSearch.query) }
            : nil
        let plannerStops: [SavedRoute.NamedCoord]? = source == "calculated"
            ? stops.compactMap { stop in
                stop.coordinate.map { SavedRoute.NamedCoord(lat: $0.latitude, lon: $0.longitude, label: stop.search.query) }
            }
            : nil
        let route = SavedRoute(
            id: UUID(),
            name: name,
            createdAt: Date(),
            transportModeRaw: transportMode.rawValue,
            customSpeedKmh: transportMode == .custom ? customSpeedKmh : nil,
            coordinates: routeCoordinates.map { .init(lat: $0.latitude, lon: $0.longitude) },
            source: source,
            sourceDetail: sourceDetail,
            fromWaypoint: plannerFrom,
            toWaypoint: plannerTo,
            stopWaypoints: plannerStops
        )
        do {
            try savedRoutes.save(route)
            addLog("Saved route: \(name)")
        } catch {
            addLog("Save failed: \(error.localizedDescription)")
        }
    }

    func loadSavedRoute(_ route: SavedRoute, autoPlay: Bool = false) {
        let coords = route.clCoordinates
        guard !coords.isEmpty else { return }

        transportMode = route.transportMode
        if let custom = route.customSpeedKmh {
            customSpeedKmh = custom
        }

        // Restore planner inputs so the loaded route is re-editable. Older
        // saved routes (and non-"calculated" sources) have nil here; in that
        // case clear the planner so stale fields don't linger from whatever
        // the user was planning before.
        if let f = route.fromWaypoint {
            fromCoordinate = CLLocationCoordinate2D(latitude: f.lat, longitude: f.lon)
            fromSearch.setQuery(f.label ?? "")
        } else {
            fromCoordinate = nil
            fromSearch.setQuery("")
        }
        if let t = route.toWaypoint {
            toCoordinate = CLLocationCoordinate2D(latitude: t.lat, longitude: t.lon)
            toSearch.setQuery(t.label ?? "")
        } else {
            toCoordinate = nil
            toSearch.setQuery("")
        }
        stops = (route.stopWaypoints ?? []).map { saved in
            let s = RouteStop()
            s.coordinate = CLLocationCoordinate2D(latitude: saved.lat, longitude: saved.lon)
            s.search.setQuery(saved.label ?? "")
            return s
        }

        routeCoordinates = coords
        let speed = effectiveBaseSpeedMPS
        let mult = speedMultiplier
        let shouldPlay = autoPlay && connectionStatus.isConnected
        addLog("Loaded route: \(route.name)")
        Task {
            await sim.loadRoute(coordinates: coords, baseSpeed: speed, resetStart: true)
            if shouldPlay {
                await sim.play(multiplier: mult)
            }
        }
    }

    func deleteSavedRoute(_ route: SavedRoute) {
        savedRoutes.delete(route)
    }

    func renameSavedRoute(_ route: SavedRoute, to newName: String) {
        var renamed = route
        renamed.name = newName
        do {
            // save() overwrites the same <id>.json, so this is an in-place rename.
            try savedRoutes.save(renamed)
        } catch {
            addLog("Rename failed: \(error.localizedDescription)")
        }
    }

    func saveRecordingAsRoute(_ session: RecorderService.Session, name: String) {
        let coords = session.points.map { SavedRoute.Coord(lat: $0.latitude, lon: $0.longitude) }
        let route = SavedRoute(
            id: UUID(),
            name: name,
            createdAt: Date(),
            transportModeRaw: transportMode.rawValue,
            customSpeedKmh: transportMode == .custom ? customSpeedKmh : nil,
            coordinates: coords,
            source: "recorded",
            sourceDetail: session.id.uuidString,
            fromWaypoint: nil,
            toWaypoint: nil,
            stopWaypoints: nil
        )
        do {
            try savedRoutes.save(route)
            addLog("Saved recording as route: \(name)")
        } catch {
            addLog("Save failed: \(error.localizedDescription)")
        }
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
        addLog(detail)
        teardownLiveState(statusMessage: detail)
    }

    private func handleTunnelDown(line: String) {
        addLog("Tunnel down: \(line)")
        teardownLiveState(statusMessage: "Tunnel down")
    }

    private func handleSystemSleep() async {
        guard daemonBridge != nil else { return }
        addLog("Pausing — system sleeping (DVT session would drop)")
        await disconnect()
    }

    private func teardownLiveState(statusMessage: String) {
        eventsTask?.cancel(); eventsTask = nil
        daemonBridge = nil
        // Fire-and-forget — the sim detach + tunnel stop are independent.
        Task {
            await sim.detach()
            await tunnelSupervisor.stop()
        }
        connectionStatus = .error(statusMessage)
    }

    // First connect per session sweeps any orphan tm_daemon.py left over from
    // a prior host-app crash (parent watcher catches most, but isn't instant).
    private func sweepStaleDaemonsIfNeeded() {
        guard !didSweepStaleDaemons else { return }
        didSweepStaleDaemons = true
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "tm_daemon.py"]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            // pkill missing is harmless; log and continue.
            addLog("Stale-daemon sweep skipped: \(error.localizedDescription)")
        }
    }

    private func loadWaypoints() {
        guard let data = UserDefaults.standard.data(forKey: "savedWaypoints"),
              let waypoints = try? JSONDecoder().decode([SavedWaypoint].self, from: data) else { return }
        savedWaypoints = waypoints
    }

    private func persistWaypoints() {
        guard let data = try? JSONEncoder().encode(savedWaypoints) else { return }
        UserDefaults.standard.set(data, forKey: "savedWaypoints")
    }

    // MARK: - Internal

    private var transportLabel: String {
        if transportMode == .custom {
            return String(format: "Custom %.0f km/h", customSpeedKmh)
        }
        return transportMode.rawValue
    }

    private func extractCoordinates(from polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(),
            count: polyline.pointCount
        )
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
        return coords
    }

    private func stopLabel(at index: Int, total: Int) -> String {
        if index == 0 { return "From" }
        if index == total - 1 { return "To" }
        return "Stop \(index)"
    }

    private func buildRoute(
        from: CLLocationCoordinate2D,
        via: [CLLocationCoordinate2D],
        to: CLLocationCoordinate2D
    ) async -> (coords: [CLLocationCoordinate2D], distance: Double, time: TimeInterval)? {
        let stopsList = [from] + via + [to]
        var combined: [CLLocationCoordinate2D] = []
        var totalDistance = 0.0
        var totalTime: TimeInterval = 0.0

        for i in 0..<(stopsList.count - 1) {
            let a = stopsList[i]
            let b = stopsList[i + 1]
            let aLoc = CLLocation(latitude: a.latitude, longitude: a.longitude)
            let bLoc = CLLocation(latitude: b.latitude, longitude: b.longitude)
            if aLoc.distance(from: bLoc) < 1.0 { continue }

            let request = MKDirections.Request()
            request.source = MKMapItem(location: aLoc, address: nil)
            request.destination = MKMapItem(location: bLoc, address: nil)
            request.transportType = effectiveDirectionsTransportType

            let fromLabel = stopLabel(at: i, total: stopsList.count)
            let toLabel = stopLabel(at: i + 1, total: stopsList.count)

            do {
                let response = try await MKDirections(request: request).calculate()
                guard let route = response.routes.first else {
                    addLog("Route failed: \(fromLabel) → \(toLabel): no route found.")
                    return nil
                }
                let segCoords = extractCoordinates(from: route.polyline)
                combined = RouteMath.joinSegments(combined, segCoords)
                totalDistance += route.distance
                totalTime += route.expectedTravelTime
            } catch {
                addLog("Route failed: \(fromLabel) → \(toLabel): \(error.localizedDescription)")
                return nil
            }
        }

        guard combined.count >= 2 else {
            addLog("Start and end are the same location.")
            return nil
        }
        return (combined, totalDistance, totalTime)
    }

    func addLog(_ message: String) {
        let ts = Date().formatted(date: .omitted, time: .standard)
        logMessages.append("[\(ts)] \(message)")
    }
}
