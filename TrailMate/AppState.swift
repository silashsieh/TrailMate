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

    // Localized label for the UI. rawValue stays English — it's persisted in
    // UserDefaults ("transportMode") and SavedRoute.transportModeRaw, so it
    // must not change with the system language.
    var displayName: String {
        switch self {
        case .walk: String(localized: "Walk")
        case .cycle: String(localized: "Cycle")
        case .drive: String(localized: "Drive")
        case .custom: String(localized: "Custom")
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

// The device manager. Owns app-global concerns — discovery, the device
// selection, shared libraries (saved routes/waypoints/recordings), the routing
// kernel, the tuning the control surface edits, and the log — plus the device
// session(s). Today it owns exactly one `session` (built eagerly at launch so
// the UI can read its red dot and plan routes before any device connects); at
// multi-device this becomes a UDID-keyed collection. The UI binds to AppState
// and reaches per-device state through forwarding accessors that resolve to the
// active session, so views never need to know the session exists.
@Observable
@MainActor
final class AppState {
    // The active device session. Implicitly-unwrapped because it back-references
    // self and so must be built in init() after the stored properties exist;
    // assigned once and never nil thereafter.
    private(set) var session: DeviceSession!

    // The UDID the active session is currently connected to, or nil when
    // disconnected. Snapshotted from selectedDeviceUDID *after* a successful
    // connect (in the connect() forwarder), so it's a stable binding the AI
    // dispatch can match against without ever reading the live GUI selection —
    // which the user can change mid-session. At multi-device (epic 012) this
    // collapses into the UDID-keyed session collection the manager will own.
    private(set) var connectedUDID: String?

    // AI command server. Implicitly-unwrapped for the same reason as `session`:
    // it back-references self. Holds the AF_UNIX listener; only running while
    // aiControlEnabled is on.
    private var commandServer: CommandServer!

    // MARK: App-global tuning (the control surface edits these; bound in the UI)

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

    // Realism
    var noiseSigmaMeters: Double = 5.0 {
        didSet {
            let sigma = noiseSigmaMeters
            Task { await session.sim.updateNoiseSigma(sigma) }
        }
    }

    // Launch behavior (epic 005). The position is always saved; this only
    // gates whether the next launch restores it or starts empty.
    var restoreLastSimulatedLocation: Bool = SimulatedPositionPersistence.restoreOnLaunch {
        didSet { SimulatedPositionPersistence.restoreOnLaunch = restoreLastSimulatedLocation }
    }

    // AI control (epic 019). Off by default — gates the Unix-socket command
    // server entirely, so there's no attack surface until the user opts in.
    // Persisted so the choice survives relaunch; the didSet starts/stops the
    // server live when toggled in Settings.
    var aiControlEnabled: Bool = UserDefaults.standard.bool(forKey: "aiControlEnabled") {
        didSet {
            guard aiControlEnabled != oldValue else { return }
            UserDefaults.standard.set(aiControlEnabled, forKey: "aiControlEnabled")
            if aiControlEnabled {
                commandServer.start()
                addLog("AI control enabled.")
            } else {
                commandServer.stop()
                addLog("AI control disabled.")
            }
        }
    }

    // MARK: App-global services & libraries

    let discovery = DeviceDiscoveryService()
    var selectedDeviceUDID: String?
    let recorder = RecorderService()
    let savedRoutes = SavedRoutesStore()
    var savedWaypoints: [SavedWaypoint] = []

    // Routing kernel (D4). Swappable behind the protocol; MapKit today. Stateless
    // and shared across sessions (the MapKit throttle is per-process, not
    // per-route).
    let router: any RoutingService = MapKitRoutingService()

    // Log
    var logMessages: [String] = []
    var showLogSheet = false

    // Wander sheet
    var showWanderSheet = false
    var pendingWanderCenter: CLLocationCoordinate2D?

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
        // All other stored properties have default values, so `self` is fully
        // initialized here; build the session first so the tuning didSets and
        // the restore-teleport below have a `session.sim` to reach.
        self.session = DeviceSession(manager: self)
        self.commandServer = CommandServer(appState: self)

        let storedCustom = UserDefaults.standard.double(forKey: "customSpeedKmh")
        self.customSpeedKmh = storedCustom > 0 ? storedCustom : 15.0

        if UserDefaults.standard.object(forKey: "noiseSigmaMeters") != nil {
            self.noiseSigmaMeters = UserDefaults.standard.double(forKey: "noiseSigmaMeters")
        }

        if let raw = UserDefaults.standard.string(forKey: "transportMode"),
           let mode = TransportMode(rawValue: raw) {
            self.transportMode = mode
        }
        // didSets don't fire for in-init assignments, so seed the engine
        // explicitly (base speed is also re-pushed on connect).
        let initialSigma = noiseSigmaMeters
        Task { await session.sim.updateNoiseSigma(initialSigma) }

        // System sleep tears down the DVT session unconditionally (Apple's
        // design — see v2-features.md). Drop the connection cleanly so the
        // UI doesn't claim we're still connected after wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.session.handleSystemSleep()
            }
        }

        loadWaypoints()
        recorder.loadIndex()
        savedRoutes.load()

        // The aiControlEnabled didSet doesn't fire for the in-init default, so
        // start the server explicitly when the persisted choice is on. start()
        // unlink()s any stale socket from a prior crash before binding.
        if aiControlEnabled {
            commandServer.start()
        }

        // Seed the red dot from the last session (display only — emit()
        // reaches no backend until connect; attach() broadcasts it then).
        // Bypasses the UI teleport's isConnected guard deliberately.
        if restoreLastSimulatedLocation {
            let restored = SimulatedPositionPersistence.load()
                ?? SimulatedPositionPersistence.defaultCoordinate
            Task { await session.sim.teleport(to: restored) }
        }

        #if DEBUG
        if UITestSupport.openWander {
            pendingWanderCenter = CLLocationCoordinate2D(latitude: 25.0339, longitude: 121.5645)
            showWanderSheet = true
        }
        #endif
    }

    // MARK: - Tuning relays

    func persistTuning() {
        UserDefaults.standard.set(customSpeedKmh, forKey: "customSpeedKmh")
        UserDefaults.standard.set(noiseSigmaMeters, forKey: "noiseSigmaMeters")
        UserDefaults.standard.set(transportMode.rawValue, forKey: "transportMode")
    }

    private func syncEngineSpeeds() async {
        await session.sim.updateBaseSpeed(effectiveBaseSpeedMPS)
    }

    private func pushLoopConfig() {
        let mode = loopMode
        let count = loopCount
        Task { await session.sim.updateLoop(mode: mode, count: count) }
    }

    // MARK: - Per-device forwards (UI reads/calls AppState; we resolve the active session)

    var simState: SimulationStateBridge { session.simState }
    var connectionStatus: ConnectionStatus { session.connectionStatus }
    var isCalculatingRoute: Bool { session.isCalculatingRoute }
    var routeCoordinates: [CLLocationCoordinate2D] {
        get { session.routeCoordinates }
        set { session.routeCoordinates = newValue }
    }
    var fromSearch: LocationSearch { session.fromSearch }
    var toSearch: LocationSearch { session.toSearch }
    var fromCoordinate: CLLocationCoordinate2D? {
        get { session.fromCoordinate }
        set { session.fromCoordinate = newValue }
    }
    var toCoordinate: CLLocationCoordinate2D? {
        get { session.toCoordinate }
        set { session.toCoordinate = newValue }
    }
    var stops: [RouteStop] {
        get { session.stops }
        set { session.stops = newValue }
    }
    var canCalculateRoute: Bool { session.canCalculateRoute }

    func connect() async {
        // Snapshot the GUI selection *before* connecting, then commit it as the
        // session's bound UDID only if the connect succeeds. dispatch() matches
        // AI commands against this stable value, never the live selection.
        let udid = selectedDeviceUDID
        await session.connect()
        connectedUDID = session.connectionStatus.isConnected ? udid : nil
    }
    func disconnect() async {
        await session.disconnect()
        connectedUDID = nil
    }
    func teleport(to coordinate: CLLocationCoordinate2D) { session.teleport(to: coordinate) }
    func clearLocation() async { await session.clearLocation() }
    func selectFrom(_ completion: MKLocalSearchCompletion) async { await session.selectFrom(completion) }
    func useCurrentLocationAsFrom() { session.useCurrentLocationAsFrom() }
    func selectTo(_ completion: MKLocalSearchCompletion) async { await session.selectTo(completion) }
    func addStop() { session.addStop() }
    func removeStop(id: UUID) { session.removeStop(id: id) }
    func selectStop(id: UUID, completion: MKLocalSearchCompletion) async { await session.selectStop(id: id, completion: completion) }
    func moveStop(fromOffsets: IndexSet, toOffset: Int) { session.moveStop(fromOffsets: fromOffsets, toOffset: toOffset) }
    func calculateRoute() async { await session.calculateRoute() }
    func travelDirectly(to dest: CLLocationCoordinate2D) { session.travelDirectly(to: dest) }
    func appendDirectly(to dest: CLLocationCoordinate2D) async { await session.appendDirectly(to: dest) }
    func appendRoute(to dest: CLLocationCoordinate2D) async { await session.appendRoute(to: dest) }
    func routeFromCurrent(to dest: CLLocationCoordinate2D) async { await session.routeFromCurrent(to: dest) }
    func wanderNearby(center: CLLocationCoordinate2D, radius: Double, duration: TimeInterval) async {
        await session.wanderNearby(center: center, radius: radius, duration: duration)
    }
    func loadDrawnRoute(_ coords: [CLLocationCoordinate2D]) async { await session.loadDrawnRoute(coords) }
    func startPlayback() { session.startPlayback() }
    func pausePlayback() { session.pausePlayback() }
    func resumePlayback() { session.resumePlayback() }
    func stopPlayback() { session.stopPlayback() }
    func beginPlaybackScrub() { session.beginPlaybackScrub() }
    func scrubPlayback(toProgress progress: Double) { session.scrubPlayback(toProgress: progress) }
    func seekPlayback(toProgress progress: Double) { session.seekPlayback(toProgress: progress) }
    func endPlaybackScrub() { session.endPlaybackScrub() }
    func rejoinRoute() { session.rejoinRoute() }
    func updateStickInput(x: Float, y: Float) { session.updateStickInput(x: x, y: y) }
    func pressDirection(_ direction: JoystickEngine.Direction) { session.pressDirection(direction) }
    func releaseDirection(_ direction: JoystickEngine.Direction) { session.releaseDirection(direction) }
    func importGPX() { session.importGPX() }
    func exportGPX() { session.exportGPX() }
    func toggleRecording() { session.toggleRecording() }
    func replayRecording(_ recording: RecorderService.Session) { session.replayRecording(recording) }

    // MARK: - AI command dispatch (epic 019)

    // The single entry point the AI command server calls for every command. It
    // is the *same* facade the GUI uses — it forwards to the session/AppState
    // methods the buttons call, so every coordinate still passes the
    // SimulationActor.emit() chokepoint (noise + recording). It never reads
    // selectedDeviceUDID: device-scoped commands resolve their target by the
    // UDID they carry, matched against the connected session.
    //
    // Returns a CommandResponse rather than throwing — a bad UDID or a
    // not-connected device is an expected, machine-readable outcome the agent
    // must be able to branch on, not an exception that drops the connection.
    func dispatch(_ command: Command) async -> CommandResponse {
        switch command {
        case .devices:
            return CommandResponse.success(devicesDocument())
        case .status:
            return CommandResponse.success(statusDocument())

        case .teleport(let udid, let lat, let lon):
            return resolvingConnected(udid) {
                let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                self.session.teleport(to: coord)
                return CommandResponse.success()
            }

        case .route(let udid, let coordinates):
            return await resolvingConnectedAsync(udid) {
                guard coordinates.count >= 2 else {
                    return CommandResponse.failure(code: "bad_route", message: "route needs at least two coordinates")
                }
                let coords = coordinates.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
                // loadDrawnRoute is the existing "load these coords, no autoplay"
                // path; PLAY is a separate command. It already logs and pushes
                // through the same loadRoute the GUI uses.
                await self.session.loadDrawnRoute(coords)
                return CommandResponse.success()
            }

        case .play(let udid):
            return resolvingConnected(udid) {
                guard !self.session.routeCoordinates.isEmpty else {
                    return CommandResponse.failure(code: "no_route", message: "no route loaded to play")
                }
                self.session.startPlayback()
                return CommandResponse.success()
            }

        case .pause(let udid):
            return resolvingConnected(udid) {
                self.session.pausePlayback()
                return CommandResponse.success()
            }

        case .stop(let udid):
            return resolvingConnected(udid) {
                self.session.stopPlayback()
                return CommandResponse.success()
            }

        case .seek(let udid, let progress):
            return resolvingConnected(udid) {
                let clamped = min(max(progress, 0), 1)
                self.session.seekPlayback(toProgress: clamped)
                return CommandResponse.success()
            }

        case .clear(let udid):
            return await resolvingConnectedAsync(udid) {
                await self.session.clearLocation()
                return CommandResponse.success()
            }
        }
    }

    // Resolves the target for a device-scoped command and runs `body` only if
    // the UDID names the connected session. Distinguishes "unknown device" from
    // "known but not connected" so the agent gets an actionable error — and so
    // a command for device A can never fall through onto device B.
    private func resolvingConnected(_ udid: String, _ body: () -> CommandResponse) -> CommandResponse {
        switch resolveTarget(udid) {
        case .connected:
            return body()
        case .notConnected:
            return CommandResponse.failure(code: "not_connected", message: "device \(udid) is not connected")
        case .unknown:
            return CommandResponse.failure(code: "unknown_device", message: "no device with UDID \(udid)")
        }
    }

    private func resolvingConnectedAsync(_ udid: String, _ body: () async -> CommandResponse) async -> CommandResponse {
        switch resolveTarget(udid) {
        case .connected:
            return await body()
        case .notConnected:
            return CommandResponse.failure(code: "not_connected", message: "device \(udid) is not connected")
        case .unknown:
            return CommandResponse.failure(code: "unknown_device", message: "no device with UDID \(udid)")
        }
    }

    private enum DispatchTarget {
        case connected      // the live session is bound to this UDID and connected
        case notConnected   // a known device, but not the connected session
        case unknown        // no device with this UDID anywhere we can see
    }

    // Liveness comes from session.connectionStatus, not connectedUDID alone:
    // an unexpected drop (daemon death, tunnel down, sleep) flips the status
    // without routing through the disconnect() forwarder, so connectedUDID can
    // briefly lag. The status read is the authoritative gate.
    private func resolveTarget(_ udid: String) -> DispatchTarget {
        if connectedUDID == udid, session.connectionStatus.isConnected {
            return .connected
        }
        let known = discovery.devices.contains { $0.udid == udid }
            || connectedUDID == udid
            || selectedKnownUDIDs.contains(udid)
        return known ? .notConnected : .unknown
    }

    // UDIDs we've ever bound to count as "known" even if discovery hasn't
    // re-scanned — otherwise a command issued right after a drop would read as
    // unknown rather than not-connected.
    private var selectedKnownUDIDs: Set<String> {
        Set([connectedUDID].compactMap { $0 })
    }

    // One all-devices document with explicit per-device connection state, so a
    // "running-but-not-connected" condition is unambiguous and machine-readable
    // (epic 019). Built from discovery plus the connected session; the session's
    // simulation read-state comes from its MainActor simState bridge.
    private func statusDocument() -> JSONValue {
        var entries: [JSONValue] = []
        var seen = Set<String>()

        for device in discovery.devices {
            seen.insert(device.udid)
            entries.append(deviceStatusEntry(udid: device.udid, name: device.name))
        }
        // The connected device may not be in the last discovery snapshot;
        // surface it regardless so its live state is never hidden.
        if let udid = connectedUDID, !seen.contains(udid) {
            entries.append(deviceStatusEntry(udid: udid, name: nil))
        }

        return .object([
            "protocol": .int(AIProtocol.version),
            "devices": .array(entries)
        ])
    }

    private func deviceStatusEntry(udid: String, name: String?) -> JSONValue {
        let isConnected = connectedUDID == udid && session.connectionStatus.isConnected
        var fields: [String: JSONValue] = [
            "udid": .string(udid),
            "connected": .bool(isConnected)
        ]
        if let name {
            fields["name"] = .string(name)
        }
        if isConnected {
            let s = session.simState
            fields["playback"] = .string(playbackStateString(s.navigationPlaybackState))
            fields["progress"] = .double(s.navigationProgress)
            fields["recording"] = .bool(s.isRecording)
            fields["hasRoute"] = .bool(!session.routeCoordinates.isEmpty)
            if let coord = s.simulatedCoordinate {
                fields["latitude"] = .double(coord.latitude)
                fields["longitude"] = .double(coord.longitude)
            }
        }
        return .object(fields)
    }

    private func devicesDocument() -> JSONValue {
        let entries: [JSONValue] = discovery.devices.map { device in
            .object([
                "udid": .string(device.udid),
                "name": .string(device.name),
                "connection": .string(device.connectionType.rawValue),
                "connected": .bool(connectedUDID == device.udid && session.connectionStatus.isConnected)
            ])
        }
        return .object([
            "devices": .array(entries)
        ])
    }

    private func playbackStateString(_ state: NavigationEngine.PlaybackState) -> String {
        switch state {
        case .idle: return "idle"
        case .playing: return "playing"
        case .paused: return "paused"
        }
    }

    // MARK: - Saved Locations (app-global library; reaches into the active session)

    func saveCurrentLocation(name: String) {
        guard let coord = session.simState.simulatedCoordinate else { return }
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
        session.teleport(to: waypoint.coordinate)
    }

    // MARK: - Recording library

    func exportRecording(_ recording: RecorderService.Session) {
        guard let src = recording.fileURL else { return }
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

    func deleteRecording(_ recording: RecorderService.Session) {
        recorder.delete(recording)
    }

    // MARK: - Saved Routes (app-global library; reaches into the active session)

    func saveCurrentRoute(name: String, source: String = "calculated", sourceDetail: String? = nil) {
        guard !session.routeCoordinates.isEmpty else {
            addLog("No route to save.")
            return
        }
        // Capture the planner inputs only when this route came from the planner;
        // direct/recorded/imported sources have no editable inputs to round-trip.
        let plannerFrom: SavedRoute.NamedCoord? = source == "calculated"
            ? session.fromCoordinate.map { SavedRoute.NamedCoord(lat: $0.latitude, lon: $0.longitude, label: session.fromSearch.query) }
            : nil
        let plannerTo: SavedRoute.NamedCoord? = source == "calculated"
            ? session.toCoordinate.map { SavedRoute.NamedCoord(lat: $0.latitude, lon: $0.longitude, label: session.toSearch.query) }
            : nil
        let plannerStops: [SavedRoute.NamedCoord]? = source == "calculated"
            ? session.stops.compactMap { stop in
                stop.coordinate.map { SavedRoute.NamedCoord(lat: $0.latitude, lon: $0.longitude, label: stop.search.query) }
            }
            : nil
        let route = SavedRoute(
            id: UUID(),
            name: name,
            createdAt: Date(),
            transportModeRaw: transportMode.rawValue,
            customSpeedKmh: transportMode == .custom ? customSpeedKmh : nil,
            coordinates: session.routeCoordinates.map { .init(lat: $0.latitude, lon: $0.longitude) },
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
            session.fromCoordinate = CLLocationCoordinate2D(latitude: f.lat, longitude: f.lon)
            session.fromSearch.setQuery(f.label ?? "")
        } else {
            session.fromCoordinate = nil
            session.fromSearch.setQuery("")
        }
        if let t = route.toWaypoint {
            session.toCoordinate = CLLocationCoordinate2D(latitude: t.lat, longitude: t.lon)
            session.toSearch.setQuery(t.label ?? "")
        } else {
            session.toCoordinate = nil
            session.toSearch.setQuery("")
        }
        session.stops = (route.stopWaypoints ?? []).map { saved in
            let s = RouteStop()
            s.coordinate = CLLocationCoordinate2D(latitude: saved.lat, longitude: saved.lon)
            s.search.setQuery(saved.label ?? "")
            return s
        }

        session.routeCoordinates = coords
        let speed = effectiveBaseSpeedMPS
        let mult = speedMultiplier
        let shouldPlay = autoPlay && session.connectionStatus.isConnected
        addLog("Loaded route: \(route.name)")
        Task {
            await session.sim.loadRoute(coordinates: coords, baseSpeed: speed, resetStart: true)
            if shouldPlay {
                await session.sim.play(multiplier: mult)
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

    func saveRecordingAsRoute(_ recording: RecorderService.Session, name: String) {
        let coords = recording.points.map { SavedRoute.Coord(lat: $0.latitude, lon: $0.longitude) }
        let route = SavedRoute(
            id: UUID(),
            name: name,
            createdAt: Date(),
            transportModeRaw: transportMode.rawValue,
            customSpeedKmh: transportMode == .custom ? customSpeedKmh : nil,
            coordinates: coords,
            source: "recorded",
            sourceDetail: recording.id.uuidString,
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

    // MARK: - Daemon orphan sweep

    // First connect per session sweeps any orphan tm_daemon.py left over from
    // a prior host-app crash (parent watcher catches most, but isn't instant).
    func sweepStaleDaemonsIfNeeded() {
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

    // MARK: - Private

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

    var transportLabel: String {
        if transportMode == .custom {
            return String(format: "Custom %.0f km/h", customSpeedKmh)
        }
        return transportMode.rawValue
    }

    func addLog(_ message: String) {
        let ts = Date().formatted(date: .omitted, time: .standard)
        logMessages.append("[\(ts)] \(message)")
    }
}
