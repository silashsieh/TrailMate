import Foundation

enum DaemonError: LocalizedError {
    case notRunning
    case startupFailed(String)
    case startupTimeout
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            "Daemon is not running"
        case .startupFailed(let msg):
            "Daemon startup failed: \(msg)"
        case .startupTimeout:
            "Timed out waiting for daemon READY"
        case .commandFailed(let msg):
            "Command failed: \(msg)"
        }
    }
}

@MainActor
final class DaemonBridge {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var readTask: Task<Void, Never>?
    private var pendingContinuation: CheckedContinuation<String?, Never>?
    private var pendingSentinel: UUID?
    private var bufferedLines: [String] = []
    private var expectingExit = false
    private var didNotifyExit = false

    // Fires when the daemon process exits unexpectedly (not via stop()).
    var onUnexpectedExit: ((Int32, Process.TerminationReason) -> Void)?

    // Fires when the daemon emits an unsolicited TUNNEL_DOWN line.
    var onTunnelDown: ((String) -> Void)?

    func start(rsdAddress: String, rsdPort: String) async throws {
        let proc = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        proc.executableURL = PythonBundle.interpreter
        proc.arguments = ["-u", PythonBundle.script("tm_daemon").path, rsdAddress, rsdPort]
        proc.environment = PythonBundle.environment
        proc.currentDirectoryURL = PythonBundle.interpreter.deletingLastPathComponent()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        // Fires on a background queue when the process exits.
        proc.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let reason = proc.terminationReason
            Task { @MainActor in
                self?.handleProcessExit(status: status, reason: reason)
            }
        }

        try proc.run()
        self.process = proc
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe

        readTask = Task.detached { [weak self] in
            let handle = stdoutPipe.fileHandleForReading
            do {
                for try await line in handle.bytes.lines {
                    await self?.receiveLine(line)
                }
            } catch {}
            await self?.receiveLine(nil)
        }

        // Bounded wait for READY (10 s). On timeout, treat as startup failure.
        let firstLine = await nextLine(timeout: .seconds(10))
        guard firstLine == "READY" else {
            expectingExit = true
            let stderr = readStderr()
            proc.terminate()
            _ = await waitForExit(proc: proc, timeout: .seconds(2))
            closePipes()
            self.process = nil
            self.stdinPipe = nil
            self.stdoutPipe = nil
            self.stderrPipe = nil
            if firstLine == nil {
                throw DaemonError.startupTimeout
            }
            let detail = stderr.isEmpty ? firstLine! : stderr
            throw DaemonError.startupFailed(detail)
        }
    }

    @discardableResult
    func sendCommand(_ command: String) async throws -> String {
        guard let pipe = stdinPipe, process?.isRunning == true else {
            throw DaemonError.notRunning
        }

        pipe.fileHandleForWriting.write(Data((command + "\n").utf8))

        guard let response = await nextLine() else {
            throw DaemonError.notRunning
        }

        if response.hasPrefix("ERR") {
            throw DaemonError.commandFailed(response)
        }

        return response
    }

    var isRunning: Bool {
        process?.isRunning == true
    }

    // Fire-and-forget for 10-20Hz playback. The single pendingContinuation can't
    // safely interleave responses, so awaiting SET per tick would serialize the loop.
    func setLocationQuiet(latitude: Double, longitude: Double) {
        guard let pipe = stdinPipe, process?.isRunning == true else { return }
        pipe.fileHandleForWriting.write(Data("SETQ \(latitude) \(longitude)\n".utf8))
    }

    // QUIT → SIGTERM → SIGKILL with bounded waits at each step. The daemon's
    // async with LocationSimulation(...) only clears the iPhone's simulated
    // location if QUIT or SIGTERM lets the async-with exit run; SIGKILL is the
    // last-resort path.
    func stop() async {
        guard let proc = process else { return }
        expectingExit = true

        // Phase 1: QUIT — wait up to 2 s for the daemon's EXIT ack.
        if proc.isRunning, let pipe = stdinPipe {
            try? pipe.fileHandleForWriting.write(contentsOf: Data("QUIT\n".utf8))
        }
        let exited = await waitForLine("EXIT", timeout: .seconds(2))

        // Phase 2: SIGTERM — daemon's signal handler still clears DVT.
        if !exited, proc.isRunning {
            proc.terminate()
            _ = await waitForExit(proc: proc, timeout: .seconds(2))
        }

        // Phase 3: SIGKILL — only if it's stuck.
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
            _ = await waitForExit(proc: proc, timeout: .seconds(1))
        }

        readTask?.cancel()
        closePipes()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
        if let cont = pendingContinuation {
            pendingContinuation = nil
            pendingSentinel = nil
            cont.resume(returning: nil)
        }
    }

    // MARK: - Internal

    private func closePipes() {
        try? stdinPipe?.fileHandleForWriting.close()
        try? stdoutPipe?.fileHandleForReading.close()
        try? stderrPipe?.fileHandleForReading.close()
    }

    private func handleProcessExit(status: Int32, reason: Process.TerminationReason) {
        guard !didNotifyExit else { return }
        didNotifyExit = true
        if !expectingExit, let callback = onUnexpectedExit {
            callback(status, reason)
        }
    }

    private func nextLine() async -> String? {
        if !bufferedLines.isEmpty {
            return bufferedLines.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            self.pendingContinuation = continuation
            self.pendingSentinel = nil
        }
    }

    // Race nextLine() against a timeout. A per-call sentinel disambiguates this
    // wait from any later one — if `pendingSentinel` no longer matches when the
    // timer fires, someone else has already taken our slot and we leave the new
    // wait alone.
    private func nextLine(timeout: Duration) async -> String? {
        if !bufferedLines.isEmpty {
            return bufferedLines.removeFirst()
        }
        let sentinel = UUID()
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            self.pendingContinuation = cont
            self.pendingSentinel = sentinel
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self else { return }
                if self.pendingSentinel == sentinel, let pending = self.pendingContinuation {
                    self.pendingContinuation = nil
                    self.pendingSentinel = nil
                    pending.resume(returning: nil)
                }
            }
        }
    }

    // Wait for a specific line (used by stop's QUIT/EXIT handshake). Non-matching
    // lines are re-buffered so steady-state flow is undisturbed.
    private func waitForLine(_ expected: String, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let remaining = deadline - ContinuousClock.now
            guard let line = await nextLine(timeout: remaining) else { return false }
            if line == expected { return true }
            bufferedLines.append(line)
        }
        return false
    }

    private func waitForExit(proc: Process, timeout: Duration) async -> Bool {
        // Sample isRunning on a short polling interval — Process has no async
        // wait API on macOS, and waitUntilExit() blocks. 50 ms polling is well
        // under any sane termination latency.
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if !proc.isRunning { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !proc.isRunning
    }

    private func receiveLine(_ line: String?) {
        if let line, line.hasPrefix("TUNNEL_DOWN"), !expectingExit {
            onTunnelDown?(line)
            return
        }
        if let continuation = pendingContinuation {
            pendingContinuation = nil
            pendingSentinel = nil
            continuation.resume(returning: line)
        } else if let line {
            bufferedLines.append(line)
        }
    }

    private func readStderr() -> String {
        guard let data = stderrPipe?.fileHandleForReading.availableData,
              let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

