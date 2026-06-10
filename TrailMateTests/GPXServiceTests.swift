import CoreLocation
import Testing
@testable import TrailMate

// GPXService inherits the app module's MainActor default isolation, so the
// suite runs on the main actor rather than loosening the production type.
@MainActor
struct GPXServiceTests {
    private let coords = [
        CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654),
        CLLocationCoordinate2D(latitude: 25.0339, longitude: 121.5645),
        CLLocationCoordinate2D(latitude: 25.0478, longitude: 121.5170),
        CLLocationCoordinate2D(latitude: -33.8568, longitude: 151.2153),
    ]
    // A fixed whole-second date: ISO 8601 timestamps carry second precision,
    // so round-trips are only exact on whole seconds.
    private let startTime = Date(timeIntervalSince1970: 1_780_000_000)

    @Test func roundTripPreservesCoordinates() {
        let xml = GPXService.generate(coordinates: coords, speedMPS: 1.4, startTime: startTime)
        let parsed = GPXService.parse(data: Data(xml.utf8))
        #expect(parsed.count == coords.count)
        for (original, restored) in zip(coords, parsed) {
            #expect(abs(original.latitude - restored.latitude) < 1e-9)
            #expect(abs(original.longitude - restored.longitude) < 1e-9)
        }
    }

    @Test func roundTripTimestampedPreservesPointsAndTimes() {
        let points = [
            RecorderService.Point(timestamp: startTime, latitude: 25.0330, longitude: 121.5654),
            RecorderService.Point(timestamp: startTime.addingTimeInterval(10), latitude: 25.0335, longitude: 121.5650),
            RecorderService.Point(timestamp: startTime.addingTimeInterval(25), latitude: 25.0340, longitude: 121.5645),
        ]
        let xml = GPXService.generate(timestamped: points)
        let parsed = GPXService.parseTimestamped(data: Data(xml.utf8))
        #expect(parsed.count == points.count)
        for (original, restored) in zip(points, parsed) {
            #expect(abs(restored.0.timeIntervalSince(original.timestamp)) < 0.5)
            #expect(abs(original.latitude - restored.1.latitude) < 1e-9)
            #expect(abs(original.longitude - restored.1.longitude) < 1e-9)
        }
    }

    @Test func generateSpacesTimestampsBySpeed() throws {
        // Two points ~100 m apart at 10 m/s should be ~10 s apart; allow the
        // formatter's whole-second truncation plus flat-vs-geodesic slack.
        let a = CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654)
        let b = CLLocationCoordinate2D(latitude: 25.0330 + 100.0 / 111_320.0, longitude: 121.5654)
        let xml = GPXService.generate(coordinates: [a, b], speedMPS: 10, startTime: startTime)
        let parsed = GPXService.parseTimestamped(data: Data(xml.utf8))
        try #require(parsed.count == 2)
        // The geodesic gap is ~99.5 m → Δt = 9.95 s, which the formatter
        // truncates to 9; accept 10 too in case it ever rounds instead.
        let delta = try #require(parsed.last).0.timeIntervalSince(try #require(parsed.first).0)
        #expect(delta == 9 || delta == 10)
    }

    @Test func parseAcceptsTrkptAndRteptPoints() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="other-tool">
          <wpt lat="25.0330" lon="121.5654"></wpt>
          <trk><trkseg><trkpt lat="25.0339" lon="121.5645"></trkpt></trkseg></trk>
          <rte><rtept lat="25.0478" lon="121.5170"></rtept></rte>
        </gpx>
        """
        let parsed = GPXService.parse(data: Data(xml.utf8))
        try #require(parsed.count == 3)
        #expect(abs(parsed[1].latitude - 25.0339) < 1e-9)
        #expect(abs(parsed[2].longitude - 121.5170) < 1e-9)
    }

    @Test func parseSkipsMalformedPointsAndEmptyInput() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="other-tool">
          <wpt lat="25.0330" lon="121.5654"></wpt>
          <wpt lat="25.0339"></wpt>
          <wpt lat="not-a-number" lon="121.5170"></wpt>
        </gpx>
        """
        let parsed = GPXService.parse(data: Data(xml.utf8))
        #expect(parsed.count == 1)

        let empty = GPXService.generate(coordinates: [], speedMPS: 1.4, startTime: startTime)
        #expect(GPXService.parse(data: Data(empty.utf8)).isEmpty)
    }
}
