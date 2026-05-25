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

enum ControlMode: String, CaseIterable {
    case route = "Route"
    case joystick = "Joystick"
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

    // Mode
    var controlMode: ControlMode = .joystick

    // Teleport
    var simulatedCoordinate: CLLocationCoordinate2D?

    // Route
    var fromSearch = LocationSearch()
    var toSearch = LocationSearch()
    var fromCoordinate: CLLocationCoordinate2D?
    var toCoordinate: CLLocationCoordinate2D?
    var transportMode: TransportMode = .walk {
        didSet { syncEngineSpeeds() }
    }
    var customSpeedKmh: Double = 15.0 {
        didSet { syncEngineSpeeds() }
    }
    var speedMultiplier: Double = 1.0
    var routeCoordinates: [CLLocationCoordinate2D] = []
    var isCalculatingRoute = false
    let navigationEngine = NavigationEngine()

    // Joystick
    let joystickEngine = JoystickEngine()
    private var joystickAnchor: CLLocationCoordinate2D?

    // Discovery
    let discovery = DeviceDiscoveryService()
    var selectedDeviceUDID: String?

    // Recording
    let recorder = RecorderService()

    // Saved Routes
    let savedRoutes = SavedRoutesStore()

    // Composite control
    let positionIntegrator = PositionIntegrator()
    private var aggregatorTask: Task<Void, Never>?
    private var deviationStartedAt: Date?
    private var lastDeviationCheck: Date = .distantPast
    var routeDeviationMeters: Double = 0
    private static let deviationAbortMeters: Double = 200
    private static let deviationAbortSeconds: TimeInterval = 10

    // Saved Locations
    var savedWaypoints: [SavedWaypoint] = []

    // Realism
    var noiseSigmaMeters: Double = 5.0 {
        didSet { noise.sigmaMeters = noiseSigmaMeters }
    }
    private let noise = LocationNoise()
    private var idleJitterTask: Task<Void, Never>?

    // Log
    var logMessages: [String] = []
    var showLogSheet = false

    private var daemonBridge: DaemonBridge?
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
        let storedCustom = UserDefaults.standard.double(forKey: "customSpeedKmh")
        self.customSpeedKmh = storedCustom > 0 ? storedCustom : 15.0

