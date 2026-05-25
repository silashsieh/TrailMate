import Foundation

enum TunnelError: LocalizedError {
    case authCancelled
    case startFailed(String)
    case timeout
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .authCancelled:        "Authentication required"
        case .startFailed(let msg): "Tunnel start failed: \(msg)"
        case .timeout:              "Timed out waiting for tunnel"
        case .parseFailed(let s):   "Could not parse tunnel output: \(s)"
        }
    }
}

@MainActor
final class TunnelSupervisor {
    struct TunnelInfo {
        let address: String
        let port: Int
    }

    private var controlFile: URL?

    func start(udid: String) async throws -> TunnelInfo {
        // Per-call control file under ~/Library/Application Support/TrailMate/tunnels/.
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let tunnelsDir = appSupport.appendingPathComponent("TrailMate/tunnels", isDirectory: true)
        try FileManager.default.createDirectory(at: tunnelsDir, withIntermediateDirectories: true)
        let ctrl = tunnelsDir.appendingPathComponent("\(UUID().uuidString).info")
        controlFile = ctrl

        let parentPid = ProcessInfo.processInfo.processIdentifier
        let wrapper = PythonBundle.tunnelWrapperScript.path
        let pyHome = PythonBundle.pythonHome.path
        let pyLibs = PythonBundle.pythonLibs.path

        // Build the inner shell line: the wrapper backgrounded so osascript
        // returns immediately after auth, plus `disown` so its PID isn't tied
        // to the bash that spawned it.
        let inner = [wrapper, udid, ctrl.path, String(parentPid), pyHome, pyLibs]
            .map(shellQuote)
            .joined(separator: " ")
        let bashLine = "\(inner) >/dev/null 2>&1 & disown"
        let appleScript = "do shell script \(appleScriptStringLiteral(bashLine)) with administrator privileges"

        try await runOsascript(appleScript)
        return try await waitForControlFile(ctrl, timeout: .seconds(30))
    }

    func stop() async {
        guard let ctrl = controlFile else { return }
        controlFile = nil
        // Touch the .stop sentinel — the root wrapper polls for it and runs
        // its trap-cleanup, killing pmd3 and removing the control files. No
        // auth prompt needed for teardown.
        let stopURL = ctrl.appendingPathExtension("stop")
        FileManager.default.createFile(atPath: stopURL.path, contents: Data())
    }

    // MARK: - Internal

    private func runOsascript(_ script: String) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = Pipe()

        try proc.run()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            proc.terminationHandler = { _ in cont.resume() }
        }

        if proc.terminationStatus != 0 {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            // osascript reports "execution error: User cancelled. (-128)" when
            // the user dismisses the auth dialog.
            if text.contains("-128") || text.localizedCaseInsensitiveContains("cancel") {
                throw TunnelError.authCancelled
            }
            throw TunnelError.startFailed(text.isEmpty ? "osascript exited \(proc.terminationStatus)" : text)
        }
    }

    private func waitForControlFile(_ url: URL, timeout: Duration) async throws -> TunnelInfo {
        let errURL = url.appendingPathExtension("error")
        let fm = FileManager.default
        let deadline = ContinuousClock.now.advanced(by: timeout)

        while ContinuousClock.now < deadline {
            // Surface wrapper-level failures first (early pmd3 exit, etc.).
            if fm.fileExists(atPath: errURL.path) {
                let data = (try? Data(contentsOf: errURL)) ?? Data()
                let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw TunnelError.startFailed(firstLine(text))
            }

            if fm.fileExists(atPath: url.path),
               let data = try? Data(contentsOf: url),
               let raw = String(data: data, encoding: .utf8) {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty {
                    let parts = line.split(whereSeparator: { $0.isWhitespace })
                    guard parts.count == 2, let port = Int(parts[1]) else {
                        throw TunnelError.parseFailed(line)
                    }
                    return TunnelInfo(address: String(parts[0]), port: port)
                }
            }

            try? await Task.sleep(for: .milliseconds(250))
        }
        throw TunnelError.timeout
    }

    private func firstLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
    }

    /// POSIX-safe shell single-quoting.
    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Wrap a string as an AppleScript double-quoted literal, escaping `\` and `"`.
    private func appleScriptStringLiteral(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }
}
