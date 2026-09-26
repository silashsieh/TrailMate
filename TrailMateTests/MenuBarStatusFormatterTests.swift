import Testing
@testable import TrailMate

@MainActor
struct MenuBarStatusFormatterTests {
    @Test func selectedDeviceAndActivityFollowConnectionAndPlayback() {
        let name = "A very long iPhone device name"
        #expect(summary(name: name, status: .connected, playback: .playing, progress: 0.426, recording: true)
            == "A very long iPhone dev… · Connected · Playing 43%")
        #expect(summary(name: "Alpha", status: .connected, playback: .paused, recording: true)
            == "Alpha · Connected · Paused")
        #expect(summary(name: "Beta", status: .connected, recording: true)
            == "Beta · Connected · Recording")
        #expect(summary(name: "Beta", status: .connected)
            == "Beta · Connected · Idle")
    }

    @Test func staleNameNeverAppearsDuringLossOrRecovery() {
        #expect(summary(name: "Alpha", status: .disconnected) == "Disconnected · Idle")
        #expect(summary(name: "Alpha", status: .connecting) == "Connecting… · Idle")
        #expect(summary(name: "Alpha", status: .reconnecting(attempt: 3, maxAttempts: 10))
            == "Reconnecting… 3/10 · Idle")
        #expect(summary(name: "Alpha", status: .cancellingRetry) == "Cancelling… · Idle")
        #expect(summary(name: "Alpha", status: .error("Tunnel lost")) == "Error: Tunnel lost · Idle")
    }

    private func summary(
        name: String?,
        status: ConnectionStatus,
        playback: NavigationEngine.PlaybackState = .idle,
        progress: Double = 0,
        recording: Bool = false
    ) -> String {
        MenuBarStatusFormatter.summary(
            deviceName: name,
            connection: status,
            playback: playback,
            progress: progress,
            isRecording: recording
        )
    }
}
