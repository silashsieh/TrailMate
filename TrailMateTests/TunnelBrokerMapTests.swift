import Foundation
import Testing
@testable import TrailMate

// Every response is supplied in memory. The broker never opens the localhost
// tunneld URL, creates a control file, or invokes the privileged launcher.
@MainActor
struct TunnelBrokerMapTests {
    private final class MapFeed {
        var responses: [Data]
        private(set) var reads = 0

        init(_ rows: [String]) { responses = rows.map { Data($0.utf8) } }

        func next() -> Data {
            reads += 1
            return responses.removeFirst()
        }
    }

    private func broker(feed: MapFeed, clock: ManualMonotonicClock, timeout: Duration = .seconds(15)) -> TunnelBroker {
        TunnelBroker(
            controlDirectory: isolatedControlDirectory(),
            time: clock.timeSource,
            endpointPollInterval: .milliseconds(600),
            endpointTimeout: timeout,
            mapResponse: { feed.next() }
        )
    }

    private func isolatedControlDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TrailMate-WP5B-\(UUID().uuidString)", isDirectory: true)
    }

    private func tick(_ clock: ManualMonotonicClock) async {
        var parked = false
        for _ in 0..<2_000 {
            if clock.pendingSleepCount == 1 { parked = true; break }
            await Task.yield()
        }
        #expect(parked, "endpoint resolver should be waiting on the manual clock")
        clock.advance(by: .milliseconds(600))
    }

    @Test func selectsTheRequestedUDIDAndPrefersUsbmuxOverEarlierWiFi() async throws {
        let row = #"{"OTHER":[{"tunnel-address":"other","tunnel-port":1,"interface":"usbmux-OTHER-Network"}],"A":[{"tunnel-address":"wifi","tunnel-port":2,"interface":"wifi"},{"tunnel-address":"usb","tunnel-port":3,"interface":"usbmux-A-Network"}]}"#
        let feed = MapFeed([row, row, row])
        let clock = ManualMonotonicClock()
        let task = Task { try await broker(feed: feed, clock: clock).rsdEndpoint(udid: "A") }
        await tick(clock)
        await tick(clock)
        let endpoint = try await task.value
        #expect(endpoint.address == "usb")
        #expect(endpoint.port == 3)
        #expect(feed.reads == 3)
    }

    @Test func fallsBackToFirstUsableEntryWhenThereIsNoUsbmux() async throws {
        let row = #"{"A":[{"tunnel-address":"wifi-first","tunnel-port":4,"interface":"wifi"},{"tunnel-address":"wifi-second","tunnel-port":5,"interface":"wifi"}]}"#
        let feed = MapFeed([row, row, row])
        let clock = ManualMonotonicClock()
        let task = Task { try await broker(feed: feed, clock: clock).rsdEndpoint(udid: "A") }
        await tick(clock)
        await tick(clock)
        let endpoint = try await task.value
        #expect(endpoint.address == "wifi-first")
        #expect(endpoint.port == 4)
    }

    @Test func missingAndMalformedEntriesAreSkippedUntilTheEndpointStabilizes() async throws {
        let missing = #"{"OTHER":[],"A":[{"tunnel-port":3},{"tunnel-address":"bad"}]}"#
        let stable = #"{"A":[{"tunnel-address":"ready","tunnel-port":6,"interface":"usbmux-A-Network"}]}"#
        let feed = MapFeed([missing, stable, stable, stable])
        let clock = ManualMonotonicClock()
        let task = Task { try await broker(feed: feed, clock: clock).rsdEndpoint(udid: "A") }
        await tick(clock)
        await tick(clock)
        await tick(clock)
        let endpoint = try await task.value
        #expect(endpoint.address == "ready")
        #expect(endpoint.port == 6)
        #expect(feed.reads == 4)
    }

    @Test func endpointRotationResetsTheStabilityCounter() async throws {
        let transient = #"{"A":[{"tunnel-address":"old","tunnel-port":7}]}"#
        let rotated = #"{"A":[{"tunnel-address":"new","tunnel-port":8}]}"#
        let feed = MapFeed([transient, transient, rotated, rotated, rotated])
        let clock = ManualMonotonicClock()
        let task = Task { try await broker(feed: feed, clock: clock).rsdEndpoint(udid: "A") }
        for _ in 0..<4 { await tick(clock) }
        let endpoint = try await task.value
        #expect(endpoint.address == "new")
        #expect(endpoint.port == 8)
        #expect(feed.reads == 5)
    }

    @Test func noValidEntryReportsTheRequestedDeviceAfterManualTimeout() async {
        let feed = MapFeed([#"{"OTHER":[],"A":[{"tunnel-address":"missing-port"}]}"#, #"{"OTHER":[]}"#])
        let clock = ManualMonotonicClock()
        let task = Task { try await broker(feed: feed, clock: clock, timeout: .milliseconds(1_200)).rsdEndpoint(udid: "A") }
        await tick(clock)
        await tick(clock)
        do {
            _ = try await task.value
            Issue.record("Expected a missing-tunnel error")
        } catch TunnelError.startFailed(let message) {
            #expect(message.contains("device A has no tunnel yet"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(feed.reads == 2)
    }

    @Test func rotatingEndpointTimesOutToItsMostRecentReading() async throws {
        let first = #"{"A":[{"tunnel-address":"old","tunnel-port":7}]}"#
        let second = #"{"A":[{"tunnel-address":"new","tunnel-port":8}]}"#
        let feed = MapFeed([first, second])
        let clock = ManualMonotonicClock()
        let task = Task { try await broker(feed: feed, clock: clock, timeout: .milliseconds(1_200)).rsdEndpoint(udid: "A") }
        await tick(clock)
        await tick(clock)
        let endpoint = try await task.value
        #expect(endpoint.address == "new")
        #expect(endpoint.port == 8)
        #expect(feed.reads == 2)
    }

    @Test func malformedTopLevelAndFetchErrorsArePropagated() async {
        let malformed = MapFeed(["[]"])
        let clock = ManualMonotonicClock()
        do {
            _ = try await broker(feed: malformed, clock: clock).rsdEndpoint(udid: "A")
            Issue.record("Expected a parse error")
        } catch TunnelError.parseFailed(let message) {
            #expect(message.contains("not a JSON object"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        let expected = URLError(.cannotConnectToHost)
        let failed = TunnelBroker(
            controlDirectory: isolatedControlDirectory(),
            time: clock.timeSource,
            mapResponse: { throw expected }
        )
        do {
            _ = try await failed.rsdEndpoint(udid: "A")
            Issue.record("Expected the map-fetch error")
        } catch let error as URLError {
            #expect(error.code == .cannotConnectToHost)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
