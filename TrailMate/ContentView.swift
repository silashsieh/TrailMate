import SwiftUI
import MapKit

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            MapArea()
        }
        .navigationTitle("TrailMate")
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
                    TextField("RSD Address", text: $appState.rsdAddress)
                        .textFieldStyle(.roundedBorder)
                    TextField("RSD Port", text: $appState.rsdPort)
                        .textFieldStyle(.roundedBorder)
                    ConnectionButton()
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
                case .teleport:
                    TeleportSection()
                case .route:
                    RouteSection()
                }
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
            }
        }
        .navigationSplitViewColumnWidth(min: 280, ideal: 320)
    }
}

// MARK: - Teleport Controls

private struct TeleportSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Section("Teleport") {
            if let coord = appState.simulatedCoordinate {
                Text(String(format: "%.6f, %.6f", coord.latitude, coord.longitude))
                    .font(.caption)
                    .textSelection(.enabled)
                Button("Clear Location", role: .destructive) {
                    Task { await appState.clearLocation() }
                }
            } else {
                Text("Long-press on map to teleport")
                    .foregroundStyle(.secondary)
            }
        }
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

            Picker("Transport", selection: $appState.transportMode) {
                ForEach(TransportMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)

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
        }

        if !appState.routeCoordinates.isEmpty {
            Section("Playback") {
                SpeedPicker(speedMultiplier: $appState.speedMultiplier)
                PlaybackControls()
                PlaybackProgress()
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
            switch appState.navigationEngine.playbackState {
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
            .disabled(appState.navigationEngine.playbackState == .idle)
        }
    }
}

private struct PlaybackProgress: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let engine = appState.navigationEngine
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: engine.progress)
            HStack {
                Text(formatDistance(engine.elapsedDistance))
                Spacer()
                Text(formatDistance(engine.totalDistance))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func formatDistance(_ meters: Double) -> String {
        if meters >= 1000 {
            return String(format: "%.1f km", meters / 1000)
        }
        return String(format: "%.0f m", meters)
    }
}

// MARK: - Sidebar Components

private struct ConnectionButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Button {
            Task { await appState.connect() }
        } label: {
            HStack {
                if appState.connectionStatus == .connecting {
                    ProgressView().controlSize(.small)
                }
                Text(appState.connectionStatus == .connecting ? "Connecting…" : "Connect")
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(appState.connectionStatus == .connecting)
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

// MARK: - Map

private struct MapArea: View {
    @Environment(AppState.self) private var appState
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 25.033, longitude: 121.565),
            span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        )
    )

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

                if let coord = appState.simulatedCoordinate {
                    Annotation("", coordinate: coord) {
                        Circle()
                            .fill(.red)
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .mapControls {
                MapCompass()
                MapZoomStepper()
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                    .onEnded { value in
                        guard case .second(true, let drag) = value, let drag else { return }
                        guard appState.connectionStatus.isConnected else { return }
                        guard appState.controlMode == .teleport else { return }
                        if let coordinate = proxy.convert(drag.location, from: .local) {
                            Task {
                                await appState.teleport(to: coordinate)
                            }
                        }
                    }
            )
            .overlay(alignment: .top) {
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
                .padding(.top, 8)
            }
        }
    }

    private var mapHintText: String {
        switch appState.connectionStatus {
        case .disconnected:
            "Connect to a device to start"
        case .connecting:
            "Connecting..."
        case .connected:
            if appState.navigationEngine.playbackState == .playing {
                let pct = Int(appState.navigationEngine.progress * 100)
                return "Playing route — \(pct)%"
            }
            if let coord = appState.simulatedCoordinate {
                return String(format: "Simulating: %.4f, %.4f", coord.latitude, coord.longitude)
            }
            switch appState.controlMode {
            case .teleport: return "Long-press on map to teleport"
            case .route: return "Search locations and calculate a route"
            }
        case .error:
            "Connection error — check sidebar"
        }
    }
}
