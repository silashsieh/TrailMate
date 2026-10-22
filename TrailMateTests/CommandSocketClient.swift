import Darwin
import Foundation

// A minimal AF_UNIX client for the socket suite. Every wait is a zero-timeout
// poll interleaved with Task.sleep, so a test never parks a thread: the
// server answers a command only after its MainActor hop runs the dispatcher,
// and a test that blocked the main thread while waiting would deadlock.
final class CommandSocketClient: @unchecked Sendable {
    enum ClientError: Error, Equatable {
        case connectFailed(errno: Int32)
        case writeFailed(errno: Int32)
        case timedOut
    }

    private var fd: Int32
    private var buffer = Data()

    init(path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.connectFailed(errno: errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            sunPath.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    dst.update(from: src.baseAddress!, count: src.count)
                }
            }
        }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            throw ClientError.connectFailed(errno: code)
        }

        // The server may close first (oversized input, stop()); a write to a
        // gone peer must surface as EPIPE, never as a fatal SIGPIPE in the
        // test host.
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        self.fd = fd
    }

    deinit {
        close()
    }

    func close() {
        guard fd >= 0 else { return }
        Darwin.close(fd)
        fd = -1
    }

    func send(_ string: String, timeout: Duration = .seconds(3)) async throws {
        try await send(bytes: Array(string.utf8), timeout: timeout)
    }

    func send(bytes: [UInt8], timeout: Duration = .seconds(3)) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress, raw.count)
            }
            if written > 0 {
                offset += written
                continue
            }
            let code = errno
            guard written < 0, code == EAGAIN || code == EINTR else {
                throw ClientError.writeFailed(errno: code)
            }
            guard ContinuousClock.now < deadline else { throw ClientError.timedOut }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    // One line without its terminator; nil once the peer has closed and no
    // complete line remains. Throws timedOut when the deadline passes with the
    // connection still open — the "no further response" assertion.
    func readLine(timeout: Duration = .seconds(3)) async throws -> String? {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return String(decoding: line, as: UTF8.self)
            }
            let n = Darwin.read(fd, &chunk, chunk.count)
            if n > 0 {
                buffer.append(contentsOf: chunk[0..<n])
                continue
            }
            if n == 0 { return nil }
            let code = errno
            guard code == EAGAIN || code == EINTR else { return nil }
            guard ContinuousClock.now < deadline else { throw ClientError.timedOut }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    // True once the peer has closed (EOF) with nothing left to read.
    func awaitEOF(timeout: Duration = .seconds(3)) async throws -> Bool {
        try await readLine(timeout: timeout) == nil
    }
}
