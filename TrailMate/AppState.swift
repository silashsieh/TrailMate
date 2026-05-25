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

    // MainActor projection of simulation state for SwiftUI to observe.
    // SimulationActor pushes snapshots into this; views never touch the
    // engines directly.
    let simState = SimulationStateBridge()

    // Route
    var fromSearch = LocationSearch()
    var toSearch = LocationSearch()
    var fromCoordinate: CLLocationCoordinate2D?
    var toCoordinate: CLLocationCoordinate2D?
    var transportMode: TransportMode = .walk {
        didSet { Task { await syncEngineSpeeds() } }
    }
    var customSpeedKmh: Double = 15.0 {
        didSet { Task { await syncEngineSpeeds() } }
    }
    var speedMultiplier: Double = 1.0
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

    // Log
    var logMessages: [String] = []
    var showLogSheet = false

    private var daemonBridge: DaemonBridge?
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
    }

    private func syncEngineSpeeds() async {
        await sim.updateBaseSpeed(effectiveBaseSpeedMPS)
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
            await sim.loadRoute(coordinates: coords, baseSpeed: effectiveBaseSpeedMPS, resetStart: true)

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
        guard let from = simState.simulatedCoordinate else {
            addLog("Set an origin first — long-press the map to teleport.")
            return
        }

        let coords = [from, dest]
        routeCoordinates = coords
        controlMode = .route
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

    // Apple Maps routing from current simulated position to `dest`. Auto-plays.
    func routeFromCurrent(to dest: CLLocationCoordinate2D) async {
        guard connectionStatus.isConnected else { return }
        guard let from = simState.simulatedCoordinate else {
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
            controlMode = .route
            await sim.loadRoute(coordinates: coords, baseSpeed: effectiveBaseSpeedMPS, resetStart: true)

            let distKm = route.distance / 1000
            let timeMin = route.expectedTravelTime / 60
            addLog(String(format: "Route: %.1f km, ~%.0f min (%@)", distKm, timeMin, transportLabel))
            await sim.play(multiplier: speedMultiplier)
        } catch {
            addLog("Route calculation failed: \(error.localizedDescription)")
        }

        isCalculatingRoute = false
    }

    func startPlayback() {
        guard !routeCoordinates.isEmpty, connectionStatus.isConnected else { return }
        let mult = speedMultiplier
        addLog(String(format: "Playing route at %.0f×...", mult))
        Task { await sim.play(multiplier: mult) }
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

    // MARK: - Joystick

    func startJoystick() {
        let fallback = CLLocationCoordinate2D(latitude: 25.033, longitude: 121.565)
        let speed = effectiveBaseSpeedMPS
        let label = transportLabel
        Task {
            await sim.startJoystick(baseSpeed: speed, fallbackCoord: fallback)
            addLog("Joystick started (\(label) speed)")
        }
    }

    func recenterJoystick() {
        Task {
            await sim.recenterJoystick()
            addLog("Recentered to starting position")
        }
    }

    func stopJoystick() async {
        await sim.stopJoystick()
        if await sim.isPlaybackIdle {
            await clearLocation()
        }
    }

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
            controlMode = .route
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
        controlMode = .route
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
        controlMode = .route
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

    func addLog(_ message: String) {
        let ts = Date().formatted(date: .omitted, time: .standard)
        logMessages.append("[\(ts)] \(message)")
    }
}
