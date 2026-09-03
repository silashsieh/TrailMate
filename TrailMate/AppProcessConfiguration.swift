import Foundation

// Process-wide composition selected before SwiftUI builds any property wrapper.
// Production always uses the standard defaults domain and legacy live paths;
// DEBUG test hosts receive one immutable isolated domain/root for their process.
nonisolated struct AppProcessConfiguration: @unchecked Sendable {
    let defaults: UserDefaults
    let runtimePaths: AppRuntimePaths

    static let current: AppProcessConfiguration = {
        #if DEBUG
        if UITestSupport.isTesting {
            return AppProcessConfiguration(
                defaults: UITestSupport.defaults,
                runtimePaths: UITestSupport.runtimePaths
            )
        }
        #endif
        return AppProcessConfiguration(defaults: .standard, runtimePaths: .live)
    }()
}
