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
        .sheet(isPresented: $appState.showWanderSheet) {
            WanderSheet()
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

                Toggle("Restore last location on launch", isOn: $appState.restoreLastSimulatedLocation)
                    .font(.caption)
                    .help("Off: start with no simulated position until you teleport. The last position is remembered either way.")
            }

            if appState.connectionStatus.isConnected {
                RouteSection()
                JoystickSection()
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
            HStack(alignment: .top, spacing: 8) {
                SearchField(
                    label: "From",
                    search: appState.fromSearch,
                    onSelect: { completion in
                        Task { await appState.selectFrom(completion) }
                    }
                )
                .frame(maxWidth: .infinity)

                Button {
                    appState.useCurrentLocationAsFrom()
                } label: {
                    Image(systemName: "location.fill")
                }
                .buttonStyle(.borderless)
                .padding(.top, 6)
                .help("Use current location")
                .disabled(appState.simState.simulatedCoordinate == nil)
            }

            ForEach(Array(appState.stops.enumerated()), id: \.element.id) { index, stop in
                StopRow(index: index, stop: stop)
            }

            if appState.fromCoordinate != nil && appState.toCoordinate != nil {
                Button {
                    appState.addStop()
                } label: {
                    Label("Add Stop", systemImage: "plus.circle")
                }
            }

            SearchField(
                label: "To",
                search: appState.toSearch,
                onSelect: { completion in
                    Task { await appState.selectTo(completion) }
                }
            )

            if appState.stops.count > 10 {
                Text("Apple Maps may throttle routes with this many stops.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

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
            .disabled(!appState.canCalculateRoute)

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
                LoopPicker()
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
            .onChange(of: appState.transportMode) { _, _ in
                appState.persistTuning()
            }

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

private struct StopRow: View {
    let index: Int
    let stop: RouteStop
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            SearchField(
                label: "Stop \(index + 1)",
                search: stop.search,
                onSelect: { completion in
                    Task { await appState.selectStop(id: stop.id, completion: completion) }
                }
            )
            .frame(maxWidth: .infinity)

            Button(role: .destructive) {
                appState.removeStop(id: stop.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .padding(.top, 6)
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

private struct LoopPicker: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        VStack(alignment: .leading, spacing: 6) {
            Picker("Loop", selection: $appState.loopMode) {
                Text("Off").tag(NavigationEngine.LoopMode.off)
                Text("Restart").tag(NavigationEngine.LoopMode.restart)
                Text("Ping-Pong").tag(NavigationEngine.LoopMode.pingPong)
            }
            .pickerStyle(.segmented)

            if appState.loopMode != .off {
                Stepper(value: $appState.loopCount, in: 0...99) {
                    HStack {
                        Text(appState.loopMode == .pingPong ? "Round trips" : "Passes")
                        Spacer()
                        Text(appState.loopCount == 0 ? "∞" : "\(appState.loopCount)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
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
                Text(remainingTimeLabel)
                    .monospacedDigit()
                Spacer()
                Text(formatDistance(sim.navigationTotalDistance))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if appState.loopMode != .off && sim.navigationPlaybackState != .idle {
                Text("Loop \(sim.navigationCompletedLoops + 1) of \(appState.loopCount == 0 ? "∞" : "\(appState.loopCount)")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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

    private var remainingTimeLabel: String {
        let sim = appState.simState
        let remainingMeters = max(0, sim.navigationTotalDistance - sim.navigationElapsedDistance)
        let effectiveSpeed = appState.effectiveBaseSpeedMPS * appState.speedMultiplier
        guard effectiveSpeed > 0 else { return "--:--:--" }
        let total = Int((remainingMeters / effectiveSpeed).rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return String(format: "%02d:%02d:%02d left", hours, minutes, secs)
    }
}

// MARK: - Joystick Controls

private struct JoystickSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
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

// MARK: - Wander Sheet

private struct WanderSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    enum RadiusChoice: Hashable { case fixed(Double), custom }
    enum DurationChoice: Hashable { case fixed(TimeInterval), custom }

    @State private var radiusChoice: RadiusChoice = .fixed(100)
    @State private var customRadiusText: String = "150"
    @State private var durationChoice: DurationChoice = .fixed(15 * 60)
    @State private var customDurationText: String = "20"

    private static let radiusOptions: [(label: String, meters: Double)] = [
        ("50 m", 50), ("100 m", 100), ("200 m", 200)
    ]

    private static let durationOptions: [(label: String, seconds: TimeInterval)] = [
        ("15 min", 15 * 60), ("30 min", 30 * 60), ("1 hr", 60 * 60)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Wander nearby")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }

            if let center = appState.pendingWanderCenter {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.5f, %.5f", center.latitude, center.longitude))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Radius").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(Self.radiusOptions, id: \.label) { opt in
                        ChoiceButton(
                            label: opt.label,
                            isSelected: radiusChoice == .fixed(opt.meters)
                        ) { radiusChoice = .fixed(opt.meters) }
                    }
                    ChoiceButton(
                        label: "Custom",
                        isSelected: radiusChoice == .custom
                    ) { radiusChoice = .custom }
                }
                if radiusChoice == .custom {
                    HStack(spacing: 4) {
                        TextField("meters", text: $customRadiusText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        Text("m").foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Duration").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(Self.durationOptions, id: \.label) { opt in
                        ChoiceButton(
                            label: opt.label,
                            isSelected: durationChoice == .fixed(opt.seconds)
                        ) { durationChoice = .fixed(opt.seconds) }
                    }
                    ChoiceButton(
                        label: "Custom",
                        isSelected: durationChoice == .custom
                    ) { durationChoice = .custom }
                }
                if durationChoice == .custom {
                    HStack(spacing: 4) {
                        TextField("minutes", text: $customDurationText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        Text("min").foregroundStyle(.secondary)
                    }
                }
            }

            Text(previewText)
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Start") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }

    private var resolvedRadius: Double? {
        switch radiusChoice {
        case .fixed(let m): m
        case .custom: Double(customRadiusText.trimmingCharacters(in: .whitespaces))
        }
    }

    private var resolvedDuration: TimeInterval? {
        switch durationChoice {
        case .fixed(let s):
            return s
        case .custom:
            guard let mins = Double(customDurationText.trimmingCharacters(in: .whitespaces)) else { return nil }
            return mins * 60
        }
    }

    private var canStart: Bool {
        guard let r = resolvedRadius, r > 0 else { return false }
        guard let d = resolvedDuration, d > 0 else { return false }
        guard appState.pendingWanderCenter != nil else { return false }
        return true
    }

    private var previewText: String {
        guard let d = resolvedDuration else { return " " }
        let kmh = appState.effectiveBaseSpeedMPS * 3.6
        let km = appState.effectiveBaseSpeedMPS * d / 1000
        let mode: String = {
            if appState.transportMode == .custom {
                return String(format: "Custom %.0f km/h", appState.customSpeedKmh)
            }
            return appState.transportMode.rawValue
        }()
        return String(format: "≈ %.1f km at %@ (%.0f km/h)", km, mode, kmh)
    }

    private func start() {
        guard let center = appState.pendingWanderCenter,
              let radius = resolvedRadius,
              let duration = resolvedDuration else { return }
        dismiss()
        Task { await appState.wanderNearby(center: center, radius: radius, duration: duration) }
    }
}

private struct ChoiceButton: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor.opacity(0.25) : Color.gray.opacity(0.12),
                            in: Capsule())
                .overlay(
                    Capsule().stroke(isSelected ? Color.accentColor : Color.gray.opacity(0.3), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
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
    enum Action { case teleport, direct, route, wander, appendDirect, appendRoute, cancel }

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

            if !appState.routeCoordinates.isEmpty {
                Divider().frame(height: 14)

                Button {
                    onAction(.appendDirect)
                } label: {
                    Label("Append direct", systemImage: "arrow.forward.to.line")
                }
                .buttonStyle(.borderless)

                Button {
                    onAction(.appendRoute)
                } label: {
                    Label("Append route", systemImage: "arrow.triangle.branch")
                }
                .buttonStyle(.borderless)
                .disabled(appState.isCalculatingRoute)
            }

            Divider().frame(height: 14)

            Button {
                onAction(.wander)
            } label: {
                Label("Wander nearby…", systemImage: "shuffle.circle")
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
    @State private var cameraPosition: MapCameraPosition = .region(MapCameraPersistence.loadRegion())
    @State private var pendingDestination: CLLocationCoordinate2D?
    // Session-only, like MapKit's user-tracking: not persisted across launches.
    @State private var isFollowing = false
    // Last user-chosen zoom, so follow recenters without changing it.
    @State private var followSpan: MKCoordinateSpan = MapCameraPersistence.loadRegion().span
    // .contextMenu doesn't expose its click location, so a hover tracker records the last
    // pointer position (map-local space); it's converted to a coordinate lazily at menu
    // time, since a stored coordinate would go stale if the camera moved under the cursor.
    @State private var lastHoverPoint: CGPoint?

    var body: some View {
        MapReader { proxy in
            Map(position: $cameraPosition) {
                if !appState.routeCoordinates.isEmpty {
                    MapPolyline(coordinates: appState.routeCoordinates)
                        .stroke(.blue, lineWidth: 4)
                }

                if let from = appState.fromCoordinate {
                    Marker("Start", systemImage: "flag.fill", coordinate: from)
                        .tint(.green)
                }

                ForEach(Array(appState.stops.enumerated()), id: \.element.id) { idx, stop in
                    if let coord = stop.coordinate {
                        Marker("Stop \(idx + 1)",
                               systemImage: "\(idx + 1).circle.fill",
                               coordinate: coord)
                            .tint(.blue)
                    }
                }

                if let to = appState.toCoordinate {
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
            .onMapCameraChange(frequency: .onEnd) { context in
                MapCameraPersistence.save(region: context.region)
                followSpan = context.region.span
            }
            // Any user camera gesture hands control back to the user, mirroring
            // MapKit's user-tracking semantics. Follow's own programmatic updates
            // report positionedByUser == false, so they don't self-disengage.
            .onMapCameraChange(frequency: .continuous) { _ in
                if isFollowing && cameraPosition.positionedByUser {
                    isFollowing = false
                }
            }
            // CLLocationCoordinate2D isn't Equatable; compare a derived [Double]? instead.
            .onChange(of: appState.simState.simulatedCoordinate.map { [$0.latitude, $0.longitude] }) { _, _ in
                guard isFollowing else { return }
                guard let coord = appState.simState.simulatedCoordinate else {
                    // Nothing left to follow (location cleared back to real GPS).
                    isFollowing = false
                    return
                }
                recenter(on: coord)
            }
            // Long-press fallback for the right-click context menu below — kept so existing
            // muscle memory survives. Long-press, not tap: a plain tap would steal the Map's
            // own pan/zoom gestures, and the 0.5s threshold disambiguates intent from
            // incidental clicks.
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
            .onContinuousHover(coordinateSpace: .local) { phase in
                // Keep the last point on .ended — the menu's content is evaluated after the
                // right-click, by which time hover tracking has already stopped.
                if case .active(let point) = phase {
                    lastHoverPoint = point
                }
            }
            .contextMenu {
                destinationMenu(proxy: proxy)
            }
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
                            followButton
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
                            case .wander:
                                appState.pendingWanderCenter = dest
                                appState.showWanderSheet = true
                            case .appendDirect:
                                Task { await appState.appendDirectly(to: dest) }
                            case .appendRoute:
                                Task { await appState.appendRoute(to: dest) }
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

    private var followButton: some View {
        Button {
            if isFollowing {
                isFollowing = false
            } else if let coord = appState.simState.simulatedCoordinate {
                isFollowing = true
                // Center now rather than waiting for the next snapshot push.
                recenter(on: coord)
            }
        } label: {
            Image(systemName: isFollowing ? "location.fill" : "location")
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .disabled(appState.simState.simulatedCoordinate == nil)
        .help(isFollowing ? "Stop following the simulated position"
                          : "Follow the simulated position")
    }

    private func recenter(on coord: CLLocationCoordinate2D) {
        withAnimation {
            cameraPosition = .region(MKCoordinateRegion(center: coord, span: followSpan))
        }
    }

    // Right-click destination menu: same actions as DestinationActionBar (the long-press
    // capsule), presented as a native context menu at the pointer — macOS convention, and
    // consistent with the sidebar rows' .contextMenu. Empty content while disconnected
    // suppresses the menu entirely, mirroring the long-press guard.
    @ViewBuilder
    private func destinationMenu(proxy: MapProxy) -> some View {
        if appState.connectionStatus.isConnected,
           let point = lastHoverPoint,
           let coordinate = proxy.convert(point, from: .local) {
            Section(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)) {
                Button {
                    appState.teleport(to: coordinate)
                } label: {
                    Label("Teleport", systemImage: "bolt.fill")
                }

                // Unlike long-press (which teleports instantly when there's no origin), a
                // context menu always opens; origin-dependent actions just disable instead.
                Button {
                    appState.travelDirectly(to: coordinate)
                } label: {
                    Label("Go directly", systemImage: "arrow.up.right.circle")
                }
                .disabled(appState.simState.simulatedCoordinate == nil)

                Button {
                    Task { await appState.routeFromCurrent(to: coordinate) }
                } label: {
                    Label("Route here", systemImage: "map.fill")
                }
                .disabled(appState.simState.simulatedCoordinate == nil || appState.isCalculatingRoute)
            }

            if !appState.routeCoordinates.isEmpty {
                Section {
                    Button {
                        Task { await appState.appendDirectly(to: coordinate) }
                    } label: {
                        Label("Append direct", systemImage: "arrow.forward.to.line")
                    }

                    Button {
                        Task { await appState.appendRoute(to: coordinate) }
                    } label: {
                        Label("Append route", systemImage: "arrow.triangle.branch")
                    }
                    .disabled(appState.isCalculatingRoute)
                }
            }

            Section {
                Button {
                    appState.pendingWanderCenter = coordinate
                    appState.showWanderSheet = true
                } label: {
                    Label("Wander nearby…", systemImage: "shuffle.circle")
                }
                .disabled(appState.isCalculatingRoute)
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
            if let coord = appState.simState.simulatedCoordinate {
                return String(format: "Simulating: %.4f, %.4f", coord.latitude, coord.longitude)
            }
            return "Right-click the map to set a starting location"
        case .error:
            return "Connection error — check sidebar"
        }
    }
}

private enum MapCameraPersistence {
    private static let centerLatKey = "MapCamera.centerLat"
    private static let centerLonKey = "MapCamera.centerLon"
    private static let spanLatKey = "MapCamera.spanLatDelta"
    private static let spanLonKey = "MapCamera.spanLonDelta"

    private static let defaultCenter = CLLocationCoordinate2D(latitude: 25.033, longitude: 121.565)
    private static let defaultSpan = MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)

    static func loadRegion() -> MKCoordinateRegion {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: centerLatKey) != nil else {
            return MKCoordinateRegion(center: defaultCenter, span: defaultSpan)
        }
        let center = CLLocationCoordinate2D(
            latitude: defaults.double(forKey: centerLatKey),
            longitude: defaults.double(forKey: centerLonKey)
        )
        let span = MKCoordinateSpan(
            latitudeDelta: defaults.double(forKey: spanLatKey),
            longitudeDelta: defaults.double(forKey: spanLonKey)
        )
        return MKCoordinateRegion(center: center, span: span)
    }

    static func save(region: MKCoordinateRegion) {
        let defaults = UserDefaults.standard
        defaults.set(region.center.latitude, forKey: centerLatKey)
        defaults.set(region.center.longitude, forKey: centerLonKey)
        defaults.set(region.span.latitudeDelta, forKey: spanLatKey)
        defaults.set(region.span.longitudeDelta, forKey: spanLonKey)
    }
}
