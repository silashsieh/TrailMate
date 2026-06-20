import CoreLocation
import Testing
@testable import TrailMate

// Covers the decimal-degree parsing/formatting behind direct location entry
// (epic 027, #52): accepted separator variants, range/garbage rejection, and
// the format→parse round trip the copy/paste flow depends on.
struct CoordinateFormatTests {
    @Test func parsesCommaSeparatedPair() throws {
        let coord = try #require(CoordinateFormat.parse("25.0330, 121.5654"))
        #expect(abs(coord.latitude - 25.0330) < 1e-9)
        #expect(abs(coord.longitude - 121.5654) < 1e-9)
    }

    @Test func parsesWithoutSpaceAfterComma() throws {
        let coord = try #require(CoordinateFormat.parse("25.0330,121.5654"))
        #expect(abs(coord.latitude - 25.0330) < 1e-9)
        #expect(abs(coord.longitude - 121.5654) < 1e-9)
    }

    @Test func parsesWhitespaceSeparatedPair() throws {
        let coord = try #require(CoordinateFormat.parse("  25.0330   121.5654 "))
        #expect(abs(coord.latitude - 25.0330) < 1e-9)
        #expect(abs(coord.longitude - 121.5654) < 1e-9)
    }

    @Test func parsesNegativeAndSignedValues() throws {
        let coord = try #require(CoordinateFormat.parse("-33.8688, +151.2093"))
        #expect(abs(coord.latitude - -33.8688) < 1e-9)
        #expect(abs(coord.longitude - 151.2093) < 1e-9)
    }

    @Test func parsesBoundaryValues() throws {
        #expect(CoordinateFormat.parse("90, 180") != nil)
        #expect(CoordinateFormat.parse("-90, -180") != nil)
        #expect(CoordinateFormat.parse("0, 0") != nil)
    }

    @Test func rejectsOutOfRange() {
        #expect(CoordinateFormat.parse("91, 0") == nil)        // lat > 90
        #expect(CoordinateFormat.parse("-90.1, 0") == nil)     // lat < -90
        #expect(CoordinateFormat.parse("0, 181") == nil)       // lon > 180
        #expect(CoordinateFormat.parse("0, -181") == nil)      // lon < -180
    }

    @Test func rejectsGarbageAndWrongCardinality() {
        #expect(CoordinateFormat.parse("") == nil)
        #expect(CoordinateFormat.parse("   ") == nil)
        #expect(CoordinateFormat.parse("hello") == nil)
        #expect(CoordinateFormat.parse("25.0330") == nil)              // one value
        #expect(CoordinateFormat.parse("25.0, 121.5, 30") == nil)      // three values
        #expect(CoordinateFormat.parse("25.0,, 121.5") == nil)         // empty middle field
        #expect(CoordinateFormat.parse("abc, def") == nil)
        #expect(CoordinateFormat.parse("1e999, 0") == nil)             // non-finite
    }

    @Test func formatRoundTrips() throws {
        let original = CLLocationCoordinate2D(latitude: 25.033956, longitude: 121.565421)
        let string = CoordinateFormat.string(from: original)
        let parsed = try #require(CoordinateFormat.parse(string))
        #expect(abs(parsed.latitude - original.latitude) < 1e-6)
        #expect(abs(parsed.longitude - original.longitude) < 1e-6)
    }

    @Test func formatUsesCommaSeparatedDecimalDegrees() {
        let string = CoordinateFormat.string(from: CLLocationCoordinate2D(latitude: 1.5, longitude: -2.25))
        #expect(string == "1.500000, -2.250000")
    }
}
