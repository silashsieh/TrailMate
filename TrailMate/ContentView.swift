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
            Section("RSD Tunnel") {
                TextField("Address", text: $appState.rsdAddress)
                    .textFieldStyle(.roundedBorder)
                TextField("Port", text: $appState.rsdPort)
                    .textFieldStyle(.roundedBorder)

                ConnectionButton()
            }

            Section("Location") {
                StatusRow()

                if appState.simulatedCoordinate != nil {
                    Button("Clear Location", role: .destructive) {
                        Task { await appState.clearLocation() }
                    }
                }
            }

            Section("Log") {
                if appState.logMessages.isEmpty {
                    Text("No activity yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(appState.logMessages.enumerated()), id: \.offset) { _, msg in
                        Text(msg)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 260, ideal: 300)
    }
}

// MARK: - Sidebar Components

private struct ConnectionButton: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Button {
            Task {
                if appState.connectionStatus.isConnected {
                    await appState.disconnect()
                } else {
                    await appState.connect()
                }
            }
        } label: {
            HStack {
                if appState.connectionStatus == .connecting {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(buttonLabel)
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(appState.connectionStatus == .connecting)
    }

    private var buttonLabel: String {
        switch appState.connectionStatus {
        case .disconnected: "Connect"
        case .connecting: "Connecting…"
        case .connected: "Disconnect"
        case .error: "Retry"
        }
    }
}

private struct StatusRow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(statusText)
                .font(.callout)
        }
    }

    private var statusColor: Color {
        switch appState.connectionStatus {
        case .disconnected: .gray
        case .connecting: .yellow
        case .connected: .green
        case .error: .red
        }
    }

    private var statusText: String {
        switch appState.connectionStatus {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case .connected:
            if let coord = appState.simulatedCoordinate {
                String(format: "Simulating: %.4f, %.4f", coord.latitude, coord.longitude)
            } else {
                "Connected — tap map to teleport"
            }
        case .error(let msg): "Error: \(msg)"
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
                if let coord = appState.simulatedCoordinate {
                    Marker("Simulated Location", systemImage: "location.fill", coordinate: coord)
                        .tint(.red)
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
            if let coord = appState.simulatedCoordinate {
                String(format: "Simulating: %.4f, %.4f — long-press to move", coord.latitude, coord.longitude)
            } else {
                "Long-press on map to teleport"
            }
        case .error:
            "Connection error — check sidebar"
        }
    }
}
