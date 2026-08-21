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
    // The live log occupies space it rarely earns; start collapsed and remember
    // the user's choice across launches. (The full-log sheet stays the deep view.)
    @AppStorage("sidebarLogExpanded") private var logExpanded = false

    // Normally the persisted choice; under the --uitest-expand-log hook, forced
    // open so the smoke suite can assert the section's contents without
    // depending on the persisted (collapsed-by-default) state.
    private var logExpansion: Binding<Bool> {
        #if DEBUG
        if UITestSupport.expandLog { return .constant(true) }
        #endif
        return $logExpanded
    }

    var body: some View {
        List {
            Section("Devices") {
                // The switcher: one compact row per session, tap to select which
                // device the control surface (route/playback/joystick) + map
                // planning target. Add Device appends a slot.
                ForEach(appState.sessions) { session in
                    DeviceSwitcherRow(session: session)
                }
                Button {
                    appState.addSession()
                } label: {
                    Label("Add Device", systemImage: "plus")
                }

                // Connection controls for the *selected* session. The row above
                // shows its status; this is the action surface.
                if appState.connectionStatus.isConnected {
                    Button("Disconnect") {
                        Task { await appState.disconnect() }
                    }
                } else {
                    DevicePickerArea()
                    ConnectionButton()
                }
            }

            // Direct location entry (epic 027): search a place or type a
            // coordinate to teleport the red dot, independent of route endpoints.
            DirectLocationSection()

            // Both sections drive the local red dot, with or without a device
            // attached (the device mirrors it once connected), so neither is
            // gated on connection.
            RouteSection()
            JoystickSection()

            if !appState.savedWaypoints.isEmpty || appState.simState.simulatedCoordinate != nil {
                SavedLocationsSection()
            }

            if !appState.savedRoutes.routes.isEmpty {
                SavedRoutesSection()
            }

            if !appState.recorder.recordings.isEmpty {
                RecordingsSection()
            }

            // Live log, collapsed by default (epic 025). A DisclosureGroup keeps
            // an always-visible disclosure triangle next to the "Log" label, so
            // it's obvious the section opens (a collapsed `Section` only reveals
            // its control on hover). The @AppStorage binding persists the choice.
            DisclosureGroup("Log", isExpanded: logExpansion) {
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
                    Text(mode.displayName).tag(mode)
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
    let label: LocalizedStringKey
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

// MARK: - Direct location entry (epic 027)

// Search a place or type a coordinate to teleport the red dot, independent of
// the route From/To fields (#42, #52). Selecting a search result or submitting
// a coordinate teleports directly — it consumes no route slot — and a copy
// affordance puts the current position on the clipboard. Nothing here gates on
// a connection: teleport drives the local dot, mirrored by a device when one is
// attached (epic 028).
private struct DirectLocationSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Section("Go to Location") {
            // Tapping a result goes straight there (it is the "Go here"
            // affordance), unlike the route fields where selection just fills
            // the slot.
            SearchField(
                label: "Search for a place",
                search: appState.placeSearch,
                onSelect: { completion in
                    Task { await appState.goToSearchResult(completion) }
                }
            )

            CoordinateEntryField()

            if let coord = appState.simState.simulatedCoordinate {
                Button {
                    appState.copyCoordinate(coord)
                } label: {
                    Label("Copy Current Coordinate", systemImage: "doc.on.doc")
                }
            }
        }
    }
}

// Decimal-degree "lat, lon" entry that teleports on submit (#52). The Go button
// and Return both commit; the button disables until the text parses, and a
// short hint appears after a failed parse.
private struct CoordinateEntryField: View {
    @Environment(AppState.self) private var appState
    @State private var text = ""
    @State private var showHint = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                TextField("lat, lon", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { go() }

                Button("Go") { go() }
                    .disabled(CoordinateFormat.parse(text) == nil)
            }

            if showHint {
                Text("Enter decimal degrees, e.g. 25.0330, 121.5654")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func go() {
        guard let coord = CoordinateFormat.parse(text) else {
            showHint = true
            return
        }
        showHint = false
        appState.goToCoordinate(coord)
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
    // Non-nil while a scrub gesture is in flight: the thumb tracks the pointer
    // locally instead of fighting the actor's snapshot pushes. The released
    // value is what gets applied, so it must survive until onEditingChanged
    // reports the drag ended.
    @State private var scrubValue: Double?
    @State private var isDragging = false

    var body: some View {
        let sim = appState.simState
        VStack(alignment: .leading, spacing: 4) {
            Slider(
                value: Binding(
                    get: { scrubValue ?? sim.navigationProgress },
                    set: { newValue in
                        if isDragging {
                            scrubValue = newValue
                            appState.scrubPlayback(toProgress: newValue)
                        } else {
                            // Value change outside a drag (keyboard arrows, or
                            // a track click that outran onEditingChanged) —
                            // apply as a one-shot seek.
                            appState.seekPlayback(toProgress: newValue)
                        }
                    }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    isDragging = editing
                    if editing {
                        appState.beginPlaybackScrub()
                    } else {
                        if let released = scrubValue {
                            appState.seekPlayback(toProgress: released)
                        } else {
                            // Click with no value change — just release the hold.
                            appState.endPlaybackScrub()
                        }
                        scrubValue = nil
                    }
                }
            )
            .accessibilityLabel("Playback position")
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
                    Label("Off-route: \(appState.simState.routeDeviationMeters, specifier: "%.0f") m",
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
            return String(format: String(localized: "%.1f km"), meters / 1000)
        }
        return String(format: String(localized: "%.0f m"), meters)
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
        return String(format: String(localized: "%02d:%02d:%02d left"), hours, minutes, secs)
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
        // Ungrouped waypoints sit under the main header, next to Save Current
        // Location; each user-defined folder gets its own section below. Drag
        // reorders within a section (.onMove); the row context menu moves an
        // item between folders. (epic 029)
        let ungrouped = appState.savedWaypoints.filter { $0.category == nil }
        let canSave = appState.simState.simulatedCoordinate != nil
        if !ungrouped.isEmpty || canSave {
            Section("Saved Locations") {
                ForEach(ungrouped) { waypoint in
                    SavedLocationRow(waypoint: waypoint)
                }
                .onMove { source, destination in
                    appState.moveWaypoints(inCategory: nil, fromOffsets: source, toOffset: destination)
                }

                if canSave {
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

        ForEach(appState.savedLocationCategories, id: \.self) { category in
            Section(category) {
                ForEach(appState.savedWaypoints.filter { $0.category == category }) { waypoint in
                    SavedLocationRow(waypoint: waypoint)
                }
                .onMove { source, destination in
                    appState.moveWaypoints(inCategory: category, fromOffsets: source, toOffset: destination)
                }
            }
        }
    }
}

private struct SavedLocationRow: View {
    let waypoint: SavedWaypoint
    @Environment(AppState.self) private var appState
    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var showNewCategoryAlert = false
    @State private var newCategoryName = ""
    @FocusState private var nameFieldIsFocused: Bool

    var body: some View {
        Group {
            if isRenaming {
                VStack(alignment: .leading) {
                    TextField("Name", text: $draftName)
                        .font(.callout)
                        .focused($nameFieldIsFocused)
                        .onSubmit { commitRename() }
                        .onExitCommand { isRenaming = false }
                        .onAppear { nameFieldIsFocused = true }
                    Text(coordinateText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Button {
                    appState.teleportToWaypoint(waypoint)
                } label: {
                    VStack(alignment: .leading) {
                        Text(waypoint.name)
                            .font(.callout)
                        Text(coordinateText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        // Click-away commits, like Finder. onSubmit clears isRenaming before the
        // field resigns focus, so an Enter-commit doesn't also commit here.
        .onChange(of: nameFieldIsFocused) { _, focused in
            if !focused && isRenaming { commitRename() }
        }
        .contextMenu {
            Button("Rename") { beginRename() }
            CategoryMenu(
                categories: appState.savedLocationCategories,
                current: waypoint.category,
                assign: { appState.setWaypointCategory($0, for: waypoint) },
                newCategory: { newCategoryName = ""; showNewCategoryAlert = true }
            )
            Button("Delete", role: .destructive) {
                appState.deleteWaypoint(waypoint)
            }
        }
        .alert("New Category", isPresented: $showNewCategoryAlert) {
            TextField("Category", text: $newCategoryName)
            Button("Create") {
                appState.setWaypointCategory(newCategoryName, for: waypoint)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var coordinateText: String {
        String(format: "%.4f, %.4f", waypoint.latitude, waypoint.longitude)
    }

    private func beginRename() {
        draftName = waypoint.name
        isRenaming = true
    }

    private func commitRename() {
        isRenaming = false
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty name cancels the rename, like Finder.
        guard !trimmed.isEmpty, trimmed != waypoint.name else { return }
        appState.renameWaypoint(waypoint, to: trimmed)
    }
}

// Shared "Category" submenu for saved-item context menus (epic 029): assign the
// item to an existing folder (the current one checkmarked), spin up a new
// folder, or clear the assignment.
private struct CategoryMenu: View {
    let categories: [String]
    let current: String?
    let assign: (String?) -> Void
    let newCategory: () -> Void

    var body: some View {
        Menu("Category") {
            ForEach(categories, id: \.self) { category in
                Button {
                    assign(category)
                } label: {
                    if category == current {
                        Label(category, systemImage: "checkmark")
                    } else {
                        Text(category)
                    }
                }
            }
            if !categories.isEmpty {
                Divider()
            }
            Button("New Category…") { newCategory() }
            if current != nil {
                Button("Remove from Category") { assign(nil) }
            }
        }
    }
}

// MARK: - Saved Routes

private struct SavedRoutesSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        // Ungrouped routes under the main header; one section per folder below.
        // No Save button here (routes are saved from the Route section), so skip
        // the header entirely when everything is filed away. (epic 029)
        let ungrouped = appState.savedRoutes.routes.filter { $0.category == nil }
        if !ungrouped.isEmpty {
            Section("Saved Routes") {
                ForEach(ungrouped) { route in
                    SavedRouteRow(route: route)
                }
                .onMove { source, destination in
                    appState.moveRoutes(inCategory: nil, fromOffsets: source, toOffset: destination)
                }
            }
        }

        ForEach(appState.savedRouteCategories, id: \.self) { category in
            Section(category) {
                ForEach(appState.savedRoutes.routes.filter { $0.category == category }) { route in
                    SavedRouteRow(route: route)
                }
                .onMove { source, destination in
                    appState.moveRoutes(inCategory: category, fromOffsets: source, toOffset: destination)
                }
            }
        }
    }
}

private struct SavedRouteRow: View {
    let route: SavedRoute
    @Environment(AppState.self) private var appState
    @State private var isRenaming = false
    @State private var draftName = ""
    @State private var showNewCategoryAlert = false
    @State private var newCategoryName = ""
    @FocusState private var nameFieldIsFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isRenaming {
                TextField("Name", text: $draftName)
                    .font(.callout)
                    .focused($nameFieldIsFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { isRenaming = false }
                    .onAppear { nameFieldIsFocused = true }
            } else {
                Text(route.name)
                    .font(.callout)
            }
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isRenaming else { return }
            appState.loadSavedRoute(route, autoPlay: false)
        }
        // Click-away commits, like Finder. onSubmit clears isRenaming before the
        // field resigns focus, so an Enter-commit doesn't also commit here.
        .onChange(of: nameFieldIsFocused) { _, focused in
            if !focused && isRenaming { commitRename() }
        }
        .contextMenu {
            Button("Load") { appState.loadSavedRoute(route, autoPlay: false) }
            Button("Replay") { appState.loadSavedRoute(route, autoPlay: true) }
            Button("Rename") { beginRename() }
            CategoryMenu(
                categories: appState.savedRouteCategories,
                current: route.category,
                assign: { appState.setRouteCategory($0, for: route) },
                newCategory: { newCategoryName = ""; showNewCategoryAlert = true }
            )
            Button("Delete", role: .destructive) { appState.deleteSavedRoute(route) }
        }
        .alert("New Category", isPresented: $showNewCategoryAlert) {
            TextField("Category", text: $newCategoryName)
            Button("Create") {
                appState.setRouteCategory(newCategoryName, for: route)
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func beginRename() {
        draftName = route.name
        isRenaming = true
    }

    private func commitRename() {
        isRenaming = false
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty name cancels the rename, like Finder.
        guard !trimmed.isEmpty, trimmed != route.name else { return }
        appState.renameSavedRoute(route, to: trimmed)
    }

    private var detail: String {
        let dist = route.distanceMeters
        let distStr = dist >= 1000
            ? String(format: String(localized: "%.2f km"), dist / 1000)
            : String(format: String(localized: "%.0f m"), dist)
        return String(localized: "\(route.transportMode.displayName) · \(distStr) · \(route.coordinates.count) pts")
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
            ? String(format: String(localized: "%.2f km"), dist / 1000)
            : String(format: String(localized: "%.0f m"), dist)
        let totalSec = Int(session.duration.rounded())
        let minutes = totalSec / 60
        let seconds = totalSec % 60
        return String(localized: "\(session.points.count) pts · \(distStr) · \(minutes)m \(seconds)s")
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

    @State private var mode: WanderMode
    @State private var radiusChoice: RadiusChoice
    @State private var customRadiusText: String
    @State private var durationChoice: DurationChoice
    @State private var customDurationText: String
    @State private var laneSpacingText: String

    // Numeric so the unit suffix can be a localizable label ("%lld m" /
    // "%lld min") rendered inline, rather than a baked-in English string.
    private static let radiusOptions: [Double] = [250, 500, 750]
    private static let durationOptions: [TimeInterval] = [30 * 60, 60 * 60, 120 * 60]

    // Each open restores the last persisted selection (epic 018); the sheet
    // is created per presentation, so init is the restore point. Mode is part
    // of that: reopening lands in whichever mode was used last.
    init() {
        _mode = State(initialValue: WanderPresetPersistence.mode)
        _radiusChoice = State(initialValue: WanderPresetPersistence.radiusIsCustom
            ? .custom : .fixed(WanderPresetPersistence.radiusMeters))
        _customRadiusText = State(initialValue: Self.format(WanderPresetPersistence.customRadiusMeters))
        _durationChoice = State(initialValue: WanderPresetPersistence.durationIsCustom
            ? .custom : .fixed(WanderPresetPersistence.durationSeconds))
        _customDurationText = State(initialValue: Self.format(WanderPresetPersistence.customDurationMinutes))
        _laneSpacingText = State(initialValue: Self.format(WanderPresetPersistence.laneSpacingMeters))
    }

    // The magnitude bound keeps Int(value) from trapping if an absurd custom
    // value (e.g. "1e300") was ever persisted — show it raw instead.
    private static func format(_ value: Double) -> String {
        value == value.rounded() && value.magnitude < 1e15 ? String(Int(value)) : String(value)
    }

    private static let customRadiusRange: ClosedRange<Double> = 50...2000
    private static let customDurationRange: ClosedRange<Double> = 5...240
    private static let laneSpacingRange: ClosedRange<Double> = 10...500

    // Slider ↔ text bindings: the text field stays the source of truth — it
    // feeds persistence and resolution — and the slider is a view over it.
    // Typed values outside the slider range stay valid; the knob just pins
    // to the nearest end until the slider is dragged.
    private var customRadiusSlider: Binding<Double> {
        Binding {
            Double(customRadiusText.trimmingCharacters(in: .whitespaces))
                ?? WanderPresetPersistence.defaultCustomRadiusMeters
        } set: { customRadiusText = Self.format($0) }
    }

    private var customDurationSlider: Binding<Double> {
        Binding {
            Double(customDurationText.trimmingCharacters(in: .whitespaces))
                ?? WanderPresetPersistence.defaultCustomDurationMinutes
        } set: { customDurationText = Self.format($0) }
    }

    private var laneSpacingSlider: Binding<Double> {
        Binding {
            Double(laneSpacingText.trimmingCharacters(in: .whitespaces))
                ?? WanderPresetPersistence.defaultLaneSpacingMeters
        } set: { laneSpacingText = Self.format($0) }
    }

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

            // Two peer ways to generate a route from the same point and radius,
            // so the mode sits above them as a segmented control rather than
            // reading as a third preset row.
            Picker("Mode", selection: $mode) {
                Text("Random").tag(WanderMode.random)
                Text("Sweeping").tag(WanderMode.sweeping)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("wander.mode")

            VStack(alignment: .leading, spacing: 6) {
                Text("Radius").font(.subheadline).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    ForEach(Self.radiusOptions, id: \.self) { meters in
                        ChoiceButton(
                            label: "\(Int(meters)) m",
                            isSelected: radiusChoice == .fixed(meters),
                            accessibilityID: "wander.radius.\(Int(meters))"
                        ) { radiusChoice = .fixed(meters) }
                    }
                    ChoiceButton(
                        label: "Custom",
                        isSelected: radiusChoice == .custom,
                        accessibilityID: "wander.radius.custom"
                    ) { radiusChoice = .custom }
                }
                if radiusChoice == .custom {
                    HStack(spacing: 8) {
                        Slider(value: customRadiusSlider, in: Self.customRadiusRange, step: 50)
                        TextField("meters", text: $customRadiusText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        Text("m").foregroundStyle(.secondary)
                    }
                }
                // Radius is the center-to-edge half-side when sweeping, which is
                // easy to misread as a corner distance — so spell the square out.
                if let sweep = sweepResult, let radius = resolvedRadius {
                    Text(String(format: String(localized: "Square side %.0f m · %d lanes"),
                                radius * 2, sweep.laneCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if mode == .random {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Duration").font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach(Self.durationOptions, id: \.self) { seconds in
                            ChoiceButton(
                                label: "\(Int(seconds / 60)) min",
                                isSelected: durationChoice == .fixed(seconds),
                                accessibilityID: "wander.duration.\(Int(seconds / 60))"
                            ) { durationChoice = .fixed(seconds) }
                        }
                        ChoiceButton(
                            label: "Custom",
                            isSelected: durationChoice == .custom,
                            accessibilityID: "wander.duration.custom"
                        ) { durationChoice = .custom }
                    }
                    if durationChoice == .custom {
                        HStack(spacing: 8) {
                            Slider(value: customDurationSlider, in: Self.customDurationRange, step: 5)
                            TextField("minutes", text: $customDurationText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 90)
                            Text("min").foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // No duration control when sweeping: the square and the lane spacing
            // fix the route, so its length — and therefore its time — is derived,
            // not chosen.
            if mode == .sweeping {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Lane spacing").font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Slider(value: laneSpacingSlider, in: Self.laneSpacingRange, step: 5)
                        TextField("meters", text: $laneSpacingText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .accessibilityIdentifier("wander.sweep.spacing")
                        Text("m").foregroundStyle(.secondary)
                    }
                }
            }

            Text(previewText)
                .font(.callout)
                .foregroundStyle(previewIsWarning ? Color.orange : Color.secondary)

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
        // Persist every change, not just Start — quitting with the sheet open
        // must still restore the selection on relaunch. Custom text is only
        // recorded once it parses to a positive number, so a half-typed value
        // never clobbers the last good one.
        .onChange(of: mode) { _, choice in
            WanderPresetPersistence.mode = choice
        }
        .onChange(of: radiusChoice) { _, choice in
            switch choice {
            case .fixed(let m):
                WanderPresetPersistence.radiusIsCustom = false
                WanderPresetPersistence.radiusMeters = m
            case .custom:
                WanderPresetPersistence.radiusIsCustom = true
            }
        }
        .onChange(of: customRadiusText) { _, text in
            // .isFinite: Double("1e999") parses to +inf, which must not persist.
            if let m = Double(text.trimmingCharacters(in: .whitespaces)), m > 0, m.isFinite {
                WanderPresetPersistence.customRadiusMeters = m
            }
        }
        .onChange(of: durationChoice) { _, choice in
            switch choice {
            case .fixed(let s):
                WanderPresetPersistence.durationIsCustom = false
                WanderPresetPersistence.durationSeconds = s
            case .custom:
                WanderPresetPersistence.durationIsCustom = true
            }
        }
        .onChange(of: customDurationText) { _, text in
            if let mins = Double(text.trimmingCharacters(in: .whitespaces)), mins > 0, mins.isFinite {
                WanderPresetPersistence.customDurationMinutes = mins
            }
        }
        .onChange(of: laneSpacingText) { _, text in
            if let m = Double(text.trimmingCharacters(in: .whitespaces)), m > 0, m.isFinite {
                WanderPresetPersistence.laneSpacingMeters = m
            }
        }
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

    private var resolvedSpacing: Double? {
        Double(laneSpacingText.trimmingCharacters(in: .whitespaces))
    }

    // Sweeping geometry is pure arithmetic and bounded by the builder's point
    // cap, so the sheet builds the real route to preview it: the distance and
    // time shown are measured off the very coordinates Start hands to the
    // engine. nil means there's nothing to preview yet (not an error).
    private var sweepPreview: Result<CoverageRouteBuilder.Result, Error>? {
        guard mode == .sweeping,
              let center = appState.pendingWanderCenter,
              let radius = resolvedRadius, radius > 0, radius.isFinite,
              let spacing = resolvedSpacing, spacing > 0, spacing.isFinite
        else { return nil }
        return Result {
            try CoverageRouteBuilder.build(options: CoverageRouteBuilder.Options(
                center: center, halfSideMeters: radius, laneSpacingMeters: spacing
            ))
        }
    }

    private var sweepResult: CoverageRouteBuilder.Result? {
        guard case .success(let result) = sweepPreview else { return nil }
        return result
    }

    private var canStart: Bool {
        guard let r = resolvedRadius, r > 0, r.isFinite else { return false }
        guard appState.pendingWanderCenter != nil else { return false }
        switch mode {
        case .random:
            guard let d = resolvedDuration, d > 0 else { return false }
            return true
        case .sweeping:
            return sweepResult != nil
        }
    }

    private var previewIsWarning: Bool {
        if case .some(.failure) = sweepPreview { return true }
        return false
    }

    private var speedLabel: String {
        if appState.transportMode == .custom {
            return String(format: String(localized: "Custom %.0f km/h"), appState.customSpeedKmh)
        }
        return appState.transportMode.displayName
    }

    private var previewText: String {
        switch mode {
        case .random: randomPreviewText
        case .sweeping: sweepPreviewText
        }
    }

    // Random picks the duration, so distance is speed × duration.
    private var randomPreviewText: String {
        guard let d = resolvedDuration else { return " " }
        let kmh = appState.effectiveBaseSpeedMPS * 3.6
        let km = appState.effectiveBaseSpeedMPS * d / 1000
        return String(format: String(localized: "≈ %.1f km at %@ (%.0f km/h)"), km, speedLabel, kmh)
    }

    // Sweeping inverts it: the geometry fixes the distance, and the time follows
    // from the base speed.
    private var sweepPreviewText: String {
        guard let preview = sweepPreview else { return " " }
        switch preview {
        case .success(let result):
            guard let seconds = CoverageRouteBuilder.estimatedSeconds(
                distanceMeters: result.distanceMeters,
                speedMPS: appState.effectiveBaseSpeedMPS
            ) else { return " " }
            return String(
                format: String(localized: "≈ %.1f km, ~%.0f min at %@ (%.0f km/h)"),
                result.distanceMeters / 1000, seconds / 60, speedLabel, appState.effectiveBaseSpeedMPS * 3.6
            )
        case .failure(let error):
            if let builderError = error as? CoverageRouteBuilder.BuilderError,
               case .tooManyPoints = builderError {
                return String(localized: "Too many lanes — increase the spacing")
            }
            return String(localized: "Can't sweep this area")
        }
    }

    private func start() {
        guard let center = appState.pendingWanderCenter,
              let radius = resolvedRadius else { return }
        switch mode {
        case .random:
            guard let duration = resolvedDuration else { return }
            dismiss()
            Task { await appState.wanderNearby(center: center, radius: radius, duration: duration) }
        case .sweeping:
            guard let spacing = resolvedSpacing else { return }
            dismiss()
            Task { await appState.sweepArea(center: center, halfSideMeters: radius, laneSpacingMeters: spacing) }
        }
    }
}

private struct ChoiceButton: View {
    let label: LocalizedStringKey
    let isSelected: Bool
    // Disambiguates same-labeled buttons (the two "Custom"s) for UI tests.
    var accessibilityID: String? = nil
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
        .accessibilityIdentifier(accessibilityID ?? "")
    }
}

// MARK: - Sidebar Components

private struct DevicePickerArea: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        // Bind the picker to the selected session's own target UDID (the per-slot
        // picker value), not a manager-global one.
        @Bindable var session = appState.selectedSession
        let discovery = appState.discovery
        // Hide devices another session is already connected to, so two slots
        // can't fight over one device.
        let available = discovery.devices.filter { device in
            !appState.sessions.contains { $0.id != session.id && $0.connectedUDID == device.udid }
        }

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Device")
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

            if !available.isEmpty {
                Picker("Device", selection: $session.selectedDeviceUDID) {
                    Text("Select…").tag(String?.none)
                    ForEach(available) { device in
                        Text(device.displayLabel).tag(Optional(device.udid))
                    }
                }
                .labelsHidden()
            } else if discovery.hasScanned && !discovery.isScanning {
                Group {
                    // lastError is a system NSError description (already
                    // OS-localized) — render verbatim, not as a lookup key.
                    if let err = discovery.lastError {
                        Text(verbatim: err)
                    } else {
                        Text("No devices found.")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let udid = session.selectedDeviceUDID,
               available.first(where: { $0.udid == udid }) != nil {
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
        let noDevice = (appState.selectedSession.selectedDeviceUDID ?? "").isEmpty
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

// One row in the device switcher. Tap selects which device the control surface
// and map planning target; a color swatch ties the row to that device's marker
// and route on the map. Context menu disconnects this specific session or
// removes its slot (the collection never empties).
private struct DeviceSwitcherRow: View {
    let session: DeviceSession
    @Environment(AppState.self) private var appState

    var body: some View {
        let isSelected = session.id == appState.selectedSessionID
        Button {
            appState.selectedSessionID = session.id
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(appState.color(for: session))
                    .frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.deviceName ?? String(localized: "No device"))
                        .font(.callout)
                        // Emphasize the active session's name (epic 026): the
                        // switcher already lists every device's name; weight marks
                        // which one the control surface and status currently track.
                        .fontWeight(isSelected ? .semibold : .regular)
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(statusColor)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .contextMenu {
            if session.connectionStatus.isConnected {
                Button("Disconnect") {
                    Task {
                        await session.disconnect()
                        appState.syncActiveJoystick()
                    }
                }
            }
            if appState.sessions.count > 1 {
                Button("Remove", role: .destructive) {
                    appState.removeSession(session)
                }
            }
        }
    }

    private var statusText: String {
        switch session.connectionStatus {
        case .disconnected:
            return session.selectedDeviceUDID == nil
                ? String(localized: "Not configured")
                : String(localized: "Disconnected")
        case .connecting: return String(localized: "Connecting…")
        case .connected: return String(localized: "Connected")
        case .error(let message): return String(localized: "Error: \(message)")
        }
    }

    private var statusColor: Color {
        switch session.connectionStatus {
        case .connected: return .green
        case .error: return .orange
        default: return .secondary
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
    enum Action { case teleport, direct, route, wander, appendDirect, appendRoute, copy, cancel }

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

            Divider().frame(height: 14)

            Button {
                onAction(.copy)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderless)

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
    // Draw mode (hand-drawn routes): gates the freehand stroke gesture and drops
    // .pan from the map's interaction modes while active. The stroke is kept as
    // coordinates (converted at capture time, so it stays world-anchored) plus the
    // last raw screen point for jitter decimation.
    @State private var isDrawingRoute = false
    @State private var strokeCoords: [CLLocationCoordinate2D] = []
    @State private var lastStrokePoint: CGPoint?

    var body: some View {
        MapReader { proxy in
            // Drawing claims the drag for the stroke; zoom stays live (scroll/pinch
            // don't collide with a one-button drag), pan returns when drawing ends.
            Map(position: $cameraPosition, interactionModes: isDrawingRoute ? .zoom : .all) {
                // Every session's route + simulated dot, color-coded so multiple
                // devices are distinguishable on the shared map. The selected
                // session is emphasized (thicker line, larger dot+ring); its
                // planning markers (start/stop/end below) belong to it alone.
                ForEach(Array(appState.sessions.enumerated()), id: \.element.id) { index, session in
                    let color = AppState.sessionPalette[index % AppState.sessionPalette.count]
                    let isSelected = session.id == appState.selectedSessionID

                    if !session.routeCoordinates.isEmpty {
                        MapPolyline(coordinates: session.routeCoordinates)
                            .stroke(color.opacity(isSelected ? 1.0 : 0.7), lineWidth: isSelected ? 4 : 3)
                    }

                    if let coord = session.simState.simulatedCoordinate {
                        Annotation("", coordinate: coord) {
                            Circle()
                                .fill(color)
                                .frame(width: isSelected ? 16 : 12, height: isSelected ? 16 : 12)
                                .overlay(Circle().stroke(.white, lineWidth: isSelected ? 3 : 2))
                        }
                    }
                }

                if strokeCoords.count >= 2 {
                    MapPolyline(coordinates: strokeCoords)
                        .stroke(.orange, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [6, 4]))
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
            // Selecting a saved location/route frames it on the map (#53). A fresh
            // request id fires this even when the same item is picked twice. The
            // selection takes camera control, so any active follow disengages.
            .onChange(of: appState.mapFocus?.id) { _, newID in
                guard newID != nil, let region = appState.mapFocus?.region else { return }
                isFollowing = false
                withAnimation {
                    cameraPosition = .region(region)
                }
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
                        guard let coordinate = proxy.convert(drag.location, from: .local) else { return }

                        // First press: there's no origin yet, so a popover offering "Go directly"
                        // or "Route here" would have nothing to anchor from. Teleport instead
                        // (works whether or not a device is connected — it moves the red dot).
                        if appState.simState.simulatedCoordinate == nil {
                            appState.teleport(to: coordinate)
                        } else {
                            pendingDestination = coordinate
                        }
                    }
            )
            // Draw mode's gesture arbitration: while drawing, `.gesture` enables the
            // stroke drag and masks out the long-press wrapped above (a slow stroke
            // would otherwise trigger it); while not drawing, `.subviews` disables the
            // stroke gesture entirely so the map's normal interactions are untouched.
            .gesture(drawGesture(proxy: proxy), including: isDrawingRoute ? .gesture : .subviews)
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
            // Placed as a bottom-trailing safe-area inset rather than a plain overlay so
            // MapKit reflows its built-in zoom/compass controls (which it positions within
            // the map's safe area) up and clear of the joystick instead of letting the
            // joystick occlude them. The Map still draws full-bleed behind the inset, so the
            // joystick keeps floating over the map; when it's idle the inset collapses to
            // zero and the controls return to the corner.
            .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
                if appState.simState.joystickIsActive {
                    VirtualJoystickView { x, y in
                        appState.updateStickInput(x: x, y: y)
                    }
                    .padding(24)
                }
            }
            .focusable()
            .pointerStyle(isDrawingRoute ? .rectSelection : nil)
            .onKeyPress(.escape) {
                guard isDrawingRoute else { return .ignored }
                exitDrawMode()
                return .handled
            }
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

                        // Record, Follow, and Draw all act on the local red dot or
                        // route, not the device — Record captures the simulated path
                        // (offline too), Follow tracks the dot's camera, Draw builds a
                        // route — so all three show whether or not a device is connected.
                        RecordButton()
                        followButton
                        drawButton
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
                            case .copy:
                                // Leave the bar up so copy can precede another
                                // action on the same point.
                                appState.copyCoordinate(dest)
                                return
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

    private var drawButton: some View {
        Button {
            if isDrawingRoute {
                exitDrawMode()
            } else {
                isDrawingRoute = true
                // The camera must hold still under the stroke.
                isFollowing = false
            }
        } label: {
            Image(systemName: "pencil.line")
                .font(.callout)
                .foregroundStyle(isDrawingRoute ? Color.accentColor : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .help(isDrawingRoute ? "Stop drawing (Esc)" : "Draw a route by dragging on the map")
    }

    // Freehand stroke capture. Raw drag locations are decimated in screen space
    // (hand jitter lives there, and its meter size scales with zoom) and converted
    // to coordinates immediately, so the stroke stays world-anchored no matter
    // what the camera does afterwards.
    private func drawGesture(proxy: MapProxy) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if let last = lastStrokePoint {
                    let dx = value.location.x - last.x
                    let dy = value.location.y - last.y
                    guard dx * dx + dy * dy >= 9 else { return }  // < 3 pt: jitter
                }
                guard let coord = proxy.convert(value.location, from: .local) else { return }
                lastStrokePoint = value.location
                strokeCoords.append(coord)
            }
            .onEnded { _ in
                finishStroke()
            }
    }

    private func finishStroke() {
        defer {
            strokeCoords = []
            lastStrokePoint = nil
        }
        let spacing = StrokeGeometry.spacing(forSpeedMPS: appState.effectiveBaseSpeedMPS)
        guard let route = StrokeGeometry.resampleUniform(
            StrokeGeometry.chaikin(strokeCoords),
            spacingMeters: spacing
        ) else {
            // A stray click or jitter blob shouldn't kick the user out of draw mode.
            appState.addLog("Stroke too short to form a route — drag a longer line.")
            return
        }
        isDrawingRoute = false
        Task { await appState.loadDrawnRoute(route) }
    }

    private func exitDrawMode() {
        isDrawingRoute = false
        strokeCoords = []
        lastStrokePoint = nil
    }

    // Right-click destination menu: same actions as DestinationActionBar (the long-press
    // capsule), presented as a native context menu at the pointer — macOS convention, and
    // consistent with the sidebar rows' .contextMenu. Every action drives the local red dot
    // (the device mirrors it when connected), so none gate on connection; only origin-
    // dependent actions disable until a position exists.
    @ViewBuilder
    private func destinationMenu(proxy: MapProxy) -> some View {
        if !isDrawingRoute,
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

                Button {
                    appState.copyCoordinate(coordinate)
                } label: {
                    Label("Copy Coordinate", systemImage: "doc.on.doc")
                }
            }
        }
    }

    private var mapHintText: String {
        if isDrawingRoute {
            return String(localized: "Drag to draw a route — Esc to cancel")
        }
        switch appState.connectionStatus {
        case .connecting:
            return String(localized: "Connecting…")
        case .error:
            return String(localized: "Connection error — check sidebar")
        case .connected, .disconnected:
            // The map drives the local red dot whether or not a device is
            // attached; the status dot beside this text already shows the
            // connection. So the copy is about the simulation, only
            // distinguishing "mirrored to a device" (Simulating) from
            // "local only" (Local position).
            if appState.simState.navigationPlaybackState == .playing {
                let pct = Int(appState.simState.navigationProgress * 100)
                // Explicit format string keeps the lone % escaped as %%.
                return String(format: String(localized: "Playing route — %d%%"), pct)
            }
            if let coord = appState.simState.simulatedCoordinate {
                return appState.connectionStatus.isConnected
                    ? String(format: String(localized: "Simulating: %.4f, %.4f"), coord.latitude, coord.longitude)
                    : String(format: String(localized: "Local position: %.4f, %.4f"), coord.latitude, coord.longitude)
            }
            return String(localized: "Right-click the map to set a starting location")
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
