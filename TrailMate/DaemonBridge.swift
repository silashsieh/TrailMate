import Foundation

enum DaemonError: LocalizedError {
    case notRunning
    case startupFailed(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            "Daemon is not running"
        case .startupFailed(let msg):
            "Daemon startup failed: \(msg)"
        case .commandFailed(let msg):
            "Command failed: \(msg)"
        }
    }
}

@MainActor
final class DaemonBridge {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stderrPipe: Pipe?
    private var readTask: Task<Void, Never>?
    private var pendingContinuation: CheckedContinuation<String?, Never>?
    private var bufferedLines: [String] = []

    private static let pythonPath = "/Users/harry/Documents/pikmin/TrailMate/PythonDaemon/.venv/bin/python3"
    private static let daemonPath = "/Users/harry/Documents/pikmin/TrailMate/PythonDaemon/tm_daemon.py"

    func start(rsdAddress: String, rsdPort: String) async throws {
        let proc = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        proc.executableURL = URL(fileURLWithPath: Self.pythonPath)
        proc.arguments = ["-u", Self.daemonPath, rsdAddress, rsdPort]
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        try proc.run()
        self.process = proc
        self.stdinPipe = stdinPipe
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

        let firstLine = await nextLine()
        guard firstLine == "READY" else {
            let stderr = readStderr()
            proc.terminate()
            proc.waitUntilExit()
            self.process = nil
            self.stdinPipe = nil
            self.stderrPipe = nil
            let detail = stderr.isEmpty ? (firstLine ?? "no output") : stderr
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

    func stop() {
        if process?.isRunning == true {
            stdinPipe?.fileHandleForWriting.write(Data("QUIT\n".utf8))
        }
        readTask?.cancel()
        process?.terminate()
        process = nil
        stdinPipe = nil
        stderrPipe = nil
        if let cont = pendingContinuation {
            pendingContinuation = nil
            cont.resume(returning: nil)
        }
    }

    private func nextLine() async -> String? {
        if !bufferedLines.isEmpty {
            return bufferedLines.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            self.pendingContinuation = continuation
        }
    }

    private func receiveLine(_ line: String?) {
        if let continuation = pendingContinuation {
            pendingContinuation = nil
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
