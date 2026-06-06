import CoreLocation
import Foundation
import GameController

// Sendable snapshot the actor pushes to SimulationStateBridge after each tick
// that changes UI-visible state. Built on the actor; applied on MainActor.
struct SimSnapshot: Sendable {
    var simulatedCoordinate: CLLocationCoordinate2D?
    var navigationPlaybackState: NavigationEngine.PlaybackState
    var navigationProgress: Double
    var navigationElapsedDistance: Double
    var navigationTotalDistance: Double
    var navigationCompletedLoops: Int
    var joystickIsActive: Bool
    var joystickControllerName: String?
    var routeDeviationMeters: Double
    var recordingPointCount: Int
    var isRecording: Bool
}

// Events the actor emits back to MainActor for side effects it can't perform
// itself — currently only "route aborted" so AppState can write a log line.
enum SimulationEvent: Sendable {
    case routeAborted(distanceMeters: Double, durationSeconds: Double)
}

// Owns the simulation engines, the 20 Hz aggregator loop, the idle-jitter
// task, the deviation check, the 2 Hz UI throttle, and the App Nap activity
// token. Decoupled from MainActor so SwiftUI hitches don't stall SETQ
// delivery. Engines are nonisolated stored properties — no per-tick await
// hop into separate isolation domains.
actor SimulationActor {
    private let bridge: SimulationStateBridge
    private let recorderRef: RecorderService

    private let nav = NavigationEngine()
    private let joy = JoystickEngine()
    private let integrator = PositionIntegrator()
    private let noise = LocationNoise()

    private var backend: (any SimulationBackend)?
    private var aggregatorTask: Task<Void, Never>?
    private var idleJitterTask: Task<Void, Never>?
    private var controllerObservers: [NSObjectProtocol] = []
    private var activityToken: Any?

    private var lastDisplayPush: ContinuousClock.Instant?
    private var lastDeviationCheck: ContinuousClock.Instant?
    private var deviationStartedAt: ContinuousClock.Instant?

    private var lastEmittedCoordinate: CLLocationCoordinate2D?

    // Pending point count + recording flag — owned here so the snapshot push
    // doesn't need to read RecorderService across actor boundaries.
    private var isRecordingActive = false
    private var pendingPointCount = 0

    private static let deviationAbortMeters: Double = 200
    private static let deviationAbortSeconds: TimeInterval = 10

    // Events stream out to AppState (route abort log line).
    nonisolated let events: AsyncStream<SimulationEvent>
    nonisolated private let eventsContinuation: AsyncStream<SimulationEvent>.Continuation

    init(bridge: SimulationStateBridge, recorder: RecorderService) {
        self.bridge = bridge
        self.recorderRef = recorder
        var continuation: AsyncStream<SimulationEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.eventsContinuation = continuation
    }

    deinit {
        eventsContinuation.finish()
    }

    // MARK: - Lifecycle

    func attach(backend: any SimulationBackend) async {
        self.backend = backend

        // A restored (pre-connect) position has been display-only until now —
        // detach() nils lastEmittedCoordinate, so this only fires for a launch
        // restore. Broadcasting it here, before startJoystick anchors to it,
        // is what turns "display default" into the device's actual location.
        if let restored = lastEmittedCoordinate {
            emit(restored)
        }

        // App Nap mitigation — keep the simulation loop ticking when TrailMate
        // is backgrounded. Released in detach().
        if activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: .userInitiated,
                reason: "TrailMate simulation loop"
            )
        }

        // GCController observers — when a hardware controller (dis)connects we
        // update joy.connectedControllerName on the actor and refresh the
        // bridge. Posted on the main queue; we hop into the actor.
        await setupControllerObservers()

        startAggregator()
        startIdleJitter()
    }

    func detach() async {
        aggregatorTask?.cancel(); aggregatorTask = nil
        idleJitterTask?.cancel(); idleJitterTask = nil
        for obs in controllerObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        controllerObservers.removeAll()
        nav.stop()
        joy.stop()
        integrator.clear()
        lastEmittedCoordinate = nil
        lastDisplayPush = nil
        deviationStartedAt = nil
        isScrubbing = false
        backend = nil
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token as! NSObjectProtocol)
            activityToken = nil
        }
        await pushSnapshotNow()
    }

    // MARK: - Configuration

    func updateBaseSpeed(_ mps: Double) {
        nav.updateBaseSpeed(mps)
        joy.updateBaseSpeed(mps)
    }

    func updateNoiseSigma(_ sigma: Double) {
        noise.sigmaMeters = sigma
    }

    func updateLoop(mode: NavigationEngine.LoopMode, count: Int) {
        nav.updateLoop(mode: mode, count: count)
    }

    // MARK: - Route

    func loadRoute(coordinates: [CLLocationCoordinate2D], baseSpeed: Double, resetStart: Bool) async {
        isScrubbing = false
        nav.loadRoute(coordinates: coordinates, baseSpeed: baseSpeed)
        if resetStart, let first = coordinates.first {
            integrator.reset(to: first)
            lastEmittedCoordinate = first
        }
        await pushSnapshotNow()
    }

    func play(multiplier: Double) async {
        // Starting fresh (idle, not resuming a pause) snaps the integrator to
        // the engine's start point — the route start on a re-arm, or the
        // sought point when a scrub on the idle route armed a pending seek.
        // After a completed pass the integrator is parked at the far end, and
        // ticking segment-0 velocity from there would trace a route-shaped
        // ghost path offset from the polyline. Covers the unseeded (nil
        // position) case too.
        let startingFresh = nav.playbackState == .idle
        nav.play(multiplier: multiplier)
        if startingFresh, let startPoint = nav.expectedPosition {
            integrator.reset(to: startPoint)
        }
        await pushSnapshotNow()
    }

    func pause() async {
        nav.pause()
        await pushSnapshotNow()
    }

    func resume(multiplier: Double) async {
        nav.resume(multiplier: multiplier)
        await pushSnapshotNow()
    }

    func stopPlayback() async {
        nav.stop()
        lastEmittedCoordinate = nil
        deviationStartedAt = nil
        isScrubbing = false
        await pushSnapshotNow()
    }

    func rejoinRoute() async {
        guard let expected = nav.expectedPosition else { return }
        integrator.reset(to: expected)
        deviationStartedAt = nil
        emit(expected)
        await pushSnapshotNow()
    }

    // MARK: - Timeline scrub

    // True while the user is dragging the playback scrubber. Gates nav.tick in
    // the aggregator so the route doesn't slide under the thumb — without
    // touching playbackState, so release resumes exactly the prior state.
    // Transport actions (stop/load/teleport/clear) clear it so a lost release
    // event can't freeze playback.
    private var isScrubbing = false
    private var lastScrubEmit: ContinuousClock.Instant?

    func beginScrub() {
        isScrubbing = true
        lastScrubEmit = nil
    }

    // Live-follow scrub (epic 011 decision): the device receives scrub
    // positions as the user drags, not just the release point. Drag events
    // arrive at display rate, so emits + UI pushes are throttled to the 20 Hz
    // hot-path cadence; the playhead itself moves on every call. The
    // release-time seek(toProgress:) is authoritative, so dropping a stale
    // in-flight scrub here is harmless.
    func scrub(toProgress progress: Double) async {
        guard isScrubbing else { return }   // stale task landing after release
        guard let coord = applySeek(progress: progress) else { return }
        let now = ContinuousClock.now
        if let last = lastScrubEmit, now - last < .milliseconds(50) { return }
        lastScrubEmit = now
        emit(coord)
        await pushSnapshotNow(routeDeviationMeters: 0)
    }

    // Final, authoritative seek — scrub release and discrete jumps (track
    // click, keyboard arrows). Leaves playbackState as-is: a playing route
    // continues from the sought point on the next tick; paused/idle stay put
    // until Play/Resume, which both pick up from the moved playhead.
    func seek(toProgress progress: Double) async {
        isScrubbing = false
        guard let coord = applySeek(progress: progress) else { return }
        emit(coord)
        await pushSnapshotNow(routeDeviationMeters: 0)
    }

    // Releases a scrub whose value never changed (plain click, no drag).
    func endScrub() {
        isScrubbing = false
    }

    private func applySeek(progress: Double) -> CLLocationCoordinate2D? {
        guard let coord = nav.seek(toProgress: progress) else { return nil }
        integrator.reset(to: coord)
        deviationStartedAt = nil
        return coord
    }

    // MARK: - Joystick

    func startJoystick(baseSpeed: Double) async {
        // With no position yet, the engine is armed but inert — the aggregator's
        // `guard let pos = integrator.position` short-circuits until the first
        // teleport seeds it. Nothing is sent to the device.
        joy.start(baseSpeed: baseSpeed)
        await pushSnapshotNow()
    }

    func stopJoystick() async {
        joy.stop()
        await pushSnapshotNow()
    }

    func updateStickInput(x: Float, y: Float) {
        joy.updateStickInput(x: x, y: y)
    }

    func pressDirection(_ direction: JoystickEngine.Direction) {
        joy.pressDirection(direction)
    }

    func releaseDirection(_ direction: JoystickEngine.Direction) {
        joy.releaseDirection(direction)
    }

    var isJoystickActive: Bool { joy.isActive }
    var isPlaybackIdle: Bool { nav.playbackState == .idle }

    // The integrator's authoritative position. The bridge's simulatedCoordinate
    // lags until the next emit, so tests asserting on play()'s integrator
    // reset need the direct read.
    var integratorPosition: CLLocationCoordinate2D? { integrator.position }

    // MARK: - Teleport / clear

    func teleport(to coordinate: CLLocationCoordinate2D) async {
        // A teleport is an explicit jump — preempt route playback so the marker
        // doesn't snap back on the next tick.
        if nav.playbackState != .idle {
            nav.stop()
        }
        integrator.reset(to: coordinate)
        isScrubbing = false
        emit(coordinate)
        await pushSnapshotNow()
    }

    // Sets the displayed coordinate to nil and stops nav. Used after clearLocation
    // (the daemon-side CLEAR command lives in AppState because the backend
    // sendCommand belongs to it).
    func clearForLocationCleared() async {
        nav.stop()
        lastEmittedCoordinate = nil
        deviationStartedAt = nil
        isScrubbing = false
        await pushSnapshotNow()
    }

    // MARK: - Recording

    func startRecording() async {
        guard !isRecordingActive else { return }
        isRecordingActive = true
        pendingPointCount = 0
        let recorder = recorderRef
        await MainActor.run { recorder.start() }
        await pushSnapshotNow()
    }

    func stopRecording() async throws -> URL? {
        guard isRecordingActive else { return nil }
        isRecordingActive = false
        pendingPointCount = 0
        let recorder = recorderRef
        let url = try await MainActor.run { try recorder.stop() }
        await pushSnapshotNow()
        return url
    }

    // MARK: - Loops

    private func startAggregator() {
        aggregatorTask?.cancel()
        aggregatorTask = Task { [weak self] in
            let dt: TimeInterval = 0.05
            var nextTick = ContinuousClock.now
            while !Task.isCancelled {
                nextTick = nextTick.advanced(by: .milliseconds(50))
                try? await Task.sleep(until: nextTick, clock: .continuous)
                await self?.aggregatorTick(dt: dt)
            }
        }
    }

    private func startIdleJitter() {
        idleJitterTask?.cancel()
        idleJitterTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await self?.idleJitterTick()
            }
        }
    }

    private func idleJitterTick() {
        guard nav.playbackState != .playing,
              !joy.isActive,
              let coord = lastEmittedCoordinate else { return }
        emit(coord)
    }

    private func aggregatorTick(dt: TimeInterval) async {
        var vx = 0.0, vy = 0.0
        var anyContribution = false

        if !isScrubbing, let nv = nav.tick(dt: dt) {
            // A restart-loop wrap is a deliberate teleport back to the route
            // start; the engine returns zero velocity on that tick.
            if let jump = nv.jump {
                integrator.reset(to: jump)
            }
            vx += nv.vx; vy += nv.vy
            anyContribution = true
        }
        if let jv = joy.tick() {
            vx += jv.vx; vy += jv.vy
            anyContribution = true
        }

        guard anyContribution else {
            // Engines inactive — reset deviation tracking and push state only
            // if it just changed (caller doesn't need 20 Hz no-op snapshots).
            if bridge_routeDeviationMeters != 0 || deviationStartedAt != nil {
                deviationStartedAt = nil
                await pushSnapshotNow(routeDeviationMeters: 0)
            }
            return
        }

        integrator.step(vx: vx, vy: vy, dt: dt)
        guard let pos = integrator.position else { return }
        emit(pos)

        if nav.playbackState == .playing {
            await maybeCheckDeviation(pos: pos)
        } else {
            // Joystick-only (no route playing) still needs the bridge updated
            // so SwiftUI sees the moving coordinate. Without this push, emit()
            // keeps streaming SETQ to the device but simulatedCoordinate on
            // the bridge stays frozen on whatever startJoystick last pushed.
            deviationStartedAt = nil
            await pushSnapshot(routeDeviationMeters: 0)
        }
    }

    private func maybeCheckDeviation(pos: CLLocationCoordinate2D) async {
        let now = ContinuousClock.now
        if let last = lastDeviationCheck, now - last < .milliseconds(200) {
            return
        }
        lastDeviationCheck = now
        let dev = nav.distanceFromRoute(pos)
        if dev > Self.deviationAbortMeters {
            if deviationStartedAt == nil {
                deviationStartedAt = now
            }
            if let started = deviationStartedAt,
               now - started > .seconds(Self.deviationAbortSeconds) {
                nav.stop()
                deviationStartedAt = nil
                eventsContinuation.yield(.routeAborted(
                    distanceMeters: Self.deviationAbortMeters,
                    durationSeconds: Self.deviationAbortSeconds
                ))
            }
        } else {
            deviationStartedAt = nil
        }
        await pushSnapshot(routeDeviationMeters: dev)
    }

    // MARK: - Emit + bridge

    // Snapshot writes the engines' state at the time of push, but
    // routeDeviationMeters is only updated by maybeCheckDeviation. Cache the
    // last-known value here so the snapshot push can carry it without
    // re-reading.
    private var bridge_routeDeviationMeters: Double = 0

    private func emit(_ clean: CLLocationCoordinate2D) {
        lastEmittedCoordinate = clean
        let noisy = noise.apply(to: clean)
        backend?.setLocationQuiet(latitude: noisy.latitude, longitude: noisy.longitude)
        if isRecordingActive {
            pendingPointCount &+= 1
            let recorder = recorderRef
            Task { @MainActor in recorder.append(clean) }
        }
    }

    private func makeSnapshot(routeDeviationMeters: Double) -> SimSnapshot {
        SimSnapshot(
            simulatedCoordinate: lastEmittedCoordinate,
            navigationPlaybackState: nav.playbackState,
            navigationProgress: nav.progress,
            navigationElapsedDistance: nav.elapsedDistance,
            navigationTotalDistance: nav.totalDistance,
            navigationCompletedLoops: nav.completedLoops,
            joystickIsActive: joy.isActive,
            joystickControllerName: joy.connectedControllerName,
            routeDeviationMeters: routeDeviationMeters,
            recordingPointCount: pendingPointCount,
            isRecording: isRecordingActive
        )
    }

    // Throttled push for the hot path. The 2 Hz cadence is what keeps MapArea
    // from rebuilding the route MapPolyline at 20 Hz; the backend still gets
    // every SETQ tick because backend.setLocationQuiet is called from `emit`,
    // not from here.
    private func pushSnapshotThrottled(routeDeviationMeters: Double) async {
        let now = ContinuousClock.now
        let shouldPush: Bool
        if nav.playbackState == .playing {
            shouldPush = lastDisplayPush.map { now - $0 >= .milliseconds(500) } ?? true
        } else {
            shouldPush = true
        }
        guard shouldPush else { return }
        lastDisplayPush = now
        bridge_routeDeviationMeters = routeDeviationMeters
        let snap = makeSnapshot(routeDeviationMeters: routeDeviationMeters)
        let bridge = self.bridge
        Task { @MainActor in bridge.apply(snap) }
    }

    // Unthrottled push for state transitions (start/stop/pause/teleport/etc.).
    private func pushSnapshotNow(routeDeviationMeters: Double? = nil) async {
        let dev = routeDeviationMeters ?? bridge_routeDeviationMeters
        bridge_routeDeviationMeters = dev
        lastDisplayPush = ContinuousClock.now
        let snap = makeSnapshot(routeDeviationMeters: dev)
        let bridge = self.bridge
        Task { @MainActor in bridge.apply(snap) }
    }

    // Throttled push variant used inside the aggregator loop.
    private func pushSnapshot(routeDeviationMeters: Double) async {
        await pushSnapshotThrottled(routeDeviationMeters: routeDeviationMeters)
    }

    // MARK: - GCController observers

    private func setupControllerObservers() async {
        // Initial value: GCController.controllers() is MainActor-isolated in
        // recent SDKs, so fetch it once via a hop.
        let initialName = await MainActor.run {
            GCController.controllers().first?.vendorName
        }
        joy.connectedControllerName = initialName

        let connectObs = NotificationCenter.default.addObserver(
            forName: .GCControllerDidConnect,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            let name = controller.vendorName ?? "Controller"
            Task { await self?.didChangeController(name: name) }
        }
        let disconnectObs = NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Fetch the remaining controller's name on main, then hop in.
            Task {
                let name = await MainActor.run {
                    GCController.controllers().first?.vendorName
                }
                await self?.didChangeController(name: name)
            }
        }
        controllerObservers.append(connectObs)
        controllerObservers.append(disconnectObs)
        await pushSnapshotNow()
    }

    private func didChangeController(name: String?) async {
        joy.connectedControllerName = name
        await pushSnapshotNow()
    }
}

// MARK: - MainActor side: snapshot apply

@MainActor extension SimulationStateBridge {
    func apply(_ snap: SimSnapshot) {
        simulatedCoordinate = snap.simulatedCoordinate
        persistPositionThrottled()
        navigationPlaybackState = snap.navigationPlaybackState
        navigationProgress = snap.navigationProgress
        navigationElapsedDistance = snap.navigationElapsedDistance
        navigationTotalDistance = snap.navigationTotalDistance
        navigationCompletedLoops = snap.navigationCompletedLoops
        joystickIsActive = snap.joystickIsActive
        joystickControllerName = snap.joystickControllerName
        routeDeviationMeters = snap.routeDeviationMeters
        recordingPointCount = snap.recordingPointCount
        isRecording = snap.isRecording
    }
}
