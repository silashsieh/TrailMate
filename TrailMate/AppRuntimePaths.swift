import Foundation

// Every app-owned filesystem location that tests must be able to redirect as
// one unit. The root is TrailMate's Application Support directory in a live
// process and an explicit temporary directory in tests.
nonisolated struct AppRuntimePaths: Equatable, Sendable {
    let rootDirectory: URL
    let savedRoutesDirectory: URL
    let recordingsDirectory: URL
    let tunnelControlDirectory: URL
    let aiSocketURL: URL

    init(rootDirectory: URL) {
        let root = rootDirectory.standardizedFileURL
        self.rootDirectory = root
        self.savedRoutesDirectory = root.appendingPathComponent("routes", isDirectory: true)
        self.recordingsDirectory = root.appendingPathComponent("recordings", isDirectory: true)
        self.tunnelControlDirectory = root.appendingPathComponent("tunnels", isDirectory: true)
        self.aiSocketURL = root.appendingPathComponent("ai.sock", isDirectory: false)
    }

    static var live: AppRuntimePaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return AppRuntimePaths(rootDirectory: support.appendingPathComponent("TrailMate", isDirectory: true))
    }
}
