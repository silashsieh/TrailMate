import Foundation
@testable import TrailMate

@MainActor
final class IsolatedTestRuntime {
    let rootDirectory: URL
    let runtimePaths: AppRuntimePaths
    let defaultsSuiteName: String
    let defaults: UserDefaults

    init() throws {
        let identifier = UUID().uuidString
        rootDirectory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("TrailMate-Tests-\(identifier)", isDirectory: true)
        runtimePaths = AppRuntimePaths(rootDirectory: rootDirectory)
        defaultsSuiteName = "com.sh.TrailMate.Tests.\(identifier)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try FileManager.default.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    func cleanup() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: rootDirectory)
    }
}
