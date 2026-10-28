import Foundation
import Testing
@testable import TrailMate

@MainActor
struct AppRuntimePathsTests {
    @Test func livePathsPreserveLegacyApplicationSupportLayout() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let root = support.appendingPathComponent("TrailMate", isDirectory: true).standardizedFileURL
        let paths = AppRuntimePaths.live

        #expect(paths.rootDirectory == root)
        #expect(paths.savedRoutesDirectory == root.appendingPathComponent("routes", isDirectory: true))
        #expect(paths.recordingsDirectory == root.appendingPathComponent("recordings", isDirectory: true))
        #expect(paths.tunnelControlDirectory == root.appendingPathComponent("tunnels", isDirectory: true))
        #expect(paths.aiSocketURL == root.appendingPathComponent("ai.sock", isDirectory: false))
        #expect(SavedRoutesStore.baseURL == paths.savedRoutesDirectory)
        #expect(RecordingsLibrary.baseURL == paths.recordingsDirectory)
    }

    @Test func appHostedTestProcessUsesAnIsolatedConfiguration() {
        let configuration = AppProcessConfiguration.current

        #expect(configuration.runtimePaths != .live)
        let rootPath = configuration.runtimePaths.rootDirectory.path
        #expect(rootPath.hasPrefix("/tmp/") || rootPath.hasPrefix("/private/tmp/"))
        #expect(configuration.defaults !== UserDefaults.standard)
    }

    @Test func isolatedAppStateUsesOnlyExplicitRootAndDefaults() async throws {
        let runtime = try IsolatedTestRuntime()
        defer { runtime.cleanup() }
        SimulatedPositionPersistence.setRestoreOnLaunch(false, in: runtime.defaults)
        runtime.defaults.set(37.0, forKey: "customSpeedKmh")

        let app = AppState(defaults: runtime.defaults, runtimePaths: runtime.runtimePaths)

        #expect(app.defaults === runtime.defaults)
        #expect(app.runtimePaths == runtime.runtimePaths)
        #expect(app.recordingsLibrary.baseURL == runtime.runtimePaths.recordingsDirectory)
        #expect(app.savedRoutes.baseURL == runtime.runtimePaths.savedRoutesDirectory)
        #expect(app.tunnelBroker.controlDirectory == runtime.runtimePaths.tunnelControlDirectory)
        #expect(app.customSpeedKmh == 37.0)
        #expect(FileManager.default.fileExists(atPath: runtime.runtimePaths.recordingsDirectory.path))
        #expect(FileManager.default.fileExists(atPath: runtime.runtimePaths.savedRoutesDirectory.path))
        #expect(!FileManager.default.fileExists(atPath: runtime.runtimePaths.aiSocketURL.path))

        await app.prepareForQuit()
    }

    @Test func isolatedDefaultsDoNotReadOrWriteStandardDomain() throws {
        let runtime = try IsolatedTestRuntime()
        defer { runtime.cleanup() }
        let key = "WP1.Isolation.\(UUID().uuidString)"

        #expect(UserDefaults.standard.object(forKey: key) == nil)
        runtime.defaults.set("isolated", forKey: key)
        #expect(runtime.defaults.string(forKey: key) == "isolated")
        #expect(UserDefaults.standard.object(forKey: key) == nil)
    }
}
