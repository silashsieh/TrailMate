import Foundation

// Resolves (and creates the directory for) the AF_UNIX socket the AI control
// server listens on. Lives under Application Support so it's per-user and not
// world-writable, which is the whole auth model: filesystem permissions, no
// network port (epic 019 — the Unix socket has no browser-reachable attack
// surface a TCP port would).
// nonisolated: pure path computation called from CommandServer's background
// threads (default main-actor isolation would otherwise trap it off-main).
nonisolated enum SocketPath {
    enum Error: LocalizedError {
        case unresolvedSupportDirectory
        case pathTooLong(length: Int, max: Int)

        var errorDescription: String? {
            switch self {
            case .unresolvedSupportDirectory:
                return "Could not resolve the Application Support directory."
            case .pathTooLong(let length, let max):
                return "Socket path is \(length) bytes; the AF_UNIX limit is \(max - 1)."
            }
        }
    }

    // sockaddr_un.sun_path is a fixed C array; on Darwin it is 104 bytes and the
    // stored path must be NUL-terminated, so the usable path is < 104 bytes.
    // bind() fails opaquely past this, so we check up front with a clear error.
    static let maxSunPathBytes = 104

    static let directoryName = "TrailMate"
    static let socketFileName = "ai.sock"

    // The resolved socket path, creating the containing directory if needed.
    // Throws rather than returning a path bind() would reject, so the server's
    // start() surfaces a real reason in the log instead of a silent failure.
    static func resolve() throws -> String {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw Error.unresolvedSupportDirectory
        }
        let dir = support.appendingPathComponent(directoryName, isDirectory: true)
        // Owner-only — the socket's auth model is filesystem permissions.
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])

        let socketURL = dir.appendingPathComponent(socketFileName, isDirectory: false)
        let path = socketURL.path

        // Byte length (UTF-8) plus the NUL terminator must fit sun_path.
        let byteLength = path.utf8.count
        guard byteLength + 1 <= maxSunPathBytes else {
            throw Error.pathTooLong(length: byteLength + 1, max: maxSunPathBytes)
        }
        return path
    }

    // Best-effort resolution that never throws — for display in Settings, where
    // a hard failure would be worse than showing the intended path. Falls back
    // to the conventional location string if resolution fails.
    static func displayPath() -> String {
        (try? resolve()) ?? "~/Library/Application Support/\(directoryName)/\(socketFileName)"
    }
}
