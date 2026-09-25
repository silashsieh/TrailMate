import Darwin
import Foundation

// The single write boundary for a daemon's stdin. Foundation's FileHandle
// ultimately writes to the same descriptor, but using Darwin.write here keeps
// EPIPE, EINTR, and partial-write handling explicit and testable.
nonisolated final class DaemonInputWriter: @unchecked Sendable {
    enum ActivationError: Error, Equatable {
        case cannotSuppressSIGPIPE(errno: Int32)
    }

    enum WriteResult: Equatable {
        case written
        case inactive
        case failed(SimulationBackendFailure)
    }

    private let queue = DispatchQueue(label: "TrailMate.DaemonBridge.write")
    private var fileDescriptor: Int32?

    func activate(_ handle: FileHandle) throws {
        try queue.sync {
            let fd = handle.fileDescriptor
            guard fcntl(fd, F_SETNOSIGPIPE, 1) != -1 else {
                throw ActivationError.cannotSuppressSIGPIPE(errno: errno)
            }
            fileDescriptor = fd
        }
    }

    func deactivate() {
        queue.sync { fileDescriptor = nil }
    }

    @discardableResult
    func writeLine(_ line: String) -> WriteResult {
        queue.sync {
            guard let fd = fileDescriptor else { return .inactive }
            let data = Data((line + "\n").utf8)
            var offset = 0

            return data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return .written }
                while offset < rawBuffer.count {
                    let result = Darwin.write(fd, base.advanced(by: offset), rawBuffer.count - offset)
                    if result > 0 {
                        offset += result
                        continue
                    }
                    if result == -1, errno == EINTR { continue }

                    // A zero-byte write for a nonempty buffer cannot make
                    // progress; do not report a stale errno from an earlier
                    // syscall or spin forever.
                    let code = result == 0 ? EIO : errno
                    // The first failed write closes this logical channel. Every
                    // later SET/SETQ/QUIT sees inactive and performs no syscall.
                    fileDescriptor = nil
                    if code == EPIPE {
                        return .failed(.brokenPipe)
                    }
                    return .failed(.writeFailed(errno: code))
                }
                return .written
            }
        }
    }
}
