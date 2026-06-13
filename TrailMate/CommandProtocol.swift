import Foundation

// The line-delimited command protocol the AI control socket speaks. Modeled on
// tm_daemon.py's text protocol (one verb per line, space-separated args) so the
// surface stays debuggable with `nc -U` / `cat`. This file is a pure value
// layer: parsing and response encoding, no I/O — the socket server and AppState
// own the transport and dispatch.
//
// Every device-scoped verb carries the target UDID as its first argument. This
// is deliberate: AI is a command *source*, never a parallel state owner, and a
// multi-device future (epic 012) needs each command to name its device rather
// than lean on a GUI-focus selection an agent can't see.

// Protocol version. Bumped when the wire format changes incompatibly; the
// greeting line advertises it so a client can refuse a mismatch. Verbs are not
// individually versioned (epic 019 decision).
nonisolated enum AIProtocol {
    static let version = 1
}

// One parsed command. Device-scoped cases carry the UDID so dispatch can match
// it against the connected session without consulting the GUI's selection.
nonisolated enum Command: Equatable {
    case devices
    case status
    case teleport(udid: String, latitude: Double, longitude: Double)
    case route(udid: String, coordinates: [Coordinate])
    case play(udid: String)
    case pause(udid: String)
    case stop(udid: String)
    case clear(udid: String)
    case seek(udid: String, progress: Double)
    case connect(udid: String)
    case disconnect(udid: String)

    // A plain lat/lon pair. Not CLLocationCoordinate2D so this layer stays
    // Foundation-only and trivially Equatable for tests.
    struct Coordinate: Equatable {
        var latitude: Double
        var longitude: Double
    }
}

// Why parsing fails. Carried back to the client as an ERR-style response so an
// agent gets an actionable message rather than a dropped connection.
nonisolated enum CommandParseError: Error, Equatable {
    case empty
    case unknownVerb(String)
    case missingArguments(verb: String)
    case invalidNumber(String)
    case oddCoordinateCount

    var message: String {
        switch self {
        case .empty:
            return "empty command"
        case .unknownVerb(let verb):
            return "unknown command '\(verb)'"
        case .missingArguments(let verb):
            return "'\(verb)' is missing arguments"
        case .invalidNumber(let token):
            return "'\(token)' is not a number"
        case .oddCoordinateCount:
            return "route expects an even number of lat/lon values"
        }
    }
}

nonisolated extension Command {
    // Parse one protocol line. Whitespace-tolerant; verb is case-insensitive
    // (UDIDs and numbers are not). Returns a Result so the caller can render a
    // clean ERR line for a bad command instead of throwing across the socket.
    static func parse(_ line: String) -> Result<Command, CommandParseError> {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let verb = tokens.first else {
            return .failure(.empty)
        }
        let args = Array(tokens.dropFirst())
        let upper = verb.uppercased()

        switch upper {
        case "DEVICES":
            return .success(.devices)
        case "STATUS":
            return .success(.status)

        case "TELEPORT":
            // TELEPORT <udid> <lat> <lon>
            guard args.count >= 3 else { return .failure(.missingArguments(verb: upper)) }
            guard let lat = Double(args[1]) else { return .failure(.invalidNumber(args[1])) }
            guard let lon = Double(args[2]) else { return .failure(.invalidNumber(args[2])) }
            return .success(.teleport(udid: args[0], latitude: lat, longitude: lon))

        case "ROUTE":
            // ROUTE <udid> <lat0> <lon0> <lat1> <lon1> ...
            guard let udid = args.first else { return .failure(.missingArguments(verb: upper)) }
            let nums = Array(args.dropFirst())
            // Oddness first: "ROUTE dev a b c" (3 values) is a malformed pair,
            // reported as such; an even-but-too-few count (0 or 2) falls through
            // to the clearer "missing arguments".
            guard nums.count.isMultiple(of: 2) else { return .failure(.oddCoordinateCount) }
            guard nums.count >= 4 else { return .failure(.missingArguments(verb: upper)) }
            var coords: [Coordinate] = []
            coords.reserveCapacity(nums.count / 2)
            var i = 0
            while i < nums.count {
                guard let lat = Double(nums[i]) else { return .failure(.invalidNumber(nums[i])) }
                guard let lon = Double(nums[i + 1]) else { return .failure(.invalidNumber(nums[i + 1])) }
                coords.append(Coordinate(latitude: lat, longitude: lon))
                i += 2
            }
            return .success(.route(udid: udid, coordinates: coords))

        case "PLAY", "PAUSE", "STOP", "CLEAR", "CONNECT", "DISCONNECT":
            guard let udid = args.first else { return .failure(.missingArguments(verb: upper)) }
            switch upper {
            case "PLAY": return .success(.play(udid: udid))
            case "PAUSE": return .success(.pause(udid: udid))
            case "STOP": return .success(.stop(udid: udid))
            case "CONNECT": return .success(.connect(udid: udid))
            case "DISCONNECT": return .success(.disconnect(udid: udid))
            default: return .success(.clear(udid: udid))
            }

        case "SEEK":
            // SEEK <udid> <progress 0…1>
            guard args.count >= 2 else { return .failure(.missingArguments(verb: upper)) }
            guard let progress = Double(args[1]) else { return .failure(.invalidNumber(args[1])) }
            return .success(.seek(udid: args[0], progress: progress))

        default:
            return .failure(.unknownVerb(verb))
        }
    }
}

// A heterogeneous JSON value for the `data` payload — lets STATUS/DEVICES carry
// nested objects and arrays without a bespoke Codable struct per command. Only
// the cases the command surface needs; extend as the protocol grows.
nonisolated enum JSONValue: Encodable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .null: try container.encodeNil()
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }
}

// One JSON line written back per command. `ok` says the command was accepted
// (not necessarily completed — most simulation moves are fire-and-forget; read
// STATUS for the realized state). `code` is a stable machine token for failures
// (e.g. "unknown_device", "not_connected"); `error` is its human message.
nonisolated struct CommandResponse: Encodable, Equatable {
    var ok: Bool
    var code: String?
    var data: JSONValue?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case ok, code, data, error
    }

    // Custom so absent optionals are *omitted*, not emitted as JSON null —
    // keeps the line compact and unambiguous for the agent parsing it.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(ok, forKey: .ok)
        try container.encodeIfPresent(code, forKey: .code)
        try container.encodeIfPresent(data, forKey: .data)
        try container.encodeIfPresent(error, forKey: .error)
    }

    static func success(_ data: JSONValue? = nil) -> CommandResponse {
        CommandResponse(ok: true, code: nil, data: data, error: nil)
    }

    static func failure(code: String, message: String) -> CommandResponse {
        CommandResponse(ok: false, code: code, data: nil, error: message)
    }

    // Single-line JSON plus a trailing newline — the unit the socket writes and
    // the client reads one command-response at a time. JSONEncoder default
    // output is already newline-free; we add exactly one terminator.
    func line() -> String {
        let encoder = JSONEncoder()
        // Stable key order so tests and human readers see a predictable shape.
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            // Encoding a fixed small struct cannot realistically fail; fall back
            // to a hand-built error line rather than crash the connection.
            return "{\"error\":\"encode_failed\",\"ok\":false}\n"
        }
        return json + "\n"
    }
}

// The line emitted to a client the moment it connects, before any command. Lets
// the agent confirm it reached TrailMate (not some other Unix socket) and learn
// the protocol version in one read.
nonisolated func aiGreetingLine() -> String {
    let response = CommandResponse.success(.object([
        "service": .string("trailmate"),
        "protocol": .int(AIProtocol.version)
    ]))
    return response.line()
}
