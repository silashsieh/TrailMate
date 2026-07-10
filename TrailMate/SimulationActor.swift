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

nonisolated struct SimulationTiming: Sendable {
    let aggregatorDeltaTime: TimeInterval
    let aggregatorInterval: Duration
    let scrubEmitInterval: Duration
    let playbackSnapshotInterval: Duration
    let activeSnapshotInterval: Duration

    static let production = SimulationTiming(
        aggregatorDeltaTime: 0.1,
        aggregatorInterval: .milliseconds(100),
        scrubEmitInterval: .milliseconds(100),
        playbackSnapshotInterval: .milliseconds(500),
        activeSnapshotInterval: .milliseconds(100)
    )
}

// Owns the simulation engines, the 10 Hz aggregator loop, the idle-jitter
// task, the deviation check, the UI throttles, and the App Nap activity
// token. Decoupled from MainActor so SwiftUI hitches don't stall SETQ
// delivery. Engines are nonisolated stored properties — no per-tick await
// hop into separate isolation domains.
actor SimulationActor {
    private let bridge: SimulationStateBridge
    private let recorderRef: RecorderService
    private let timing: SimulationTiming

    private let nav = NavigationEngine()
    private let joy = JoystickEngine()
    private let integrator = PositionIntegrator()
    private let noise = LocationNoise()

    private var backend: (any SimulationBackend)?
    private var engineRunning = false
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

    // The high-frequency telemetry plane (epic 041): the clean position and its
    // route-relative derivatives, yielded wherever a snapshot is pushed today.
    // Latest-wins (bufferingNewest(1)) so a slow consumer always reads the
    // freshest frame and never a backlog. Dual-published alongside the bridge
    // snapshot — the old path stays authoritative until 037 moves the map onto
    // this plane — so this stream carries no behavior of its own yet.
    nonisolated let telemetry: AsyncStream<TelemetryFrame>
    nonisolated private let telemetryContinuation: AsyncStream<TelemetryFrame>.Continuation

    init(bridge: SimulationStateBridge, recorder: RecorderService, timing: SimulationTiming = .production) {
        self.bridge = bridge
        self.recorderRef = recorder
        self.timing = timing
        var continuation: AsyncStream<SimulationEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.eventsContinuation = continuation
        var telemetryCont: AsyncStream<TelemetryFrame>.Continuation!
        self.telemetry = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { telemetryCont = $0 }
        self.telemetryContinuation = telemetryCont
    }

    deinit {
        eventsContinuation.finish()
        telemetryContinuation.finish()
    }

    // MARK: - Lifecycle

    // Starts the local simulation engine: the GCController observers and the
    // aggregator + idle-jitter loops. The simulated position is a live local
    // state that exists with or without a device — these loops run for the
    // session's whole lifetime so teleport / route playback / joystick drive the
    // red dot even while disconnected. A backend, once attached, just mirrors it.
    // Idempotent; torn down by stopEngine() (session removal / quit), not detach().
    func startEngine() async {
        guard !engineRunning else { return }
        engineRunning = true
        // GCController observers — when a hardware controller (dis)connects we
        // update joy.connectedControllerName on the actor and refresh the bridge.
        await setupControllerObservers()
        startAggregator()
        startIdleJitter()
    }

    // Full teardown for session removal / app quit. Unlike detach(), which only
    // drops the device mirror, this stops the loops and clears the local position.
    func stopEngine() async {
        engineRunning = false
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
        // Engine is down for good (session removal / quit) — no more frames will
        // be produced, so end the telemetry stream after the final push so its
        // consumers see the cleared state and then a clean completion.
        telemetryContinuation.finish()
    }

    // Attach a device backend — the output sink the loops mirror to. Snaps the
    // device to the current red dot immediately: this is "the device follows the
    // red dot on connect", whether that dot came from a launch restore or from
    // offline control. Takes the App Nap token so the mirror keeps streaming when
    // TrailMate is backgrounded (released in detach()). The loops are already
    // running (startEngine), so connecting never restarts the simulation.
    func attach(backend: any SimulationBackend) async {
        self.backend = backend
        if let current = lastEmittedCoordinate {
            emit(current)
        }
        if activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: .userInitiated,
                reason: "TrailMate simulation loop"
            )
        }
        await pushSnapshotNow()
    }

    // Drop the device mirror but keep simulating locally — the red dot stays put
    // and controllable, so reconnecting re-syncs the device to wherever it ended
    // up. Releases the App Nap token (no device to keep alive while disconnected).
    func detach() async {
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
    // arrive at display rate, so emits + UI pushes are throttled to the 10 Hz
    // hot-path cadence; the playhead itself moves on every call. The
    // release-time seek(toProgress:) is authoritative, so dropping a stale
    // in-flight scrub here is harmless.
    func scrub(toProgress progress: Double) async {
        guard isScrubbing else { return }   // stale task landing after release
        guard let coord = applySeek(progress: progress) else { return }
        let now = ContinuousClock.now
        if let last = lastScrubEmit, now - last < timing.scrubEmitInterval { return }
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
        let timing = self.timing
        aggregatorTask = Task { [weak self, timing] in
            let dt = timing.aggregatorDeltaTime
            let interval = timing.aggregatorInterval
            var nextTick = ContinuousClock.now
            while !Task.isCancelled {
                nextTick = nextTick.advanced(by: interval)
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
        // Only jitter while mirroring a real device — the 1 Hz re-emit exists to
        // keep fresh noisy points flowing to the device while idle. With no
        // backend it would just drift the displayed (and persisted) red dot for
        // no one, so the offline preview stays perfectly still until driven.
        guard backend != nil,
              nav.playbackState != .playing,
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
            // if it just changed (caller doesn't need 10 Hz no-op snapshots).
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

    // Telemetry frame carrying the high-frequency subset of the snapshot.
    // Derived from the same snapshot so the two planes never disagree about the
    // position they publish for one push.
    private func makeTelemetryFrame(from snap: SimSnapshot) -> TelemetryFrame {
        TelemetryFrame(
            coordinate: snap.simulatedCoordinate,
            progress: snap.navigationProgress,
            elapsedDistance: snap.navigationElapsedDistance,
            routeDeviationMeters: snap.routeDeviationMeters,
            recordingPointCount: snap.recordingPointCount
        )
    }

    // Throttled push for the hot path. Playback remains at 2 Hz to keep
    // MapArea from rebuilding the route MapPolyline on every tick; active
    // non-playing motion is capped at 10 Hz. The backend still gets every SETQ
    // tick because backend.setLocationQuiet is called from `emit`, not here.
    private func pushSnapshotThrottled(routeDeviationMeters: Double) async {
        let now = ContinuousClock.now
        let interval = nav.playbackState == .playing
            ? timing.playbackSnapshotInterval
            : timing.activeSnapshotInterval
        let shouldPush = lastDisplayPush.map { now - $0 >= interval } ?? true
        guard shouldPush else { return }
        lastDisplayPush = now
        bridge_routeDeviationMeters = routeDeviationMeters
        let snap = makeSnapshot(routeDeviationMeters: routeDeviationMeters)
        // Dual-publish: telemetry plane first (latest-wins, no view body), then
        // the structural bridge snapshot on MainActor — same cadence as the
        // bridge push so the throttle bounds both planes identically.
        telemetryContinuation.yield(makeTelemetryFrame(from: snap))
        let bridge = self.bridge
        Task { @MainActor in bridge.apply(snap) }
    }

    // Unthrottled push for state transitions (start/stop/pause/teleport/etc.).
    private func pushSnapshotNow(routeDeviationMeters: Double? = nil) async {
        let dev = routeDeviationMeters ?? bridge_routeDeviationMeters
        bridge_routeDeviationMeters = dev
        lastDisplayPush = ContinuousClock.now
        let snap = makeSnapshot(routeDeviationMeters: dev)
        telemetryContinuation.yield(makeTelemetryFrame(from: snap))
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
    // Change-guarded per field (epic 041): write a property only when the new
    // value actually differs. Observation does not dedupe same-value writes, so
    // an unguarded 2–10 Hz push would re-invalidate every observing view every
    // tick even when nothing it reads changed. CLLocationCoordinate2D is not
    // Equatable, so its guard compares lat/lon. persistPositionThrottled still
    // runs on every apply (it has its own 1 Hz throttle) so persistence cadence
    // is unchanged whether or not the coordinate write was skipped.
    func apply(_ snap: SimSnapshot) {
        if !Self.coordinatesEqual(simulatedCoordinate, snap.simulatedCoordinate) {
            simulatedCoordinate = snap.simulatedCoordinate
        }
        persistPositionThrottled()
        if navigationPlaybackState != snap.navigationPlaybackState {
            navigationPlaybackState = snap.navigationPlaybackState
        }
        if navigationProgress != snap.navigationProgress {
            navigationProgress = snap.navigationProgress
        }
        if navigationElapsedDistance != snap.navigationElapsedDistance {
            navigationElapsedDistance = snap.navigationElapsedDistance
        }
        if navigationTotalDistance != snap.navigationTotalDistance {
            navigationTotalDistance = snap.navigationTotalDistance
        }
        if navigationCompletedLoops != snap.navigationCompletedLoops {
            navigationCompletedLoops = snap.navigationCompletedLoops
        }
        if joystickIsActive != snap.joystickIsActive {
            joystickIsActive = snap.joystickIsActive
        }
        if joystickControllerName != snap.joystickControllerName {
            joystickControllerName = snap.joystickControllerName
        }
        if routeDeviationMeters != snap.routeDeviationMeters {
            routeDeviationMeters = snap.routeDeviationMeters
        }
        if recordingPointCount != snap.recordingPointCount {
            recordingPointCount = snap.recordingPointCount
        }
        if isRecording != snap.isRecording {
            isRecording = snap.isRecording
        }
    }

    private static func coordinatesEqual(
        _ lhs: CLLocationCoordinate2D?,
        _ rhs: CLLocationCoordinate2D?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?): return l.latitude == r.latitude && l.longitude == r.longitude
        default: return false
        }
    }
}
