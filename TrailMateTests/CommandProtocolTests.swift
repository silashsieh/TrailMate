import Foundation
import Testing
@testable import TrailMate

// Covers the pure command layer: parse() success/failure and CommandResponse's
// single-line JSON shape (optionals omitted, trailing newline). The dispatch
// path is integration-tested elsewhere; this file pins the wire format.
struct CommandProtocolTests {

    // MARK: - parse: success

    @Test func parsesDevicesAndStatus() {
        #expect(Command.parse("DEVICES") == .success(.devices))
        #expect(Command.parse("STATUS") == .success(.status))
    }

    @Test func verbIsCaseInsensitive() {
        #expect(Command.parse("devices") == .success(.devices))
        #expect(Command.parse("Status") == .success(.status))
    }

    @Test func parsesTeleport() {
        let result = Command.parse("TELEPORT ABC123 25.0339 121.5645")
        #expect(result == .success(.teleport(udid: "ABC123", latitude: 25.0339, longitude: 121.5645)))
    }

    @Test func parsesNegativeAndDecimalCoordinates() {
        let result = Command.parse("TELEPORT dev -33.8688 151.2093")
        #expect(result == .success(.teleport(udid: "dev", latitude: -33.8688, longitude: 151.2093)))
    }

    @Test func parsesRouteWithMultipleCoordinates() {
        let result = Command.parse("ROUTE dev 25.0 121.0 25.1 121.1 25.2 121.2")
        let expected = Command.route(udid: "dev", coordinates: [
            .init(latitude: 25.0, longitude: 121.0),
            .init(latitude: 25.1, longitude: 121.1),
            .init(latitude: 25.2, longitude: 121.2)
        ])
        #expect(result == .success(expected))
    }

    @Test func parsesPlaybackVerbs() {
        #expect(Command.parse("PLAY dev") == .success(.play(udid: "dev")))
        #expect(Command.parse("PAUSE dev") == .success(.pause(udid: "dev")))
        #expect(Command.parse("STOP dev") == .success(.stop(udid: "dev")))
        #expect(Command.parse("CLEAR dev") == .success(.clear(udid: "dev")))
    }

    @Test func parsesConnectDisconnect() {
        #expect(Command.parse("CONNECT 00008110-0005442826C3801E")
            == .success(.connect(udid: "00008110-0005442826C3801E")))
        #expect(Command.parse("DISCONNECT dev") == .success(.disconnect(udid: "dev")))
        #expect(Command.parse("CONNECT") == .failure(.missingArguments(verb: "CONNECT")))
        #expect(Command.parse("DISCONNECT") == .failure(.missingArguments(verb: "DISCONNECT")))
    }

    @Test func parsesSeek() {
        #expect(Command.parse("SEEK dev 0.5") == .success(.seek(udid: "dev", progress: 0.5)))
    }

    @Test func toleratesExtraWhitespace() {
        let result = Command.parse("  TELEPORT   dev   1.0    2.0  ")
        #expect(result == .success(.teleport(udid: "dev", latitude: 1.0, longitude: 2.0)))
    }

    @Test func udidCaseIsPreserved() {
        // Verb folds to upper, but the UDID must round-trip exactly.
        let result = Command.parse("teleport MixedCaseUDID 1.0 2.0")
        #expect(result == .success(.teleport(udid: "MixedCaseUDID", latitude: 1.0, longitude: 2.0)))
    }

    // MARK: - parse: failure

    @Test func emptyLineFails() {
        #expect(Command.parse("") == .failure(.empty))
        #expect(Command.parse("    ") == .failure(.empty))
    }

    @Test func unknownVerbFails() {
        #expect(Command.parse("WANDER dev") == .failure(.unknownVerb("WANDER")))
    }

    @Test func teleportMissingArgsFails() {
        #expect(Command.parse("TELEPORT dev 25.0") == .failure(.missingArguments(verb: "TELEPORT")))
        #expect(Command.parse("TELEPORT") == .failure(.missingArguments(verb: "TELEPORT")))
    }

    @Test func teleportNonNumericFails() {
        #expect(Command.parse("TELEPORT dev north 121.0") == .failure(.invalidNumber("north")))
    }

    @Test func routeOddCoordinateCountFails() {
        #expect(Command.parse("ROUTE dev 25.0 121.0 25.1") == .failure(.oddCoordinateCount))
    }

    @Test func routeTooFewCoordinatesFails() {
        // One coordinate pair is not enough for a route (need >= 2 points).
        #expect(Command.parse("ROUTE dev 25.0 121.0") == .failure(.missingArguments(verb: "ROUTE")))
        #expect(Command.parse("ROUTE dev") == .failure(.missingArguments(verb: "ROUTE")))
    }

    @Test func playMissingUDIDFails() {
        #expect(Command.parse("PLAY") == .failure(.missingArguments(verb: "PLAY")))
    }

    @Test func seekMissingProgressFails() {
        #expect(Command.parse("SEEK dev") == .failure(.missingArguments(verb: "SEEK")))
    }

    // MARK: - CommandResponse.line()

    @Test func successLineOmitsOptionals() {
        let line = CommandResponse.success().line()
        #expect(line.hasSuffix("\n"))
        #expect(!line.dropLast().contains("\n"))   // single line
        let json = line.trimmingCharacters(in: .newlines)
        // Only `ok` should be present; code/data/error omitted, not null.
        #expect(json == "{\"ok\":true}")
    }

    @Test func failureLineCarriesCodeAndError() {
        let line = CommandResponse.failure(code: "unknown_device", message: "no device").line()
        let json = line.trimmingCharacters(in: .newlines)
        // sortedKeys ordering: code, error, ok.
        #expect(json == "{\"code\":\"unknown_device\",\"error\":\"no device\",\"ok\":false}")
        #expect(!json.contains("\"data\""))
    }

    @Test func successLineWithDataEncodesObject() throws {
        let response = CommandResponse.success(.object([
            "protocol": .int(1),
            "devices": .array([])
        ]))
        let line = response.line()
        #expect(line.hasSuffix("\n"))
        let data = Data(line.trimmingCharacters(in: .newlines).utf8)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["ok"] as? Bool == true)
        let payload = try #require(obj["data"] as? [String: Any])
        #expect(payload["protocol"] as? Int == 1)
        #expect((payload["devices"] as? [Any])?.isEmpty == true)
    }

    @Test func greetingLineAdvertisesProtocol() throws {
        let line = aiGreetingLine()
        #expect(line.hasSuffix("\n"))
        let data = Data(line.trimmingCharacters(in: .newlines).utf8)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["ok"] as? Bool == true)
        let payload = try #require(obj["data"] as? [String: Any])
        #expect(payload["service"] as? String == "trailmate")
        #expect(payload["protocol"] as? Int == AIProtocol.version)
    }

    @Test func jsonValueEncodesEachCase() throws {
        // Guards against a future case being added to the encoder without a test.
        func encode(_ value: JSONValue) throws -> String {
            let data = try JSONEncoder().encode(value)
            return String(data: data, encoding: .utf8) ?? ""
        }
        #expect(try encode(.string("x")) == "\"x\"")
        #expect(try encode(.int(3)) == "3")
        #expect(try encode(.bool(true)) == "true")
        #expect(try encode(.null) == "null")
        #expect(try encode(.array([.int(1), .int(2)])) == "[1,2]")
    }
}
