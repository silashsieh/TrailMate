import Darwin
import Foundation
import os

// AF_UNIX command server for AI control — the inverse of DaemonBridge's pipe
// loop. Raw BSD sockets (socket/bind/listen/accept) deliberately, not NWListener
// or an HTTP server: the design (epic 019) wants no TCP port and the smallest
// possible surface. Off by default; only listening while AppState's
// aiControlEnabled is on.
//
// Threading model:
//   - The accept loop runs on its OWN dedicated background thread and blocks in
//     accept(). It is used for nothing else, so stop() (running on the caller's
//     thread) can close the listening fd to unblock that accept() — the standard
//     Darwin idiom. A shared serial queue here would deadlock: a blocked
//     accept() would hold the queue and stop() could never run on it.
//   - Each accepted connection is handled on the global concurrent queue, one
//     blocking read() loop per connection. That dedicated thread is what makes
//     it safe for handle(line:) to park on a semaphore awaiting the MainActor
//     dispatch — it never stalls accept() or another connection.
//   - All mutable state is guarded by `lock`. stop() flips isRunning, closes the
//     listen fd, and shutdown()s every live client fd so their read() loops wake.
//
// Every command hops to MainActor and calls appState.dispatch(), which routes
// through the *same* session/AppState methods the GUI uses so every move passes
// the SimulationActor.emit() chokepoint (noise + recording).
final class CommandServer: @unchecked Sendable {
    private let appState: AppState
    private let log = Logger(subsystem: "com.harry.trailmate", category: "CommandServer")

    // Guards all mutable state below. The lock — not a confining queue — is the
    // synchronization: the accept thread, the per-connection threads, and stop()
    // all run concurrently.
    private let lock = NSLock()
    private var isRunning = false
    private var listenFD: Int32 = -1
    private var socketPath: String?
    private var clientFDs: Set<Int32> = []

    // A legal command is well under 1 KiB; cap the per-connection read buffer so
    // a client streaming newline-less bytes can't grow it without bound (OOM).
    private static let maxLineBytes = 64 * 1024
    // Upper bound a connection thread waits for a dispatched command before it
    // returns a timeout — a wedged tunnel (TUNNEL_DOWN) must not park it forever.
    private static let dispatchTimeout: DispatchTimeInterval = .seconds(15)

    init(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Lifecycle

    func start() {
        lock.lock()
        guard !isRunning else { lock.unlock(); return }

        let path: String
        do {
            path = try SocketPath.resolve()
        } catch {
            lock.unlock()
            logEvent("AI control: socket path error — \(error.localizedDescription)")
            return
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            lock.unlock()
            logEvent("AI control: socket() failed (errno \(errno)).")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // Length already validated by SocketPath.resolve(); copy the C string
        // (NUL terminator included) into the fixed sun_path tuple.
        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            sunPath.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    dst.update(from: src.baseAddress!, count: src.count)
                }
            }
        }