        if UserDefaults.standard.object(forKey: "noiseSigmaMeters") != nil {
            self.noiseSigmaMeters = UserDefaults.standard.double(forKey: "noiseSigmaMeters")
        }
        noise.sigmaMeters = noiseSigmaMeters

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
    }

    func persistTuning() {
        UserDefaults.standard.set(customSpeedKmh, forKey: "customSpeedKmh")
        UserDefaults.standard.set(noiseSigmaMeters, forKey: "noiseSigmaMeters")
    }

    private func syncEngineSpeeds() {
        let base = effectiveBaseSpeedMPS
        navigationEngine.updateBaseSpeed(base)
        joystickEngine.updateBaseSpeed(base)
    }

    // MARK: - Connection

    func connect() async {
        guard connectionStatus != .connecting else { return }
        guard let udid = selectedDeviceUDID, !udid.isEmpty else {
            addLog("Pick a device first.")
            connectionStatus = .error("No device selected")
            return
        }

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
        bridge.onUnexpectedExit = { [weak self] status, reason in
            Task { @MainActor in
                self?.handleDaemonExit(status: status, reason: reason)
            }
        }
        bridge.onTunnelDown = { [weak self] line in
            Task { @MainActor in
                self?.handleTunnelDown(line: line)
            }
        }
        self.daemonBridge = bridge

        do {
            try await bridge.start(rsdAddress: rsdAddress, rsdPort: rsdPort)
            connectionStatus = .connected
            addLog("Connected — ready for commands.")
            startIdleJitter()
            startAggregator()
        } catch {
            connectionStatus = .error(error.localizedDescription)
            addLog("Connection failed: \(error.localizedDescription)")
            self.daemonBridge = nil
            // The bridge failed but the tunnel may be up — tear it down so a
            // retry gets a fresh tunnel.
            await tunnelSupervisor.stop()
        }
    }

    func disconnect() async {
        idleJitterTask?.cancel()
        idleJitterTask = nil
        aggregatorTask?.cancel()
        aggregatorTask = nil
        joystickEngine.stop()
        navigationEngine.stop()
        positionIntegrator.clear()
        if let bridge = daemonBridge {
            await bridge.stop()
        }
        daemonBridge = nil
        // Tear the tunnel down *after* the daemon — the daemon's QUIT path
        // calls location.clear() over the DVT session, which requires the
        // tunnel to still be alive.
        await tunnelSupervisor.stop()
        connectionStatus = .disconnected
        simulatedCoordinate = nil
        addLog("Disconnected.")
    }

    // MARK: - Teleport

    func teleport(to coordinate: CLLocationCoordinate2D) {
        guard connectionStatus.isConnected else { return }

        // A teleport is an explicit jump — preempt route playback so the marker
        // doesn't snap back on the next tick.
        if navigationEngine.playbackState != .idle {
            navigationEngine.stop()
        }

        positionIntegrator.reset(to: coordinate)
        emitSimulated(coordinate)
        addLog(String(format: "Teleported to %.6f, %.6f", coordinate.latitude, coordinate.longitude))

        if joystickEngine.isActive {
            joystickAnchor = coordinate
        }
    }

    func clearLocation() async {
        guard connectionStatus.isConnected, let bridge = daemonBridge else { return }
        navigationEngine.stop()

        do {
            try await bridge.sendCommand("CLEAR")
            simulatedCoordinate = nil
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

    func selectTo(_ completion: MKLocalSearchCompletion) async {
        toSearch.select(completion)
        toCoordinate = await toSearch.resolve(completion)
    }

    func calculateRoute() async {
        guard let from = fromCoordinate, let to = toCoordinate else {
            addLog("Select both From and To locations first.")
            return
        }

        isCalculatingRoute = true
        addLog("Calculating route...")

        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: from.latitude, longitude: from.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: to.latitude, longitude: to.longitude), address: nil)
        request.transportType = effectiveDirectionsTransportType

        do {
            let directions = MKDirections(request: request)
            let response = try await directions.calculate()
            guard let route = response.routes.first else {
                addLog("No route found.")
                isCalculatingRoute = false
                return
            }

            let coords = extractCoordinates(from: route.polyline)
            routeCoordinates = coords
            navigationEngine.loadRoute(coordinates: coords, baseSpeed: effectiveBaseSpeedMPS)
            if let first = coords.first {
                positionIntegrator.reset(to: first)
                simulatedCoordinate = first
            }

            let distKm = route.distance / 1000
            let timeMin = route.expectedTravelTime / 60
            addLog(String(format: "Route: %.1f km, ~%.0f min (%@)", distKm, timeMin, transportLabel))
        } catch {
            addLog("Route calculation failed: \(error.localizedDescription)")
        }

        isCalculatingRoute = false
    }

    // Straight-line travel from the current simulated position to `dest`. Uses
    // NavigationEngine's two-point case (it already handles linear interpolation).
    func travelDirectly(to dest: CLLocationCoordinate2D) {
        guard connectionStatus.isConnected else { return }
        guard let from = simulatedCoordinate else {
            addLog("Set an origin first — long-press the map to teleport.")
            return
        }

        let coords = [from, dest]
        routeCoordinates = coords
        navigationEngine.loadRoute(coordinates: coords, baseSpeed: effectiveBaseSpeedMPS)
        positionIntegrator.reset(to: from)
        controlMode = .route

        let meters = CLLocation(latitude: from.latitude, longitude: from.longitude)
            .distance(from: CLLocation(latitude: dest.latitude, longitude: dest.longitude))
        addLog(String(format: "Direct travel: %.0f m at %@", meters, transportLabel))
        navigationEngine.play(multiplier: speedMultiplier)
    }

    // Apple Maps routing from current simulated position to `dest`. Auto-plays.
    func routeFromCurrent(to dest: CLLocationCoordinate2D) async {
        guard connectionStatus.isConnected else { return }
        guard let from = simulatedCoordinate else {
            addLog("Set an origin first — long-press the map to teleport.")
            return
        }

        isCalculatingRoute = true
        addLog("Routing from current position...")

        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: from.latitude, longitude: from.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: dest.latitude, longitude: dest.longitude), address: nil)
        request.transportType = effectiveDirectionsTransportType

        do {
            let directions = MKDirections(request: request)
            let response = try await directions.calculate()
            guard let route = response.routes.first else {
                addLog("No route found.")
                isCalculatingRoute = false
                return
            }

            let coords = extractCoordinates(from: route.polyline)
            routeCoordinates = coords
            navigationEngine.loadRoute(coordinates: coords, baseSpeed: effectiveBaseSpeedMPS)
            positionIntegrator.reset(to: coords.first ?? from)
            controlMode = .route

            let distKm = route.distance / 1000
            let timeMin = route.expectedTravelTime / 60
            addLog(String(format: "Route: %.1f km, ~%.0f min (%@)", distKm, timeMin, transportLabel))
            navigationEngine.play(multiplier: speedMultiplier)
        } catch {
            addLog("Route calculation failed: \(error.localizedDescription)")
        }

        isCalculatingRoute = false
    }

    func startPlayback() {
        guard !routeCoordinates.isEmpty, connectionStatus.isConnected else { return }
        if positionIntegrator.position == nil, let first = routeCoordinates.first {
            positionIntegrator.reset(to: first)
        }
        addLog(String(format: "Playing route at %.0f×...", speedMultiplier))
        navigationEngine.play(multiplier: speedMultiplier)
    }

    func pausePlayback() {
        navigationEngine.pause()
        addLog("Playback paused.")
    }

    func resumePlayback() {
        navigationEngine.resume(multiplier: speedMultiplier)
        addLog("Playback resumed.")
    }

    func stopPlayback() {
        navigationEngine.stop()
        simulatedCoordinate = nil
        addLog("Playback stopped.")
    }

    // MARK: - Joystick

    func startJoystick() {
        let startCoord = simulatedCoordinate ?? CLLocationCoordinate2D(latitude: 25.033, longitude: 121.565)
        joystickAnchor = startCoord
        if positionIntegrator.position == nil {
            positionIntegrator.reset(to: startCoord)
        }
        joystickEngine.start(baseSpeed: effectiveBaseSpeedMPS)
        addLog("Joystick started (\(transportLabel) speed)")
    }

    func recenterJoystick() {
        guard let anchor = joystickAnchor else { return }
        positionIntegrator.reset(to: anchor)
        emitSimulated(anchor)
        addLog("Recentered to starting position")
    }

    func stopJoystick() async {
        joystickEngine.stop()
        if navigationEngine.playbackState == .idle {
            await clearLocation()
        }
    }

    func rejoinRoute() {
        guard let expected = navigationEngine.expectedPosition else { return }
        positionIntegrator.reset(to: expected)
        emitSimulated(expected)
        deviationStartedAt = nil
        routeDeviationMeters = 0
        addLog("Rejoined route")
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
            navigationEngine.loadRoute(coordinates: coords, baseSpeed: effectiveBaseSpeedMPS)
            controlMode = .route
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
        guard let coord = simulatedCoordinate else { return }
        let waypoint = SavedWaypoint(name: name, latitude: coord.latitude, longitude: coord.longitude)
        savedWaypoints.append(waypoint)
        persistWaypoints()
        addLog("Saved location: \(name)")
    }

    func deleteWaypoint(_ waypoint: SavedWaypoint) {
        savedWaypoints.removeAll { $0.id == waypoint.id }
        persistWaypoints()
    }

    func teleportToWaypoint(_ waypoint: SavedWaypoint) {
        teleport(to: waypoint.coordinate)
    }

    // MARK: - Recording

    func toggleRecording() {
        if recorder.isRecording {
            do {
                if let url = try recorder.stop() {
                    addLog("Recording saved: \(url.lastPathComponent)")
                } else {
                    addLog("Recording stopped (no points captured).")
                }
            } catch {
                addLog("Failed to save recording: \(error.localizedDescription)")
            }
        } else {
            recorder.start()
            addLog("Recording started.")
        }
    }

    func replayRecording(_ session: RecorderService.Session) {
        guard connectionStatus.isConnected else {
            addLog("Connect to a device before replaying.")
            return
        }
        navigationEngine.stop()
        let coords = session.points.map { $0.coordinate }
        guard !coords.isEmpty else { return }
        routeCoordinates = coords
        navigationEngine.loadRoute(coordinates: coords, baseSpeed: effectiveBaseSpeedMPS)
        if let first = coords.first {
            positionIntegrator.reset(to: first)
        }
        controlMode = .route
        addLog("Replaying recording (\(session.points.count) points)")
        navigationEngine.play(multiplier: speedMultiplier)
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
        let route = SavedRoute(
            id: UUID(),
            name: name,
            createdAt: Date(),
            transportModeRaw: transportMode.rawValue,
            customSpeedKmh: transportMode == .custom ? customSpeedKmh : nil,
            coordinates: routeCoordinates.map { .init(lat: $0.latitude, lon: $0.longitude) },
            source: source,
            sourceDetail: sourceDetail
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

        routeCoordinates = coords
        navigationEngine.loadRoute(coordinates: coords, baseSpeed: effectiveBaseSpeedMPS)
        if let first = coords.first {
            positionIntegrator.reset(to: first)
            simulatedCoordinate = first
        }
        controlMode = .route
        addLog("Loaded route: \(route.name)")

        if autoPlay, connectionStatus.isConnected {
            navigationEngine.play(multiplier: speedMultiplier)
        }
    }

    func deleteSavedRoute(_ route: SavedRoute) {
        savedRoutes.delete(route)
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
            sourceDetail: session.id.uuidString
        )
        do {
            try savedRoutes.save(route)
            addLog("Saved recording as route: \(name)")
        } catch {
            addLog("Save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

    // Invoked by DaemonBridge.terminationHandler when the daemon dies on its own
    // (crash, kill, our SIGKILL escalator). Tear down Swift-side state that
    // assumed the daemon was alive. Don't auto-restart — the user clicks Connect.
    private func handleDaemonExit(status: Int32, reason: Process.TerminationReason) {
        let detail: String
        switch (status, reason) {
        case (0, _):                detail = "Daemon exited"
        case (_, .uncaughtSignal):  detail = "Daemon killed (signal)"
        default:                    detail = "Daemon crashed (exit \(status))"
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
        idleJitterTask?.cancel(); idleJitterTask = nil
        aggregatorTask?.cancel(); aggregatorTask = nil
        joystickEngine.stop()
        navigationEngine.stop()
        positionIntegrator.clear()
        daemonBridge = nil
        // The tunnel is per-session and per-daemon — if the daemon crashed,
        // a fresh reconnect needs a fresh tunnel. Fire-and-forget the stop
        // sentinel; the root wrapper sees it and tears itself down.
        Task { await tunnelSupervisor.stop() }
        connectionStatus = .error(statusMessage)
        simulatedCoordinate = nil
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

    private func handlePlaybackPosition(_ coordinate: CLLocationCoordinate2D) {
        emitSimulated(coordinate)
    }

    // Single chokepoint for every coordinate destined for the device. The map
    // marker shows the intent (`clean`); the device receives a noise-perturbed
    // sample so the reported fix has the same statistical shape as real GPS.
    private func emitSimulated(_ clean: CLLocationCoordinate2D) {
        simulatedCoordinate = clean
        let noisy = noise.apply(to: clean)
        daemonBridge?.setLocationQuiet(latitude: noisy.latitude, longitude: noisy.longitude)
        // Record the clean (intent) coord, not the noisy one — noise is a
        // transport-layer effect, not a property of the trajectory.
        recorder.append(clean)
    }

    // 1Hz re-emit so an idle "stationary" device still wiggles within σ — what a
    // real iPhone sitting on the desk reports. Suppressed during playback or
    // joystick where the active loop already drives emissions.
    private func startIdleJitter() {
        idleJitterTask?.cancel()
        idleJitterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                guard self.connectionStatus.isConnected,
                      self.navigationEngine.playbackState != .playing,
                      !self.joystickEngine.isActive,
                      let coord = self.simulatedCoordinate else { continue }
                self.emitSimulated(coord)
            }
        }
    }

    // 20 Hz: pulls a velocity vector from each active engine, sums them, steps
    // the shared integrator, and emits. This is what lets joystick deviation
    // ride on top of route playback rather than the two fighting for ownership
    // of the simulated position.
    private func startAggregator() {
        aggregatorTask?.cancel()
        aggregatorTask = Task { [weak self] in
            let dt: TimeInterval = 0.05
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                guard self.connectionStatus.isConnected else { continue }
                self.aggregatorTick(dt: dt)
            }
        }
    }

    private func aggregatorTick(dt: TimeInterval) {
        var vx = 0.0, vy = 0.0
        var anyContribution = false

        if let nv = navigationEngine.tick(dt: dt) {
            vx += nv.vx; vy += nv.vy
            anyContribution = true
        }
        if let jv = joystickEngine.tick() {
            vx += jv.vx; vy += jv.vy
            anyContribution = true
        }

        guard anyContribution else {
            // Engines are inactive — reset deviation tracking so it doesn't
            // carry over into the next route.
            if routeDeviationMeters != 0 { routeDeviationMeters = 0 }
            deviationStartedAt = nil
            return
        }

        positionIntegrator.step(vx: vx, vy: vy, dt: dt)

        guard let pos = positionIntegrator.position else { return }
        emitSimulated(pos)

        if navigationEngine.playbackState == .playing {
            let now = Date()
            guard now.timeIntervalSince(lastDeviationCheck) >= 0.2 else { return }
            lastDeviationCheck = now
            let dev = navigationEngine.distanceFromRoute(pos)
            routeDeviationMeters = dev
            if dev > Self.deviationAbortMeters {
                if deviationStartedAt == nil { deviationStartedAt = Date() }
                if let started = deviationStartedAt,
                   Date().timeIntervalSince(started) > Self.deviationAbortSeconds {
                    navigationEngine.stop()
                    deviationStartedAt = nil
                    addLog("Route aborted — drifted >\(Int(Self.deviationAbortMeters)) m for \(Int(Self.deviationAbortSeconds)) s")
                }
            } else {
                deviationStartedAt = nil
            }
        } else if routeDeviationMeters != 0 {
            routeDeviationMeters = 0
            deviationStartedAt = nil
        }
    }

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

    func addLog(_ message: String) {
        let ts = Date().formatted(date: .omitted, time: .standard)
        logMessages.append("[\(ts)] \(message)")
    }
}
