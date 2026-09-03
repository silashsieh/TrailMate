import CoreLocation
import Foundation
import Testing
@testable import TrailMate

@MainActor
struct RecordingLifecycleTests {
    @Test func concurrentActorsProduceDisjointFilesRegardlessOfStopOrder() async throws {
        let runtime = try IsolatedTestRuntime()
        defer { runtime.cleanup() }
        let library = RecordingsLibrary(baseURL: runtime.runtimePaths.recordingsDirectory)

        let aFirst = try await recordPair(stoppingAFirst: true, defaults: runtime.defaults)
        let bFirst = try await recordPair(stoppingAFirst: false, defaults: runtime.defaults)
        #expect(aFirst.a.points.map(\.latitude) == [10])
        #expect(aFirst.b.points.map(\.latitude) == [20, 21])
        #expect(bFirst.a.points.map(\.latitude) == [10, 11])
        #expect(bFirst.b.points.map(\.latitude) == [20])

        for pair in [aFirst, bFirst] {
            let persistedA = try library.persist(pair.a)
            let persistedB = try library.persist(pair.b)
            let urlA = try #require(persistedA)
            let urlB = try #require(persistedB)
            #expect(urlA != urlB)
        }

        #expect(library.recordings.count == 4)
        let pointSets = Set(library.recordings.map { $0.points.map(\.latitude) })
        #expect(pointSets == Set([[10], [20, 21], [10, 11], [20]]))
    }

    @Test func explicitStopPersistsAndCounterMatchesFile() async throws {
        let runtime = try IsolatedTestRuntime()
        defer { runtime.cleanup() }
        SimulatedPositionPersistence.setRestoreOnLaunch(false, in: runtime.defaults)
        let app = AppState(
            defaults: runtime.defaults,
            runtimePaths: runtime.runtimePaths,
            monotonicTime: ManualMonotonicClock().timeSource
        )
        let session = app.selectedSession

        session.toggleRecording()
        #expect(await eventually { await session.sim.recordingStatus().isActive })
        await session.sim.teleport(to: CLLocationCoordinate2D(latitude: 25.0, longitude: 121.0))
        await session.sim.teleport(to: CLLocationCoordinate2D(latitude: 25.1, longitude: 121.1))
        #expect(await session.sim.recordingStatus().pointCount == 2)

        session.toggleRecording()
        #expect(await eventually { app.recordingsLibrary.recordings.count == 1 })
        let recording = try #require(app.recordingsLibrary.recordings.first)
        #expect(recording.points.count == 2)
        #expect(recording.fileURL?.path.hasPrefix(runtime.runtimePaths.recordingsDirectory.path + "/") == true)
        #expect(await session.sim.recordingStatus() == .init(isActive: false, pointCount: 0))

        await app.prepareForQuit()
    }

    @Test func disconnectAndDetachRetainCaptureButShutdownDiscards() async throws {
        let runtime = try IsolatedTestRuntime()
        defer { runtime.cleanup() }
        SimulatedPositionPersistence.setRestoreOnLaunch(false, in: runtime.defaults)
        let app = AppState(defaults: runtime.defaults, runtimePaths: runtime.runtimePaths)
        let session = app.selectedSession
        session.bindConnectedForTesting(udid: "RECORDING-DEVICE")

        await session.sim.startRecording()
        await session.sim.teleport(to: CLLocationCoordinate2D(latitude: 1, longitude: 2))
        await session.disconnect()
        #expect(await session.sim.recordingStatus() == .init(isActive: true, pointCount: 1))

        await session.sim.detach()
        await session.sim.teleport(to: CLLocationCoordinate2D(latitude: 3, longitude: 4))
        #expect(await session.sim.recordingStatus() == .init(isActive: true, pointCount: 2))

        await session.shutdown()
        #expect(await session.sim.recordingStatus() == .init(isActive: false, pointCount: 0))
        #expect(await session.sim.stopRecording() == nil)
        #expect(app.recordingsLibrary.recordings.isEmpty)
        #expect(gpxFiles(under: runtime.runtimePaths.recordingsDirectory).isEmpty)
    }