        // SO_REUSEADDR is a no-op for AF_UNIX — a stale socket file is what
        // blocks bind(), so unlink() it first. Safe even if it doesn't exist.
        unlink(path)

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            lock.unlock()
            close(fd)
            logEvent("AI control: bind() failed (errno \(errno)).")
            return
        }

        // Owner-only (0700): the auth model is filesystem permissions. The parent
        // dir is already user-private, but lock the socket node down too rather
        // than rely on the dir + umask.
        chmod(path, S_IRWXU)

        guard listen(fd, 4) == 0 else {
            lock.unlock()
            close(fd)
            unlink(path)
            logEvent("AI control: listen() failed (errno \(errno)).")
            return
        }

        listenFD = fd
        socketPath = path
        isRunning = true
        lock.unlock()

        logEvent("AI control: listening at \(path)")

        // Dedicated thread for the blocking accept loop — see the type comment.
        let thread = Thread { [weak self] in
            self?.acceptLoop(fd: fd)
        }
        thread.name = "com.harry.trailmate.CommandServer.accept"
        thread.start()
    }

    func stop() {
        lock.lock()
        guard isRunning else { lock.unlock(); return }
        isRunning = false
        let fd = listenFD
        listenFD = -1
        let path = socketPath
        socketPath = nil
        // shutdown() each live client *under the lock* to wake its blocked
        // read() — but do NOT close or untrack them here. The connection thread
        // is the sole closer (closeClient), gated on set membership, so close()
        // and this shutdown() can't interleave into a close-then-reuse-then-
        // shutdown race. shutdown doesn't free the fd, so it stays valid until
        // the woken thread closes it.
        for client in clientFDs {
            shutdown(client, SHUT_RDWR)
        }
        lock.unlock()

        // Closing the listen fd unblocks accept(); the loop sees isRunning ==
        // false and exits its dedicated thread.
        if fd >= 0 { close(fd) }
        if let path { unlink(path) }
        logEvent("AI control: stopped.")
    }

    // MARK: - Accept loop

    private func acceptLoop(fd: Int32) {
        while running() {
            let clientFD = accept(fd, nil, nil)
            if clientFD < 0 {
                // accept() returns -1 when stop() closes the listening fd;
                // that's the normal shutdown path, not an error.
                if running() {
                    logEvent("AI control: accept() failed (errno \(errno)).")
                }
                return
            }
            // Reject the connection if we've stopped between accept() and now.
            guard track(clientFD) else {
                close(clientFD)
                return
            }
            // Darwin raises SIGPIPE (fatal by default) on write() to a peer that
            // already closed; SO_NOSIGPIPE turns that into an EPIPE return we
            // handle in writeLine, so a client disconnecting can't crash the app.
            var noSigPipe: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            // One blocking read loop per connection, off on a concurrent thread
            // so accept() can immediately return to listening.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.handleConnection(clientFD)
            }
        }
    }

    // MARK: - Connection handling

    private func handleConnection(_ clientFD: Int32) {
        defer { closeClient(clientFD) }

        writeLine(aiGreetingLine(), to: clientFD)

        var buffer = Data()
        var readChunk = [UInt8](repeating: 0, count: 4096)

        while running() {
            let n = read(clientFD, &readChunk, readChunk.count)
            if n <= 0 { break }   // 0 = client closed; <0 = error or shutdown()
            buffer.append(contentsOf: readChunk[0..<n])

            // Process every complete line in the buffer; keep the trailing
            // partial for the next read.
            while let nlIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<nlIndex]
                buffer.removeSubrange(buffer.startIndex...nlIndex)
                guard let rawLine = String(data: lineData, encoding: .utf8) else { continue }
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.isEmpty { continue }
                let response = handle(line: line)
                writeLine(response.line(), to: clientFD)
            }

            // A client streaming bytes with no newline must not grow the buffer
            // without bound (local OOM). Past the cap, reject and drop the
            // connection — every legal command is far smaller.
            if buffer.count > Self.maxLineBytes {
                writeLine(CommandResponse.failure(code: "line_too_long",
                    message: "command exceeds \(Self.maxLineBytes) bytes").line(), to: clientFD)
                break
            }
        }
    }

    // Parse one line and dispatch it. Parse failures become a clean ERR
    // response; valid commands hop to MainActor and run through the GUI's
    // facade. We are on a dedicated connection thread here (never MainActor), so
    // blocking on a semaphore while the MainActor Task runs dispatch is safe —
    // it parks this connection thread, not the UI thread.
    private func handle(line: String) -> CommandResponse {
        switch Command.parse(line) {
        case .failure(let error):
            return .failure(code: "parse_error", message: error.message)
        case .success(let command):
            let appState = self.appState
            let box = ResultBox()
            let semaphore = DispatchSemaphore(value: 0)
            Task { @MainActor in
                let response = await appState.dispatch(command)
                box.store(response)
                semaphore.signal()
            }
            // Bounded wait: ROUTE/CLEAR await the daemon, and a wedged tunnel
            // (TUNNEL_DOWN is anticipated) could make that never return, parking
            // this connection thread forever. The late signal/store is harmless.
            if semaphore.wait(timeout: .now() + Self.dispatchTimeout) == .timedOut {
                return .failure(code: "timeout", message: "command timed out")
            }
            return box.take() ?? .failure(code: "internal_error", message: "dispatch produced no response")
        }
    }

    // MARK: - State access (lock-guarded)

    private func running() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return isRunning
    }

    // Registers a client fd for shutdown-on-stop. Returns false (caller closes
    // the fd) if we've already stopped, so a connection accepted during the
    // teardown window is dropped cleanly.
    private func track(_ fd: Int32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard isRunning else { return false }
        clientFDs.insert(fd)
        return true
    }

    // The sole closer of a client fd. Closes only if the fd is still tracked, so
    // it runs exactly once even when stop() has shutdown() the fd concurrently —
    // both take the lock, so close() and stop()'s shutdown() can't interleave
    // into a close-then-reuse-then-shutdown race.
    private func closeClient(_ fd: Int32) {
        lock.lock()
        let wasTracked = clientFDs.remove(fd) != nil
        lock.unlock()
        if wasTracked { close(fd) }
    }

    // MARK: - Socket write

    private func writeLine(_ string: String, to fd: Int32) {
        let bytes = Array(string.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { raw in
                write(fd, raw.baseAddress, raw.count)
            }
            if written > 0 { offset += written; continue }
            // EINTR/EAGAIN are transient — retry rather than truncate the JSON
            // line (which would corrupt the client's parse). SO_NOSIGPIPE makes
            // a gone peer return EPIPE here instead of crashing the process.
            if written < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            logEvent("AI control: response write abandoned (errno \(errno)).")
            return
        }
    }

    private func logEvent(_ message: String) {
        log.info("\(message, privacy: .public)")
        let appState = self.appState
        Task { @MainActor in appState.addLog(message) }
    }
}

// One-shot box handing the dispatch result from the MainActor Task back to the
// blocked connection thread. The semaphore establishes the happens-before edge
// (store on MainActor → signal → wait → take), so a plain lock around the value
// is enough; @unchecked Sendable documents that the synchronization is manual.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CommandResponse?

    func store(_ response: CommandResponse) {
        lock.lock(); defer { lock.unlock() }
        value = response
    }

    func take() -> CommandResponse? {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
