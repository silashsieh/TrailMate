import CoreLocation
import Foundation
import Testing
@testable import TrailMate

@MainActor
struct DaemonPipeTests {
    @Test func closedPipeReturnsEPIPEWithoutKillingHost() throws {
        let pipe = Pipe()
        let writer = DaemonInputWriter()
        try writer.activate(pipe.fileHandleForWriting)
        try pipe.fileHandleForReading.close()

        #expect(writer.writeLine("SETQ 25 121") == .failed(.brokenPipe))
        #expect(writer.writeLine("QUIT") == .inactive)
        writer.deactivate()
        try pipe.fileHandleForWriting.close()
    }

    @Test func failedDaemonDisconnectsOnlyItsSession() async throws {
        let runtime = try IsolatedTestRuntime()
        defer { runtime.cleanup() }
        SimulatedPositionPersistence.setRestoreOnLaunch(false, in: runtime.defaults)
        let app = AppState(defaults: runtime.defaults, runtimePaths: runtime.runtimePaths)
        let a = app.selectedSession
        app.addSession()
        let b = app.selectedSession

        // The child closes fd 0 before announcing READY. Its stdout remains
        // open, so the hot-path write—not EOF or process exit—must detect loss.
        let bridge = fakeBridge(script: "exec 0<&-; printf 'READY\\n'; exec sleep 10")

        try await bridge.start(rsdAddress: "unused", rsdPort: "unused")
        await a.bindConnectedForTesting(udid: "DEVICE-A", backend: bridge)
        let healthy = MockSimulationBackend()
        await b.bindConnectedForTesting(udid: "DEVICE-B", backend: healthy)

        bridge.setLocationQuiet(latitude: 25, longitude: 121)
        let failed = await eventually {
            a.connectionStatus == .error("Tunnel down")
        }
        #expect(failed)
        #expect(a.connectedUDID == nil)
        #expect(b.connectionStatus == .connected)
        #expect(b.connectedUDID == "DEVICE-B")
        #expect(app.logMessages.contains { $0.contains("daemon input closed (EPIPE)") })

        // A second write cannot publish another failure or affect B.
        bridge.setLocationQuiet(latitude: 26, longitude: 122)
        #expect(b.connectionStatus == .connected)
        await b.sim.teleport(to: CLLocationCoordinate2D(latitude: 24, longitude: 120))
        #expect(await b.sim.integratorPosition?.latitude == 24)
        await app.prepareForQuit()
    }

    @Test func readyAndCommandReplyUseTheSameWriter() async throws {
        let bridge = fakeBridge(script: "printf 'READY\\n'; IFS= read -r line; printf 'OK\\n'; IFS= read -r line; printf 'EXIT\\n'")
        try await bridge.start(rsdAddress: "unused", rsdPort: "unused")
        let reply = try await bridge.sendCommand("HEARTBEAT")
        #expect(reply == "OK")
        await bridge.stop()
    }

    @Test func startupWithoutREADYTimesOutAndReapsChild() async {
        let bridge = fakeBridge(script: "exec sleep 10", startupTimeout: .milliseconds(50))
        do {
            try await bridge.start(rsdAddress: "unused", rsdPort: "unused")
            Issue.record("Daemon unexpectedly reached READY")
            await bridge.stop()
        } catch DaemonError.startupTimeout {
            // The timeout path tears down the child before returning.
        } catch {
            Issue.record("Unexpected startup error: \(error)")
        }
    }

    @Test func stdoutEOFBecomesOneConnectionLoss() async throws {
        let bridge = fakeBridge(script: "printf 'READY\\n'; exec 1>&-; exec sleep 10")
        try await bridge.start(rsdAddress: "unused", rsdPort: "unused")
        var iterator = bridge.events.makeAsyncIterator()
        let event = await iterator.next()
        if case .connectionLost(.endOfFile) = event {
            // EOF wins while the child is still alive, before process exit.
        } else {
            Issue.record("Expected stdout EOF, got \(String(describing: event))")
        }
        await bridge.stop()
    }

    @Test func tunnelDownAndProcessExitAreNormalLossEvents() async throws {
        for (script, expected) in [
            ("printf 'READY\\nTUNNEL_DOWN\\n'; exec sleep 10", "Tunnel down"),
            ("printf 'READY\\n'; exit 7", "disconnect")
        ] {
            let bridge = fakeBridge(script: script)
            try await bridge.start(rsdAddress: "unused", rsdPort: "unused")
            var iterator = bridge.events.makeAsyncIterator()
            let event = await iterator.next()
            guard case .connectionLost(let failure) = event else {
                Issue.record("Expected \(expected) event, got \(String(describing: event))")
                await bridge.stop()
                continue
            }
            if expected == "Tunnel down" {
                #expect(failure == .tunnelDown(line: "TUNNEL_DOWN"))
            } else {
                // Termination and stdout EOF can race; both are a single,
                // recoverable loss rather than a fatal signal.
                #expect(failure.statusMessage == "Daemon crashed (exit 7)" || failure == .endOfFile)
            }
            await bridge.stop()
        }
    }

    private func fakeBridge(
        script: String,
        startupTimeout: Duration = .seconds(2)
    ) -> DaemonBridge {
        DaemonBridge(configuration: .init(
            startupTimeout: startupTimeout,
            quitTimeout: .milliseconds(50),
            terminateTimeout: .milliseconds(250),
            killTimeout: .milliseconds(250)
        ) { _, _ in
            let process = Process()
            let input = Pipe()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            return .init(process: process, stdinPipe: input, stdoutPipe: output, stderrPipe: errors)
        })
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}
