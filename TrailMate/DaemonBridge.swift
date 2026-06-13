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

actor DaemonBridge: SimulationBackend {
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

    // Out-of-band events (process death, tunnel down). Consumers iterate
    // `events` in a child Task. Nonisolated so SimulationActor can subscribe
    // without crossing this actor's executor.
    nonisolated let events: AsyncStream<SimulationBackendEvent>
    nonisolated private let eventsContinuation: AsyncStream<SimulationBackendEvent>.Continuation

    // Cached write handle for the hot SETQ path. Serialized against start/stop
    // mutations by `writeQueue` so the 20 Hz simulation tick can write without
    // crossing this actor's executor and without racing pipe-close on stop.
    nonisolated(unsafe) private var writeHandle: FileHandle?
    nonisolated private let writeQueue = DispatchQueue(label: "TrailMate.DaemonBridge.write")

    init() {
        var continuation: AsyncStream<SimulationBackendEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.eventsContinuation = continuation
    }

    deinit {
        eventsContinuation.finish()
    }

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

        // Fires on a background queue when the process exits — hop onto the
        // actor to mutate state.
        proc.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let reason = proc.terminationReason
            Task { await self?.handleProcessExit(status: status, reason: reason) }
        }

        try proc.run()
        self.process = proc
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe

        // Latch the write handle on the serial queue so any concurrent SETQ
        // from the simulation actor sees the new handle atomically.
        let handle = stdinPipe.fileHandleForWriting
        writeQueue.sync { self.writeHandle = handle }

        readTask = Task.detached { [weak self] in
            let handle = stdoutPipe.fileHandleForReading
            do {
                for try await line in handle.bytes.lines {
                    await self?.receiveLine(line)
                }
            } catch {}
            await self?.receiveLine(nil)
        }

        // Bounded wait for READY. On timeout, treat as startup failure. The
        // budget is generous (20 s) because a second device's RSD/DVT setup can
        // run well past the ~few seconds a lone device takes — observed taking
        // longer than 10 s under multi-device contention, which made the app
        // give up while the daemon was still successfully connecting.
        let firstLine = await nextLine(timeout: .seconds(20))
        guard firstLine == "READY" else {
            expectingExit = true
            let stderr = readStderr()
            // A daemon spawned against a stale/dead RSD address can wedge in a
            // blocking connect that ignores SIGTERM, so escalate to SIGKILL —
            // otherwise the failed attempt leaks a stuck Python process.
            proc.terminate()
            _ = await waitForExit(proc: proc, timeout: .seconds(2))
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
                _ = await waitForExit(proc: proc, timeout: .seconds(1))
            }
            writeQueue.sync { self.writeHandle = nil }
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

    // Fire-and-forget for 10-20Hz playback. Nonisolated so the simulation
    // actor's tick can call us without an executor hop. The single-sender
    // invariant (only SimulationActor calls this) plus the serial writeQueue
    // makes it safe against start/stop mutating the cached handle.
    nonisolated func setLocationQuiet(latitude: Double, longitude: Double) {
        writeQueue.sync {
            guard let handle = writeHandle else { return }
            handle.write(Data("SETQ \(latitude) \(longitude)\n".utf8))
        }
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
        // Block any further SETQ before closing the fd. Pairs with the latch
        // in start() so concurrent setLocationQuiet sees nil and bails.
        writeQueue.sync { self.writeHandle = nil }
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
        if !expectingExit {
            let exitReason: ExitReason = (reason == .uncaughtSignal) ? .signal : .normal
            eventsContinuation.yield(.unexpectedExit(status: status, reason: exitReason))
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
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.fireTimeoutIfPending(sentinel: sentinel)
            }
        }
    }

    private func fireTimeoutIfPending(sentinel: UUID) {
        if pendingSentinel == sentinel, let pending = pendingContinuation {
            pendingContinuation = nil
            pendingSentinel = nil
            pending.resume(returning: nil)
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
            eventsContinuation.yield(.tunnelDown(line: line))
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
