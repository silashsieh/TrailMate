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

// App-global tunnel broker (epic 012). Replaces the per-device TunnelSupervisor:
// one privileged `pymobiledevice3 remote tunneld` process — a single auth prompt
// per session — auto-tunnels every connected device, and the broker resolves a
// device's current RSD endpoint by querying tunneld's HTTP API.
//
// The RSD address+port are EPHEMERAL: tunneld reassigns them on every tunnel
// (re)establishment (sleep/wake, reconnect) — verified in the 2026-06-13 spike,
// where all three devices got new address+port after wake. So `rsdEndpoint`
// re-queries on every connect and nothing caches the endpoint; the UDID is the
// only stable key.
@MainActor
final class TunnelBroker {
    struct TunnelInfo {
        let address: String
        let port: Int
    }

    // tunneld's default bind port. Configurable in case 49151 is taken.
    static let port = 49151

    private var controlFile: URL?
    private var isRunning = false

    // Launch the single privileged tunneld (the one auth prompt). Idempotent —
    // returns immediately if already running. Resolves readiness by polling
    // tunneld's HTTP endpoint, and surfaces an early tunneld exit as an error.
    func ensureRunning() async throws {
        if isRunning { return }

        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let tunnelsDir = appSupport.appendingPathComponent("TrailMate/tunnels", isDirectory: true)
        try FileManager.default.createDirectory(at: tunnelsDir, withIntermediateDirectories: true)
        let ctrl = tunnelsDir.appendingPathComponent("tunneld-\(UUID().uuidString).info")
        controlFile = ctrl

        let parentPid = ProcessInfo.processInfo.processIdentifier
        let wrapper = PythonBundle.tunneldWrapperScript.path
        let pyHome = PythonBundle.pythonHome.path
        let pyLibs = PythonBundle.pythonLibs.path

        let inner = [wrapper, ctrl.path, String(parentPid), pyHome, pyLibs, String(Self.port)]
            .map(shellQuote)
            .joined(separator: " ")
        let bashLine = "\(inner) >/dev/null 2>&1 & disown"
        let appleScript = "do shell script \(appleScriptStringLiteral(bashLine)) with administrator privileges"

        try await runOsascript(appleScript)
        try await waitUntilReady(ctrl: ctrl, timeout: .seconds(30))
        isRunning = true
    }

    // Current RSD endpoint for a device — resolved fresh every call (addresses
    // are ephemeral; see the type comment). Picks the usbmux-<UDID>-Network entry
    // tunneld exposes; falls back to the first entry.
    //
    // While tunneld is still establishing a freshly-discovered device's tunnel
    // (e.g. right after the user adds a second device), it can briefly publish a
    // transient (address,port) and then rotate it. A daemon spawned against the
    // transient endpoint wedges on a now-dead address. So wait for the endpoint
    // to read identical twice in a row before trusting it — and, as a bonus, wait
    // for the entry to appear at all, covering the "no tunnel yet" race when a
    // device is connected the instant after it's plugged in.
    func rsdEndpoint(udid: String) async throws -> TunnelInfo {
        // Require the endpoint to read identical several times in a row before
        // trusting it: a freshly-establishing tunnel can hold one (address,port)
        // briefly, then rotate. Two reads can both land inside a transient window;
        // demanding `stableReadsRequired` consecutive matches (~1.8 s of held
        // stability) makes catching a mid-rotation value far less likely.
        let stableReadsRequired = 3
        var lastSeen: TunnelInfo?
        var stableCount = 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            let map = try await fetchTunnelMap()
            if let entries = map[udid], !entries.isEmpty {
                let entry = entries.first { $0.interface.contains("usbmux") } ?? entries[0]
                let info = TunnelInfo(address: entry.address, port: entry.port)
                if let lastSeen, lastSeen.address == info.address, lastSeen.port == info.port {
                    stableCount += 1
                    if stableCount >= stableReadsRequired - 1 {
                        return info   // held identical across enough reads
                    }
                } else {
                    stableCount = 0   // changed — restart the stability count
                }
                lastSeen = info
            } else {
                lastSeen = nil; stableCount = 0   // not present yet
            }
            try? await Task.sleep(for: .milliseconds(600))
        }
        // Never stabilized within the window: hand back the last reading if we
        // ever saw one (best effort; the connect retry will recover), otherwise
        // report the device as untunneled.
        if let lastSeen { return lastSeen }
        throw TunnelError.startFailed("device \(udid) has no tunnel yet — is it connected?")
    }

    // Tear down the whole broker (all tunnels). Called at app quit, not on a
    // per-device disconnect — the broker is shared, and keeping it up is what
    // makes reconnects promptless.
    func stop() {
        guard let ctrl = controlFile else { return }
        controlFile = nil
        isRunning = false
        let stopURL = ctrl.appendingPathExtension("stop")
        FileManager.default.createFile(atPath: stopURL.path, contents: Data())
    }

    // MARK: - tunneld HTTP query

    private struct Entry {
        let address: String
        let port: Int
        let interface: String
    }

    private func fetchTunnelMap() async throws -> [String: [Entry]] {
        let url = URL(string: "http://127.0.0.1:\(Self.port)/")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TunnelError.parseFailed("tunneld response was not a JSON object")
        }
        var result: [String: [Entry]] = [:]
        for (udid, value) in obj {
            guard let array = value as? [[String: Any]] else { continue }
            result[udid] = array.compactMap { entry in
                guard let address = entry["tunnel-address"] as? String,
                      let port = entry["tunnel-port"] as? Int else { return nil }
                let interface = entry["interface"] as? String ?? ""
                return Entry(address: address, port: port, interface: interface)
            }
        }
        return result
    }

    private func waitUntilReady(ctrl: URL, timeout: Duration) async throws {
        let errURL = ctrl.appendingPathExtension("error")
        let fm = FileManager.default
        let deadline = ContinuousClock.now.advanced(by: timeout)

        while ContinuousClock.now < deadline {
            if fm.fileExists(atPath: errURL.path) {
                let text = (try? String(contentsOf: errURL, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw TunnelError.startFailed(text.isEmpty ? "tunneld exited on launch" : firstLine(text))
            }
            // Ready as soon as tunneld answers the HTTP query (even with an empty
            // device map — devices populate as their tunnels come up).
            if (try? await fetchTunnelMap()) != nil { return }
            try? await Task.sleep(for: .milliseconds(300))
        }
        throw TunnelError.timeout
    }

    private func firstLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
    }

    // MARK: - osascript / shell (same approach as the former TunnelSupervisor)

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
            if text.contains("-128") || text.localizedCaseInsensitiveContains("cancel") {
                throw TunnelError.authCancelled
            }
            throw TunnelError.startFailed(text.isEmpty ? "osascript exited \(proc.terminationStatus)" : text)
        }
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptStringLiteral(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }
}