    @Test func selectionHidesBackgroundCaptureAndRevealsItWhenReselected() async throws {
        let runtime = try IsolatedTestRuntime()
        defer { runtime.cleanup() }
        SimulatedPositionPersistence.setRestoreOnLaunch(false, in: runtime.defaults)
        let app = AppState(defaults: runtime.defaults, runtimePaths: runtime.runtimePaths)
        let a = app.selectedSession
        app.addSession()
        let b = app.selectedSession

        app.selectedSessionID = a.id
        await a.sim.startRecording()
        await a.sim.teleport(to: CLLocationCoordinate2D(latitude: 5, longitude: 6))
        #expect(await eventually { a.simState.isRecording && a.simState.recordingPointCount == 1 })
        #expect(app.simState === a.simState)
        #expect(app.simState.isRecording)

        app.selectedSessionID = b.id
        #expect(app.simState === b.simState)
        #expect(!app.simState.isRecording)
        #expect(app.simState.recordingPointCount == 0)
        #expect(await a.sim.recordingStatus() == .init(isActive: true, pointCount: 1))

        app.selectedSessionID = a.id
        #expect(app.simState.isRecording)
        #expect(app.simState.recordingPointCount == 1)

        await app.prepareForQuit()
    }

    @Test func sessionRemovalAndAppQuitDiscardWithoutPersisting() async throws {
        let runtime = try IsolatedTestRuntime()
        defer { runtime.cleanup() }
        SimulatedPositionPersistence.setRestoreOnLaunch(false, in: runtime.defaults)
        let app = AppState(defaults: runtime.defaults, runtimePaths: runtime.runtimePaths)
        let quitSession = app.selectedSession
        app.addSession()
        let removedSession = app.selectedSession

        await removedSession.sim.startRecording()
        await removedSession.sim.teleport(to: CLLocationCoordinate2D(latitude: 7, longitude: 8))
        app.removeSession(removedSession)
        #expect(await eventually {
            !(await removedSession.sim.recordingStatus()).isActive
        })

        await quitSession.sim.startRecording()
        await quitSession.sim.teleport(to: CLLocationCoordinate2D(latitude: 9, longitude: 10))
        await app.prepareForQuit()
        #expect(await quitSession.sim.recordingStatus() == .init(isActive: false, pointCount: 0))
        #expect(app.recordingsLibrary.recordings.isEmpty)
        #expect(gpxFiles(under: runtime.runtimePaths.recordingsDirectory).isEmpty)
    }

    private func recordPair(
        stoppingAFirst: Bool,
        defaults: UserDefaults
    ) async throws -> (a: RecordingCapture.Draft, b: RecordingCapture.Draft) {
        let clock = ManualMonotonicClock()
        let a = SimulationActor(
            bridge: SimulationStateBridge(defaults: defaults),
            monotonicTime: clock.timeSource,
            wallNow: { Date(timeIntervalSince1970: 1_750_000_000) }
        )
        let b = SimulationActor(
            bridge: SimulationStateBridge(defaults: defaults),
            monotonicTime: clock.timeSource,
            wallNow: { Date(timeIntervalSince1970: 1_750_000_100) }
        )
        await a.startRecording()
        await b.startRecording()
        await a.teleport(to: CLLocationCoordinate2D(latitude: 10, longitude: 110))
        await b.teleport(to: CLLocationCoordinate2D(latitude: 20, longitude: 120))

        let first: RecordingCapture.Draft
        let second: RecordingCapture.Draft
        if stoppingAFirst {
            first = try #require(await a.stopRecording())
            await b.teleport(to: CLLocationCoordinate2D(latitude: 21, longitude: 121))
            second = try #require(await b.stopRecording())
            return (a: first, b: second)
        } else {
            first = try #require(await b.stopRecording())
            await a.teleport(to: CLLocationCoordinate2D(latitude: 11, longitude: 111))
            second = try #require(await a.stopRecording())
            return (a: second, b: first)
        }
    }

    private func eventually(
        _ predicate: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        for _ in 0..<1_000 {
            if await predicate() { return true }
            await Task.yield()
        }
        return await predicate()
    }

    private func gpxFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "gpx" }
    }
}
