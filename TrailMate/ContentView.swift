import SwiftUI
import MapKit

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        NavigationSplitView {
            SidebarView()
        } detail: {
            MapArea()
        }
        .navigationTitle("TrailMate")
        .sheet(isPresented: $appState.showLogSheet) {
            LogSheet()
        }
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        List {
            Section("Connection") {
                if appState.connectionStatus.isConnected {
                    StatusRow()
                    Button("Disconnect") {
                        Task { await appState.disconnect() }
                    }
                } else {
                    DevicePickerArea()
                    ConnectionButton()
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("GPS noise σ")
                            .font(.caption)
                        Spacer()
                        Text(String(format: "%.1f m", appState.noiseSigmaMeters))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $appState.noiseSigmaMeters, in: 0...10, step: 0.5)
                        .onChange(of: appState.noiseSigmaMeters) { _, _ in
                            appState.persistTuning()
                        }
                }
            }

            if appState.connectionStatus.isConnected {
                Section("Mode") {
                    Picker("Control Mode", selection: $appState.controlMode) {
                        ForEach(ControlMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                switch appState.controlMode {
                case .route:
                    RouteSection()
                case .joystick:
                    JoystickSection()
                }
            }

            if !appState.savedWaypoints.isEmpty || appState.simState.simulatedCoordinate != nil {
                SavedLocationsSection()
            }

            if !appState.savedRoutes.routes.isEmpty {
                SavedRoutesSection()
            }

            if !appState.recorder.recordings.isEmpty {
                RecordingsSection()
            }

            Section("Log") {
                if appState.logMessages.isEmpty {
                    Text("No activity yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(appState.logMessages.suffix(20).enumerated()), id: \.offset) { _, msg in
                        Text(msg)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
                Button("View Full Log") {
                    appState.showLogSheet = true
                }
                .disabled(appState.logMessages.isEmpty)
            }
        }
        .navigationSplitViewColumnWidth(min: 280, ideal: 320)
    }
}

// MARK: - Route Controls

private struct RouteSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        Section("Route") {
            SearchField(
                label: "From",
                search: appState.fromSearch,
                onSelect: { completion in
                    Task { await appState.selectFrom(completion) }
                }
            )

            SearchField(
                label: "To",
                search: appState.toSearch,
                onSelect: { completion in
                    Task { await appState.selectTo(completion) }
                }
            )

            TransportSpeedPicker()

            Button {
                Task { await appState.calculateRoute() }
            } label: {
                HStack {
                    if appState.isCalculatingRoute {
                        ProgressView().controlSize(.small)
                    }
                    Text("Calculate Route")
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(appState.fromCoordinate == nil || appState.toCoordinate == nil || appState.isCalculatingRoute)

            Divider()

            HStack {
                Button("Import GPX") {
                    appState.importGPX()
                }
                if !appState.routeCoordinates.isEmpty {
                    Button("Export GPX") {
                        appState.exportGPX()
                    }
                }
            }
        }

        if !appState.routeCoordinates.isEmpty {
            Section("Playback") {
                SpeedPicker(speedMultiplier: $appState.speedMultiplier)
                PlaybackControls()
                PlaybackProgress()
                SaveCurrentRouteButton()
            }
        }
    }
}

private struct SaveCurrentRouteButton: View {
    @Environment(AppState.self) private var appState
    @State private var showSaveAlert = false
    @State private var name = ""

    var body: some View {
        Button("Save Route…") {
            name = ""
            showSaveAlert = true
        }
        .alert("Save Route", isPresented: $showSaveAlert) {
            TextField("Name", text: $name)
            Button("Save") {
                guard !name.isEmpty else { return }
                appState.saveCurrentRoute(name: name)
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct TransportSpeedPicker: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        VStack(alignment: .leading, spacing: 6) {
            Picker("Transport", selection: $appState.transportMode) {
                ForEach(TransportMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if appState.transportMode == .custom {
                HStack {
                    Text("km/h")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField(
                        "km/h",
                        value: $appState.customSpeedKmh,
                        format: .number.precision(.fractionLength(0...1))
                    )
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 80)
                    .onSubmit { appState.persistTuning() }
                    Stepper("", value: $appState.customSpeedKmh, in: 1...300, step: 1)
                        .labelsHidden()
                        .onChange(of: appState.customSpeedKmh) { _, _ in
                            appState.persistTuning()
                        }
                    Spacer()
                }
            }
        }
    }
}

private struct SearchField: View {
    let label: String
    let search: LocationSearch
    let onSelect: (MKLocalSearchCompletion) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(label, text: Binding(
                get: { search.query },
                set: { search.updateQuery($0) }
            ))
            .textFieldStyle(.roundedBorder)

            if !search.suggestions.isEmpty {
                ForEach(Array(search.suggestions.prefix(4).enumerated()), id: \.offset) { _, suggestion in
                    Button {
                        onSelect(suggestion)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(suggestion.title)
                                .font(.callout)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct SpeedPicker: View {
    @Binding var speedMultiplier: Double

    private let speeds: [(String, Double)] = [
        ("1×", 1), ("5×", 5), ("10×", 10), ("100×", 100)
    ]

    var body: some View {
        HStack {
            Text("Speed")
            Spacer()
            ForEach(speeds, id: \.1) { label, value in
                Button(label) { speedMultiplier = value }
                    .buttonStyle(.bordered)
                    .tint(speedMultiplier == value ? .accentColor : .secondary)
                    .controlSize(.small)
            }
        }
    }
}

private struct PlaybackControls: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack {
            switch appState.simState.navigationPlaybackState {
            case .idle:
                Button {
                    appState.startPlayback()
                } label: {
                    Label("Play", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!appState.connectionStatus.isConnected)
            case .playing:
                Button {
                    appState.pausePlayback()
                } label: {
                    Label("Pause", systemImage: "pause.fill")
                        .frame(maxWidth: .infinity)
                }
            case .paused:
                Button {
                    appState.resumePlayback()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
            }

            Button(role: .destructive) {
                appState.stopPlayback()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .disabled(appState.simState.navigationPlaybackState == .idle)
        }
    }
}

private struct PlaybackProgress: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let sim = appState.simState
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: sim.navigationProgress)
            HStack {
                Text(formatDistance(sim.navigationElapsedDistance))
                Spacer()
                Text(formatDistance(sim.navigationTotalDistance))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if appState.simState.routeDeviationMeters > 5 {
                HStack {
                    Label(String(format: "Off-route: %.0f m", appState.simState.routeDeviationMeters),
                          systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Rejoin") {
                        appState.rejoinRoute()
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func formatDistance(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.1f km", meters / 1000)
        }
        return String(format: "%.0f m", meters)
    }
}

// MARK: - Joystick Controls

private struct JoystickSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        Section("Joystick") {
            HStack {
                if let name = appState.simState.joystickControllerName {
                    Label(name, systemImage: "gamecontroller.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("No controller — use WASD or virtual stick", systemImage: "gamecontroller")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)

            TransportSpeedPicker()

            if appState.simState.joystickIsActive {
                Button("Recenter") {
                    appState.recenterJoystick()
                }

                Button("Stop", role: .destructive) {
                    Task { await appState.stopJoystick() }
                }
            } else {
                Button {
                    appState.startJoystick()
                } label: {
                    Text("Start Joystick")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!appState.connectionStatus.isConnected)

                if appState.simState.simulatedCoordinate == nil {
                    Text("Tip: Long-press the map to set a starting position first")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Saved Locations

private struct SavedLocationsSection: View {
    @Environment(AppState.self) private var appState
    @State private var showSaveAlert = false
    @State private var waypointName = ""

    var body: some View {
        Section("Saved Locations") {
            ForEach(appState.savedWaypoints) { waypoint in
                Button {
                    appState.teleportToWaypoint(waypoint)
                } label: {
                    VStack(alignment: .leading) {
                        Text(waypoint.name)
                            .font(.callout)
                        Text(String(format: "%.4f, %.4f", waypoint.latitude, waypoint.longitude))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Delete", role: .destructive) {
                        appState.deleteWaypoint(waypoint)
                    }
                }
            }

            if appState.simState.simulatedCoordinate != nil {
                Button("Save Current Location") {
                    waypointName = ""
                    showSaveAlert = true
                }
                .alert("Save Location", isPresented: $showSaveAlert) {
                    TextField("Name", text: $waypointName)
                    Button("Save") {
                        guard !waypointName.isEmpty else { return }
                        appState.saveCurrentLocation(name: waypointName)
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
    }
}

// MARK: - Saved Routes

private struct SavedRoutesSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Section("Saved Routes") {
            ForEach(appState.savedRoutes.routes) { route in
                SavedRouteRow(route: route)
            }
        }
    }
}

private struct SavedRouteRow: View {
    let route: SavedRoute
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(route.name)
                .font(.callout)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.loadSavedRoute(route, autoPlay: false)
        }
        .contextMenu {
            Button("Load") { appState.loadSavedRoute(route, autoPlay: false) }
            Button("Replay") { appState.loadSavedRoute(route, autoPlay: true) }
            Button("Delete", role: .destructive) { appState.deleteSavedRoute(route) }
        }
    }

    private var detail: String {
        let dist = route.distanceMeters
        let distStr = dist >= 1000
            ? String(format: "%.2f km", dist / 1000)
            : String(format: "%.0f m", dist)
        return "\(route.transportMode.rawValue) · \(distStr) · \(route.coordinates.count) pts"
    }
}

// MARK: - Recordings

private struct RecordingsSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Section("Recordings") {
            ForEach(appState.recorder.recordings) { session in
                RecordingRow(session: session)
            }
        }
    }
}

private struct RecordingRow: View {
    let session: RecorderService.Session
    @Environment(AppState.self) private var appState
    @State private var showSaveRoutePrompt = false
    @State private var routeName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.callout)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            appState.replayRecording(session)
        }
        .contextMenu {
            Button("Replay") { appState.replayRecording(session) }
            Button("Save as Route…") {
                routeName = session.startedAt.formatted(date: .abbreviated, time: .shortened)
                showSaveRoutePrompt = true
            }
            Button("Export…") { appState.exportRecording(session) }
            Button("Delete", role: .destructive) { appState.deleteRecording(session) }
        }
        .alert("Save as Route", isPresented: $showSaveRoutePrompt) {
            TextField("Name", text: $routeName)
            Button("Save") {
                guard !routeName.isEmpty else { return }
                appState.saveRecordingAsRoute(session, name: routeName)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var detail: String {
        let dist = session.distanceMeters
        let distStr = dist >= 1000
            ? String(format: "%.2f km", dist / 1000)
            : String(format: "%.0f m", dist)
        let totalSec = Int(session.duration.rounded())
        let minutes = totalSec / 60
        let seconds = totalSec % 60
        return "\(session.points.count) pts · \(distStr) · \(minutes)m \(seconds)s"
    }
}

// MARK: - Log Sheet

private struct LogSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log")
                    .font(.headline)
                Spacer()
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(appState.logMessages.joined(separator: "\n"), forType: .string)
                }
                Button("Clear") {
                    appState.logMessages.removeAll()
                }
                Button("Close") {
                    dismiss()
                }
            }
            .padding()

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(appState.logMessages.enumerated()), id: \.offset) { _, msg in
                        Text(msg)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        }
        .frame(minWidth: 500, minHeight: 300)
    }
}

// MARK: - Sidebar Components

private struct DevicePickerArea: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        let discovery = appState.discovery

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Devices")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await discovery.scan() }
                } label: {
                    if discovery.isScanning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .help("Rescan")
            }

            if !discovery.devices.isEmpty {
                Picker("Device", selection: $appState.selectedDeviceUDID) {
                    Text("Select…").tag(String?.none)
                    ForEach(discovery.devices) { device in
                        Text(device.displayLabel).tag(Optional(device.udid))
                    }
                }
                .labelsHidden()
            } else if discovery.hasScanned && !discovery.isScanning {
                Text(discovery.lastError ?? "No devices found.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let udid = appState.selectedDeviceUDID,
               discovery.devices.first(where: { $0.udid == udid }) != nil {
                Text("Connect will request admin access to open the RSD tunnel.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if !discovery.hasScanned {
                Task { await discovery.scan() }
            }
        }
    }
}

private struct ConnectionButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let noDevice = (appState.selectedDeviceUDID ?? "").isEmpty
        let isConnecting = appState.connectionStatus == .connecting
        Button {
            Task { await appState.connect() }
        } label: {
            HStack {
                if isConnecting {
                    ProgressView().controlSize(.small)
                }
                Text(isConnecting ? "Connecting…" : "Connect")
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(isConnecting || noDevice)
    }
}

private struct StatusRow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack {
            Circle()
                .fill(appState.connectionStatus.isConnected ? Color.green : .gray)
                .frame(width: 10, height: 10)
            Text("Connected")
                .font(.callout)
        }
    }
}

// MARK: - Record button

private struct RecordButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let recording = appState.simState.isRecording
        Button {
            appState.toggleRecording()
        } label: {
            HStack(spacing: 6) {
                if recording {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.red)
                        .frame(width: 10, height: 10)
                } else {
                    Circle()
                        .fill(.red)
                        .frame(width: 12, height: 12)
                }
                Text(recording
                     ? "Stop · \(appState.simState.recordingPointCount) pts"
                     : "Record")
                    .font(.callout)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Destination action bar

private struct DestinationActionBar: View {
    enum Action { case teleport, direct, route, cancel }

    let coord: CLLocationCoordinate2D
    let onAction: (Action) -> Void

    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 8) {
            Text(String(format: "%.5f, %.5f", coord.latitude, coord.longitude))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Divider().frame(height: 14)

            Button {
                onAction(.teleport)
            } label: {
                Label("Teleport", systemImage: "bolt.fill")
            }
            .buttonStyle(.borderless)

            Button {
                onAction(.direct)
            } label: {
                Label("Go directly", systemImage: "arrow.up.right.circle")
            }
            .buttonStyle(.borderless)

            Button {
                onAction(.route)
            } label: {
                if appState.isCalculatingRoute {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.small)
                        Text("Routing…")
                    }
                } else {
                    Label("Route here", systemImage: "map.fill")
                }
            }
            .buttonStyle(.borderless)
            .disabled(appState.isCalculatingRoute)

            Button {
                onAction(.cancel)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

// MARK: - Map

private struct MapArea: View {
    @Environment(AppState.self) private var appState
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 25.033, longitude: 121.565),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )
    )
    @State private var pendingDestination: CLLocationCoordinate2D?

    var body: some View {
        MapReader { proxy in
            Map(position: $cameraPosition) {
                if !appState.routeCoordinates.isEmpty {
                    MapPolyline(coordinates: appState.routeCoordinates)
                        .stroke(.blue, lineWidth: 4)
                }

                if let from = appState.fromCoordinate, appState.controlMode == .route {
                    Marker("Start", systemImage: "flag.fill", coordinate: from)
                        .tint(.green)
                }

                if let to = appState.toCoordinate, appState.controlMode == .route {
                    Marker("End", systemImage: "mappin", coordinate: to)
                        .tint(.orange)
                }

                if let coord = appState.simState.simulatedCoordinate {
                    Annotation("", coordinate: coord) {
                        Circle()
                            .fill(.red)
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }

                if let dest = pendingDestination {
                    Marker("Destination", systemImage: "mappin.and.ellipse", coordinate: dest)
                        .tint(.purple)
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .mapControls {
                MapCompass()
                MapZoomStepper()
            }
            // Long-press, not tap: a plain tap would steal the Map's own pan/zoom
            // gestures, and the 0.5s threshold disambiguates intent from incidental clicks.
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                    .onEnded { value in
                        guard case .second(true, let drag) = value, let drag else { return }
                        guard appState.connectionStatus.isConnected else { return }
                        guard let coordinate = proxy.convert(drag.location, from: .local) else { return }

                        // First press: there's no origin yet, so a popover offering "Go directly"
                        // or "Route here" would have nothing to anchor from. Teleport instead.
                        if appState.simState.simulatedCoordinate == nil {
                            appState.teleport(to: coordinate)
                        } else {
                            pendingDestination = coordinate
                        }
                    }
            )
            .overlay(alignment: .bottomTrailing) {
                if appState.simState.joystickIsActive {
                    VirtualJoystickView { x, y in
                        appState.updateStickInput(x: x, y: y)
                    }
                    .padding(24)
                }
            }
            .focusable()
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, "w", "a", "s", "d"], phases: [.down, .up]) { press in
                guard appState.simState.joystickIsActive else {
                    return .ignored
                }

                let direction: JoystickEngine.Direction
                let key = press.key
                if key == .upArrow || key == "w" {
                    direction = .up
                } else if key == .downArrow || key == "s" {
                    direction = .down
                } else if key == .leftArrow || key == "a" {
                    direction = .left
                } else if key == .rightArrow || key == "d" {
                    direction = .right
                } else {
                    return .ignored
                }

                if press.phase == .down {
                    appState.pressDirection(direction)
                } else {
                    appState.releaseDirection(direction)
                }
                return .handled
            }
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(appState.connectionStatus.isConnected ? .green : .gray)
                                .frame(width: 8, height: 8)
                            Text(mapHintText)
                                .font(.callout)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))

                        if appState.connectionStatus.isConnected {
                            RecordButton()
                        }
                    }

                    if let dest = pendingDestination {
                        DestinationActionBar(coord: dest) { action in
                            switch action {
                            case .teleport:
                                appState.teleport(to: dest)
                            case .direct:
                                appState.travelDirectly(to: dest)
                            case .route:
                                Task { await appState.routeFromCurrent(to: dest) }
                            case .cancel:
                                break
                            }
                            pendingDestination = nil
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private var mapHintText: String {
        switch appState.connectionStatus {
        case .disconnected:
            return "Connect to a device to start"
        case .connecting:
            return "Connecting..."
        case .connected:
            if appState.simState.navigationPlaybackState == .playing {
                let pct = Int(appState.simState.navigationProgress * 100)
                return "Playing route — \(pct)%"
            }
            if appState.simState.joystickIsActive {
                if let coord = appState.simState.simulatedCoordinate {
                    return String(format: "Joystick: %.4f, %.4f", coord.latitude, coord.longitude)
                }
                return "Joystick active"
            }
            if let coord = appState.simState.simulatedCoordinate {
                return String(format: "Simulating: %.4f, %.4f", coord.latitude, coord.longitude)
            }
            switch appState.controlMode {
            case .route: return "Search locations and calculate a route"
            case .joystick: return "Long-press map to teleport, or Start joystick for live control"
            }
        case .error:
            return "Connection error — check sidebar"
        }
    }
}
