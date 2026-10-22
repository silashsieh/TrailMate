import Darwin
import Foundation

enum DaemonError: LocalizedError {
    case notRunning
    case startupFailed(String)
    case startupTimeout
    case commandFailed(String)
    case pipeConfigurationFailed(errno: Int32)
    case connectionLost(SimulationBackendFailure)

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
        case .pipeConfigurationFailed(let code):
            "Could not suppress SIGPIPE on daemon input (errno \(code))"
        case .connectionLost(let failure):
            failure.logMessage
        }
    }
}

actor DaemonBridge: SimulationBackend {
    struct ProcessLaunch: @unchecked Sendable {
        let process: Process
        let stdinPipe: Pipe
        let stdoutPipe: Pipe
        let stderrPipe: Pipe
    }

    struct Configuration: @unchecked Sendable {
        let startupTimeout: Duration
        let quitTimeout: Duration
        let terminateTimeout: Duration
        let killTimeout: Duration
        let makeLaunch: @Sendable (_ rsdAddress: String, _ rsdPort: String) -> ProcessLaunch

        static let live = Configuration(
            startupTimeout: .seconds(20),
            quitTimeout: .seconds(2),
            terminateTimeout: .seconds(2),
            killTimeout: .seconds(1)
        ) { rsdAddress, rsdPort in
            let process = Process()
            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = PythonBundle.interpreter
            process.arguments = ["-u", PythonBundle.script("tm_daemon").path, rsdAddress, rsdPort]
            process.environment = PythonBundle.environment
            process.currentDirectoryURL = PythonBundle.interpreter.deletingLastPathComponent()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe
            return ProcessLaunch(
                process: process,
                stdinPipe: stdinPipe,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe
            )
        }
    }

    private let configuration: Configuration
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    // Accumulates partial stdout between reads; drained into whole lines by
    // ingest(). The reader Task drains an ordered byte stream fed by the
    // readabilityHandler, so ingest is called in arrival order.
    private var stdoutBuffer = Data()
    private var stdoutReader: Task<Void, Never>?
    private var stdoutContinuation: AsyncStream<Data>.Continuation?
    private var pendingContinuation: CheckedContinuation<String?, Never>?
    private var pendingSentinel: UUID?
    private var bufferedLines: [String] = []
    private var expectingExit = false

    // Out-of-band events (process death, tunnel down). Consumers iterate
    // `events` in a child Task. Nonisolated so SimulationActor can subscribe
    // without crossing this actor's executor.
    nonisolated let events: AsyncStream<SimulationBackendEvent>
    nonisolated private let eventsContinuation: AsyncStream<SimulationBackendEvent>.Continuation

    // SET, SETQ, and QUIT all share this one per-fd-SIGPIPE-protected writer.
    // The gate makes failure publication atomic across the writer, stdout EOF,
    // TUNNEL_DOWN, and Process.terminationHandler.
    nonisolated private let inputWriter = DaemonInputWriter()
    nonisolated private let failureGate = DaemonFailureGate()

    init(configuration: Configuration = .live) {
        self.configuration = configuration
        var continuation: AsyncStream<SimulationBackendEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.eventsContinuation = continuation
    }

    deinit {
        eventsContinuation.finish()
    }

    func start(rsdAddress: String, rsdPort: String) async throws {
        let launch = configuration.makeLaunch(rsdAddress, rsdPort)
        let proc = launch.process
        let stdinPipe = launch.stdinPipe
        let stdoutPipe = launch.stdoutPipe
        let stderrPipe = launch.stderrPipe
        expectingExit = false
        failureGate.reset()

        // Fires on a background queue when the process exits — hop onto the
        // actor to mutate state.
        proc.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let reason = proc.terminationReason
            Task { await self?.handleProcessExit(status: status, reason: reason) }
        }

        do {
            // F_SETNOSIGPIPE is installed before Process.run(), so no daemon
            // stdin write can inherit Darwin's process-fatal SIGPIPE default.
            try inputWriter.activate(stdinPipe.fileHandleForWriting)
        } catch let error as DaemonInputWriter.ActivationError {
            try? stdinPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            switch error {
            case .cannotSuppressSIGPIPE(let code):
                throw DaemonError.pipeConfigurationFailed(errno: code)
            }
        }

        do {
            try proc.run()
        } catch {
            failureGate.suppress()
            inputWriter.deactivate()
            try? stdinPipe.fileHandleForWriting.close()
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            throw error
        }
        // Only the child reads stdin and writes stdout/stderr. Retaining the
        // parent's copies would mask EPIPE/EOF when the child closes its ends.
        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        self.process = proc
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe

        // Read stdout with an event-driven readabilityHandler rather than
        // `FileHandle.bytes.lines`. The latter does a *blocking* read that holds
        // Foundation's shared file-handle async-read queue; with multiple devices
        // connected, one daemon's idle reader (blocked waiting for its next line)
        // starves every other daemon's reader, so a second device never sees its
        // READY and wedges. readabilityHandler fires only when data is actually
        // available and never blocks, so concurrent bridges read independently.
        // The handler feeds an ordered AsyncStream that a single Task drains into
        // the actor, so ingest() sees bytes in arrival order.
        let (byteStream, byteCont) = AsyncStream.makeStream(of: Data.self)
        self.stdoutContinuation = byteCont
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            byteCont.yield(handle.availableData)
        }
        stdoutReader = Task { [weak self] in
            for await data in byteStream {
                await self?.ingest(data)
            }
        }

        // Bounded wait for READY. On timeout, treat as startup failure. The
        // budget is generous (20 s) because a second device's RSD/DVT setup can
        // run well past the ~few seconds a lone device takes — observed taking
        // longer than 10 s under multi-device contention, which made the app
        // give up while the daemon was still successfully connecting.
        let firstLine = await nextLine(timeout: configuration.startupTimeout)
        guard firstLine == "READY" else {
            expectingExit = true
            failureGate.suppress()
            // A daemon spawned against a stale/dead RSD address can wedge in a
            // blocking connect that ignores SIGTERM, so escalate to SIGKILL —
            // otherwise the failed attempt leaks a stuck Python process.
            proc.terminate()
            _ = await waitForExit(proc: proc, timeout: configuration.terminateTimeout)
            if proc.isRunning {
                kill(proc.processIdentifier, SIGKILL)
                _ = await waitForExit(proc: proc, timeout: configuration.killTimeout)
            }
            // Read stderr only after the process has closed its write end;
            // FileHandle.availableData would otherwise block a timeout path.
            let stderr = readStderr()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stdoutContinuation?.finish(); stdoutContinuation = nil
            stdoutReader?.cancel(); stdoutReader = nil
            inputWriter.deactivate()
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
        guard stdinPipe != nil, process?.isRunning == true else {
            throw DaemonError.notRunning
        }

        switch inputWriter.writeLine(command) {
        case .written:
            break
        case .inactive:
            throw DaemonError.notRunning
        case .failed(let failure):
            reportConnectionLoss(failure)
            throw DaemonError.connectionLost(failure)
        }

        guard let response = await nextLine() else {
            throw DaemonError.notRunning
        }

        if response.hasPrefix("ERR") {
            throw DaemonError.commandFailed(response)
        }

        return response
    }

    // Fire-and-forget for 10 Hz playback. Nonisolated so the simulation
    // actor's tick can call us without an executor hop. The single-sender
    // invariant (only SimulationActor calls this) plus the writer's serial
    // queue makes it safe against start/stop mutating the cached descriptor.
    nonisolated func setLocationQuiet(latitude: Double, longitude: Double) {
        if case .failed(let failure) = inputWriter.writeLine("SETQ \(latitude) \(longitude)") {
            reportConnectionLoss(failure)
        }
    }

    // QUIT → SIGTERM → SIGKILL with bounded waits at each step. The daemon's
    // async with LocationSimulation(...) only clears the iPhone's simulated
    // location if QUIT or SIGTERM lets the async-with exit run; SIGKILL is the
    // last-resort path.
    func stop() async {
        expectingExit = true
        failureGate.suppress()
        guard let proc = process else {
            inputWriter.deactivate()
            return
        }

        // Phase 1: QUIT — wait up to 2 s for the daemon's EXIT ack.
        if proc.isRunning {
            _ = inputWriter.writeLine("QUIT")
        }
        let exited = await waitForLine("EXIT", timeout: configuration.quitTimeout)

        // Phase 2: SIGTERM — daemon's signal handler still clears DVT.
        if !exited, proc.isRunning {
            proc.terminate()
            _ = await waitForExit(proc: proc, timeout: configuration.terminateTimeout)
        }

        // Phase 3: SIGKILL — only if it's stuck.
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
            _ = await waitForExit(proc: proc, timeout: configuration.killTimeout)
        }

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutContinuation?.finish(); stdoutContinuation = nil
        stdoutReader?.cancel(); stdoutReader = nil
        // Block any further SETQ before closing the fd.
        inputWriter.deactivate()
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
        if !expectingExit {
            let exitReason: ExitReason = (reason == .uncaughtSignal) ? .signal : .normal
            reportConnectionLoss(.unexpectedExit(status: status, reason: exitReason))
        }
    }

    // This is nonisolated because SETQ reports from the serial write queue. The
    // lock-backed gate picks one cause synchronously before any competing EOF,
    // exit, or TUNNEL_DOWN callback can publish or overwrite it.
    nonisolated private func reportConnectionLoss(_ failure: SimulationBackendFailure) {
        guard failureGate.accept(failure) else { return }
        inputWriter.deactivate()
        eventsContinuation.yield(.connectionLost(failure))
        Task { await self.finishPendingAfterConnectionLoss() }
    }

    private func finishPendingAfterConnectionLoss() {
        if let continuation = pendingContinuation {
            pendingContinuation = nil
            pendingSentinel = nil
            continuation.resume(returning: nil)
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

    // Accumulate stdout bytes from the readabilityHandler and emit whole lines.
    // Empty data signals EOF (pipe closed). Lines are newline-delimited; the
    // daemon's protocol tokens are ASCII, so byte-level newline splitting is
    // safe (no multibyte split across a newline).
    private func ingest(_ data: Data) {
        guard !data.isEmpty else {
            stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            stdoutContinuation?.finish(); stdoutContinuation = nil
            receiveLine(nil)
            if !expectingExit {
                reportConnectionLoss(.endOfFile)
            }
            return
        }
        stdoutBuffer.append(data)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer[stdoutBuffer.startIndex..<nl]
            stdoutBuffer = Data(stdoutBuffer[stdoutBuffer.index(after: nl)...])
            if let line = String(data: lineData, encoding: .utf8) {
                receiveLine(line.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n")))
            }
        }
    }

    private func receiveLine(_ line: String?) {
        if let line, line.hasPrefix("TUNNEL_DOWN"), !expectingExit {
            reportConnectionLoss(.tunnelDown(line: line))
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
