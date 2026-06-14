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
    let defaults: UserDefaults

    // The device sessions — one per connectable slot. Always ≥ 1: launch creates
    // a single unbound session (it holds the restored red dot + pre-connect route
    // planning, like the old eager `session`), and removeSession() never empties
    // the collection. Command routing keys on each session's connectedUDID, never
    // on a position in this array.
    private(set) var sessions: [DeviceSession] = []

    // The session the control surface (route panel, playback, joystick, map
    // planning markers) targets and the map highlights. A stable session id, not
    // a UDID — an unbound slot has no UDID yet. Changing it re-homes the single
    // physical joystick to the newly selected device (syncActiveJoystick).
    // Placeholder default so `self` is fully initialized before init() builds the
    // first session (whose id then overwrites this); never observed before then.
    var selectedSessionID: DeviceSession.ID = UUID() {
        didSet {
            guard selectedSessionID != oldValue else { return }
            syncActiveJoystick()
        }
    }

    // The resolved selected session. Falls back to the first session, which
    // always exists, so it is never nil.
    var selectedSession: DeviceSession {
        sessions.first { $0.id == selectedSessionID } ?? sessions[0]
    }

    // AI command server. Implicitly-unwrapped because it back-references self.
    // Holds the AF_UNIX listener; only running while aiControlEnabled is on.
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
            for s in sessions {
                Task { await s.sim.updateNoiseSigma(sigma) }
            }
        }
    }

    // Launch behavior (epic 005). The position is always saved; this only
    // gates whether the next launch restores it or starts empty.
    var restoreLastSimulatedLocation: Bool {
        didSet { SimulatedPositionPersistence.setRestoreOnLaunch(restoreLastSimulatedLocation, in: defaults) }
    }

    // AI control (epic 019). Off by default — gates the Unix-socket command
    // server entirely, so there's no attack surface until the user opts in.
    // Persisted so the choice survives relaunch; the didSet starts/stops the
    // server live when toggled in Settings.
    var aiControlEnabled: Bool {
        didSet {
            guard aiControlEnabled != oldValue else { return }
            defaults.set(aiControlEnabled, forKey: "aiControlEnabled")
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
    // App-global tunnel broker (epic 012): one privileged `tunneld` for all
    // devices, one auth prompt per session. Sessions resolve their RSD endpoint
    // through it on connect; torn down only at app quit.
    let tunnelBroker = TunnelBroker()
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.restoreLastSimulatedLocation = SimulatedPositionPersistence.restoreOnLaunch(in: defaults)
        self.aiControlEnabled = defaults.bool(forKey: "aiControlEnabled")

        // Build the first (unbound) session before anything reads selectedSession
        // or the tuning didSets fan out. selectedSessionID isn't Optional, so it
        // must be seeded here from the session we just made.
        let first = DeviceSession(manager: self)
        self.sessions = [first]
        self.selectedSessionID = first.id
        self.commandServer = CommandServer(appState: self)

        let storedCustom = defaults.double(forKey: "customSpeedKmh")
        self.customSpeedKmh = storedCustom > 0 ? storedCustom : 15.0

        if defaults.object(forKey: "noiseSigmaMeters") != nil {
            self.noiseSigmaMeters = defaults.double(forKey: "noiseSigmaMeters")
        }

        if let raw = defaults.string(forKey: "transportMode"),
           let mode = TransportMode(rawValue: raw) {
            self.transportMode = mode
        }
        // didSets don't fire for in-init assignments, so seed the engine
        // explicitly (base speed is also re-pushed on connect).
        let initialSigma = noiseSigmaMeters
        Task { await first.sim.updateNoiseSigma(initialSigma) }

        // System sleep tears down the DVT session unconditionally (Apple's
        // design — see v2-features.md). Drop every connection cleanly so the
        // UI doesn't claim any device is still connected after wake.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for s in self.sessions {
                    await s.handleSystemSleep()
                }
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
            let restored = SimulatedPositionPersistence.load(from: defaults)
                ?? SimulatedPositionPersistence.defaultCoordinate
            Task { await first.sim.teleport(to: restored) }
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
        defaults.set(customSpeedKmh, forKey: "customSpeedKmh")
        defaults.set(noiseSigmaMeters, forKey: "noiseSigmaMeters")
        defaults.set(transportMode.rawValue, forKey: "transportMode")
    }

    func persistSelectedSimulatedPositionNow() {
        selectedSession.simState.persistPositionNow()
    }

    // App-global tuning fans out to every session's engine — the $-bound controls
    // are shared, so a change applies to all connected devices, not just the
    // selected one.
    private func syncEngineSpeeds() async {
        let speed = effectiveBaseSpeedMPS
        for s in sessions {
            await s.sim.updateBaseSpeed(speed)
        }
    }

    private func pushLoopConfig() {
        let mode = loopMode
        let count = loopCount
        for s in sessions {
            Task { await s.sim.updateLoop(mode: mode, count: count) }
        }
    }

    // MARK: - Session collection management

    // Colors map the markers/routes/swatches of each session on the shared map
    // and in the switcher. Indexed by the session's position; wraps past the
    // palette (the practical ceiling is a few devices, well within it).
    static let sessionPalette: [Color] = [.red, .blue, .green, .orange, .purple, .teal, .pink, .indigo]

    func color(for session: DeviceSession) -> Color {
        guard let idx = sessions.firstIndex(where: { $0.id == session.id }) else { return .red }
        return Self.sessionPalette[idx % Self.sessionPalette.count]
    }

    // Append a fresh unbound slot and select it, so the sidebar shows its device
    // picker.
    func addSession() {
        let s = DeviceSession(manager: self)
        sessions.append(s)
        seedTuning(into: s)
        selectedSessionID = s.id
    }

    // Seed a freshly created session's engine with the current app-global tuning,
    // so it behaves identically to the existing sessions before its first connect.
    // (Base speed is also re-pushed on connect; noise σ and loop have no
    // connect-time hook, so without this a session added after the user changed
    // them would diverge.)
    private func seedTuning(into s: DeviceSession) {
        let sigma = noiseSigmaMeters
        let speed = effectiveBaseSpeedMPS
        let mode = loopMode
        let count = loopCount
        Task {
            await s.sim.updateNoiseSigma(sigma)
            await s.sim.updateBaseSpeed(speed)
            await s.sim.updateLoop(mode: mode, count: count)
        }
    }

    // Remove a slot (disconnecting it first). The collection never empties: if
    // this was the last session, leave a fresh unbound one in its place. If the
    // removed session was selected, fall back to the first remaining session.
    func removeSession(_ session: DeviceSession) {
        Task { await session.disconnect() }
        sessions.removeAll { $0.id == session.id }
        if sessions.isEmpty {
            sessions = [DeviceSession(manager: self)]
        }
        if !sessions.contains(where: { $0.id == selectedSessionID }) {
            selectedSessionID = sessions[0].id
        }
        syncActiveJoystick()
    }

    // Keep exactly the selected, connected session's joystick armed, so the one
    // physical controller / WASD / virtual stick drives one device. Called on
    // selection change and after every connect/disconnect. A disarmed engine
    // still reads the controller in its tick but contributes no velocity, so
    // non-selected devices never move from joystick input.
    func syncActiveJoystick() {
        for s in sessions {
            s.setJoystickArmed(s.id == selectedSessionID && s.connectionStatus.isConnected)
        }
    }

    // MARK: - Per-device forwards (UI reads/calls AppState; we resolve the selected session)

    var simState: SimulationStateBridge { selectedSession.simState }
    var connectionStatus: ConnectionStatus { selectedSession.connectionStatus }
    var isCalculatingRoute: Bool { selectedSession.isCalculatingRoute }
    var routeCoordinates: [CLLocationCoordinate2D] {
        get { selectedSession.routeCoordinates }
        set { selectedSession.routeCoordinates = newValue }
    }
    var fromSearch: LocationSearch { selectedSession.fromSearch }
    var toSearch: LocationSearch { selectedSession.toSearch }
    var fromCoordinate: CLLocationCoordinate2D? {
        get { selectedSession.fromCoordinate }
        set { selectedSession.fromCoordinate = newValue }
    }
    var toCoordinate: CLLocationCoordinate2D? {
        get { selectedSession.toCoordinate }
        set { selectedSession.toCoordinate = newValue }
    }
    var stops: [RouteStop] {
        get { selectedSession.stops }
        set { selectedSession.stops = newValue }
    }
    var canCalculateRoute: Bool { selectedSession.canCalculateRoute }

    func connect() async {
        await selectedSession.connect()
        syncActiveJoystick()
    }
    func disconnect() async {
        await selectedSession.disconnect()
        syncActiveJoystick()
    }

    // Quit cleanup: stop the AI command socket (unlinks ai.sock) before the
    // device disconnects, so a leftover socket node isn't left behind at quit.
    // stop() is idempotent, so this is safe whether or not AI control was on.
    // Every connected session is disconnected (sleep/quit tears down all DVT
    // sessions), then the shared broker is torn down last — the daemons'
    // QUIT/CLEAR need the tunnel still alive.
    func prepareForQuit() async {
        commandServer.stop()
        for s in sessions {
            await s.disconnect()
        }
        tunnelBroker.stop()
    }
    func teleport(to coordinate: CLLocationCoordinate2D) { selectedSession.teleport(to: coordinate) }
    func clearLocation() async { await selectedSession.clearLocation() }
    func selectFrom(_ completion: MKLocalSearchCompletion) async { await selectedSession.selectFrom(completion) }
    func useCurrentLocationAsFrom() { selectedSession.useCurrentLocationAsFrom() }
    func selectTo(_ completion: MKLocalSearchCompletion) async { await selectedSession.selectTo(completion) }
    func addStop() { selectedSession.addStop() }
    func removeStop(id: UUID) { selectedSession.removeStop(id: id) }
    func selectStop(id: UUID, completion: MKLocalSearchCompletion) async { await selectedSession.selectStop(id: id, completion: completion) }
    func moveStop(fromOffsets: IndexSet, toOffset: Int) { selectedSession.moveStop(fromOffsets: fromOffsets, toOffset: toOffset) }
    func calculateRoute() async { await selectedSession.calculateRoute() }
    func travelDirectly(to dest: CLLocationCoordinate2D) { selectedSession.travelDirectly(to: dest) }
    func appendDirectly(to dest: CLLocationCoordinate2D) async { await selectedSession.appendDirectly(to: dest) }
    func appendRoute(to dest: CLLocationCoordinate2D) async { await selectedSession.appendRoute(to: dest) }
    func routeFromCurrent(to dest: CLLocationCoordinate2D) async { await selectedSession.routeFromCurrent(to: dest) }
    func wanderNearby(center: CLLocationCoordinate2D, radius: Double, duration: TimeInterval) async {
        await selectedSession.wanderNearby(center: center, radius: radius, duration: duration)
    }
    func loadDrawnRoute(_ coords: [CLLocationCoordinate2D]) async { await selectedSession.loadDrawnRoute(coords) }
    func startPlayback() { selectedSession.startPlayback() }
    func pausePlayback() { selectedSession.pausePlayback() }
    func resumePlayback() { selectedSession.resumePlayback() }
    func stopPlayback() { selectedSession.stopPlayback() }
    func beginPlaybackScrub() { selectedSession.beginPlaybackScrub() }
    func scrubPlayback(toProgress progress: Double) { selectedSession.scrubPlayback(toProgress: progress) }
    func seekPlayback(toProgress progress: Double) { selectedSession.seekPlayback(toProgress: progress) }
    func endPlaybackScrub() { selectedSession.endPlaybackScrub() }
    func rejoinRoute() { selectedSession.rejoinRoute() }
    func updateStickInput(x: Float, y: Float) { selectedSession.updateStickInput(x: x, y: y) }
    func pressDirection(_ direction: JoystickEngine.Direction) { selectedSession.pressDirection(direction) }
    func releaseDirection(_ direction: JoystickEngine.Direction) { selectedSession.releaseDirection(direction) }
    func importGPX() { selectedSession.importGPX() }
    func exportGPX() { selectedSession.exportGPX() }
    func toggleRecording() { selectedSession.toggleRecording() }
    func replayRecording(_ recording: RecorderService.Session) { selectedSession.replayRecording(recording) }

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
        // Ensure discovery has run so DEVICES isn't empty and the unknown-vs-not-
        // connected labeling is accurate even in windowless mode, where the GUI
        // device picker may never have triggered a scan. DEVICES forces a fresh
        // scan (hot-plug); other verbs only need a one-time populate.
        if case .devices = command {
            await discovery.scan()
        } else if !discovery.hasScanned {
            await discovery.scan()
        }
        switch command {
        case .devices:
            return CommandResponse.success(devicesDocument())
        case .status:
            return CommandResponse.success(statusDocument())

        case .teleport(let udid, let lat, let lon):
            return resolvingConnected(udid) { session in
                let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                session.teleport(to: coord)
                return CommandResponse.success()
            }

        case .route(let udid, let coordinates):
            return await resolvingConnectedAsync(udid) { session in
                guard coordinates.count >= 2 else {
                    return CommandResponse.failure(code: "bad_route", message: "route needs at least two coordinates")
                }
                let coords = coordinates.map {
                    CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
                }
                // loadDrawnRoute is the existing "load these coords, no autoplay"
                // path; PLAY is a separate command. It already logs and pushes
                // through the same loadRoute the GUI uses.
                await session.loadDrawnRoute(coords)
                return CommandResponse.success()
            }

        case .play(let udid):
            return resolvingConnected(udid) { session in
                guard !session.routeCoordinates.isEmpty else {
                    return CommandResponse.failure(code: "no_route", message: "no route loaded to play")
                }
                session.startPlayback()
                return CommandResponse.success()
            }

        case .pause(let udid):
            return resolvingConnected(udid) { session in
                session.pausePlayback()
                return CommandResponse.success()
            }

        case .stop(let udid):
            return resolvingConnected(udid) { session in
                session.stopPlayback()
                return CommandResponse.success()
            }

        case .seek(let udid, let progress):
            return resolvingConnected(udid) { session in
                let clamped = min(max(progress, 0), 1)
                session.seekPlayback(toProgress: clamped)
                return CommandResponse.success()
            }

        case .clear(let udid):
            return await resolvingConnectedAsync(udid) { session in
                await session.clearLocation()
                return CommandResponse.success()
            }

        case .connect(let udid):
            guard discovery.devices.contains(where: { $0.udid == udid }) else {
                return CommandResponse.failure(code: "unknown_device",
                    message: "no discovered device with UDID \(udid) (try DEVICES)")
            }
            if connectedSession(udid) != nil {
                return CommandResponse.success(.object(["state": .string("connected"), "udid": .string(udid)]))
            }
            // Connecting triggers the admin (sudo) prompt + tunnel + daemon —
            // human-gated and slower than the socket's dispatch timeout — so kick
            // it off and acknowledge immediately; the agent polls STATUS for the
            // realized state (this device's entry: state connecting → connected/
            // error). Find-or-make a slot for the device; never touch the GUI's
            // selected session (AI is a command source, not a focus owner).
            let target = sessionForConnecting(udid: udid)
            target.selectedDeviceUDID = udid
            Task { await connectSession(target) }
            return CommandResponse.success(.object(["state": .string("connecting"), "udid": .string(udid)]))

        case .disconnect(let udid):
            guard let session = connectedSession(udid) else {
                return CommandResponse.failure(code: "not_connected",
                    message: "device \(udid) is not connected")
            }
            await session.disconnect()
            syncActiveJoystick()
            return CommandResponse.success(.object(["state": .string("disconnected"), "udid": .string(udid)]))
        }
    }

    // The connected session bound to this UDID, or nil. This is the structural
    // routing key: a UDID-scoped command reaches exactly the session that owns
    // the UDID, and each session forwards only to its own private DaemonBridge —
    // so a command for device A can never move device B. Liveness comes from the
    // status, not connectedUDID alone (an unexpected drop flips the status before
    // the disconnect() forwarder nils connectedUDID).
    private func connectedSession(_ udid: String) -> DeviceSession? {
        sessions.first { $0.connectedUDID == udid && $0.connectionStatus.isConnected }
    }

    // Resolves the target for a device-scoped command and runs `body` with that
    // session only if the UDID names a connected session. Distinguishes "unknown
    // device" from "known but not connected" so the agent gets an actionable
    // error — and so a command for device A can never fall through onto device B.
    private func resolvingConnected(_ udid: String, _ body: (DeviceSession) -> CommandResponse) -> CommandResponse {
        if let session = connectedSession(udid) {
            return body(session)
        }
        return notConnectedOrUnknown(udid)
    }

    private func resolvingConnectedAsync(_ udid: String, _ body: (DeviceSession) async -> CommandResponse) async -> CommandResponse {
        if let session = connectedSession(udid) {
            return await body(session)
        }
        return notConnectedOrUnknown(udid)
    }

    private func notConnectedOrUnknown(_ udid: String) -> CommandResponse {
        let known = discovery.devices.contains { $0.udid == udid }
            || sessions.contains { $0.connectedUDID == udid || $0.selectedDeviceUDID == udid }
        return known
            ? CommandResponse.failure(code: "not_connected", message: "device \(udid) is not connected")
            : CommandResponse.failure(code: "unknown_device", message: "no device with UDID \(udid)")
    }

    // Find a slot to connect this UDID through: reuse one already targeting or
    // bound to it, else a spare idle/unbound slot, else append a fresh one.
    // Never changes selectedSessionID — AI connect must not steal GUI focus.
    private func sessionForConnecting(udid: String) -> DeviceSession {
        if let s = sessions.first(where: { $0.selectedDeviceUDID == udid || $0.connectedUDID == udid }) {
            return s
        }
        if let spare = sessions.first(where: { !$0.connectionStatus.isConnected && $0.selectedDeviceUDID == nil }) {
            return spare
        }
        let s = DeviceSession(manager: self)
        sessions.append(s)
        seedTuning(into: s)
        return s
    }

    private func connectSession(_ session: DeviceSession) async {
        await session.connect()
        syncActiveJoystick()
    }

    // One all-devices document with explicit per-device connection state, so a
    // "running-but-not-connected" condition is unambiguous and machine-readable
    // (epic 019). Built from discovery plus every connected session; each
    // device's simulation read-state comes from its session's MainActor bridge.
    private func statusDocument() -> JSONValue {
        var entries: [JSONValue] = []
        var seen = Set<String>()

        for device in discovery.devices {
            seen.insert(device.udid)
            entries.append(deviceStatusEntry(udid: device.udid, name: device.name))
        }
        // A connected device may be absent from the last discovery snapshot;
        // surface every session's device regardless so live state is never hidden.
        for s in sessions {
            if let udid = s.connectedUDID, !seen.contains(udid) {
                seen.insert(udid)
                entries.append(deviceStatusEntry(udid: udid, name: s.deviceName))
            }
        }

        return .object([
            "protocol": .int(AIProtocol.version),
            "connection": connectionStateObject(),
            "devices": .array(entries)
        ])
    }

    // The selected session's connection lifecycle (back-compat top-level view).
    // Per-device lifecycle lives in each device entry's `state`, so an agent that
    // CONNECTed a non-selected device polls that device's entry, not this.
    private func connectionStateObject() -> JSONValue {
        let session = selectedSession
        var fields: [String: JSONValue] = ["state": .string(connectionStateString(session.connectionStatus))]
        if let udid = session.connectedUDID ?? session.selectedDeviceUDID { fields["udid"] = .string(udid) }
        if case .error(let message) = session.connectionStatus { fields["error"] = .string(message) }
        return .object(fields)
    }

    private func connectionStateString(_ status: ConnectionStatus) -> String {
        switch status {
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .error: return "error"
        }
    }

    private func deviceStatusEntry(udid: String, name: String?) -> JSONValue {
        // The slot handling this device: the one connected to it, else one
        // targeting it (e.g. mid-connect). Lets the entry report a per-device
        // connection lifecycle the agent can poll after CONNECT <udid>.
        let slot = sessions.first { $0.connectedUDID == udid }
            ?? sessions.first { $0.selectedDeviceUDID == udid }
        let isConnected = slot?.connectedUDID == udid && (slot?.connectionStatus.isConnected ?? false)

        var fields: [String: JSONValue] = [
            "udid": .string(udid),
            "connected": .bool(isConnected)
        ]
        if let name {
            fields["name"] = .string(name)
        } else if let n = slot?.deviceName {
            fields["name"] = .string(n)
        }
        if let slot {
            fields["state"] = .string(connectionStateString(slot.connectionStatus))
            if case .error(let message) = slot.connectionStatus { fields["error"] = .string(message) }
        }
        if isConnected, let slot {
            let s = slot.simState
            fields["playback"] = .string(playbackStateString(s.navigationPlaybackState))
            fields["progress"] = .double(s.navigationProgress)
            fields["recording"] = .bool(s.isRecording)
            fields["hasRoute"] = .bool(!slot.routeCoordinates.isEmpty)
            if let coord = s.simulatedCoordinate {
                fields["latitude"] = .double(coord.latitude)
                fields["longitude"] = .double(coord.longitude)
            }
        }
        return .object(fields)
    }

    private func devicesDocument() -> JSONValue {
        var entries: [JSONValue] = []
        var seen = Set<String>()
        for device in discovery.devices {
            seen.insert(device.udid)
            entries.append(.object([
                "udid": .string(device.udid),
                "name": .string(device.name),
                "connection": .string(device.connectionType.rawValue),
                "connected": .bool(connectedSession(device.udid) != nil)
            ]))
        }
        // Surface any connected device absent from the discovery snapshot,
        // mirroring statusDocument so DEVICES never hides it.
        for s in sessions {
            if let udid = s.connectedUDID, !seen.contains(udid) {
                seen.insert(udid)
                var fields: [String: JSONValue] = [
                    "udid": .string(udid),
                    "connected": .bool(s.connectionStatus.isConnected)
                ]
                if let n = s.deviceName { fields["name"] = .string(n) }
                entries.append(.object(fields))
            }
        }
        return .object([
            "protocol": .int(AIProtocol.version),
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
        guard let coord = selectedSession.simState.simulatedCoordinate else { return }
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
        selectedSession.teleport(to: waypoint.coordinate)
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
        let session = selectedSession
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
        let session = selectedSession
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
        guard let data = defaults.data(forKey: "savedWaypoints"),
              let waypoints = try? JSONDecoder().decode([SavedWaypoint].self, from: data) else { return }
        savedWaypoints = waypoints
    }

    private func persistWaypoints() {
        guard let data = try? JSONEncoder().encode(savedWaypoints) else { return }
        defaults.set(data, forKey: "savedWaypoints")
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
