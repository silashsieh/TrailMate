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
        let clients = clientFDs
        clientFDs.removeAll()
        lock.unlock()

        // Closing the listen fd unblocks the accept() in the loop, which then
        // sees isRunning == false and exits its dedicated thread.
        if fd >= 0 { close(fd) }
        // shutdown() (not close) reliably wakes a read() blocked on a client fd
        // without the fd-reuse race a bare close would invite; the connection
        // thread then sees read() return 0/-1 and closes the fd itself.
        for client in clients {
            shutdown(client, SHUT_RDWR)
        }
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
            // One blocking read loop per connection, off on a concurrent thread
            // so accept() can immediately return to listening.
            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.handleConnection(clientFD)
            }
        }
    }

    // MARK: - Connection handling

    private func handleConnection(_ clientFD: Int32) {
        defer {
            untrack(clientFD)
            close(clientFD)
        }

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
            semaphore.wait()
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

    private func untrack(_ fd: Int32) {
        lock.lock(); defer { lock.unlock() }
        clientFDs.remove(fd)
    }

    // MARK: - Socket write

    private func writeLine(_ string: String, to fd: Int32) {
        let bytes = Array(string.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { raw in
                write(fd, raw.baseAddress, raw.count)
            }
            if written <= 0 { break }   // peer gone; abandon this connection
            offset += written
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
