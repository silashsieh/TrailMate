import CoreLocation

// Decimal-degree coordinate parsing and formatting for direct location entry
// (epic 027, #52). Decimal degrees only — DMS is out of scope. Pure and
// nonisolated so the same code the UI uses is unit-testable without the app
// running, and `string(from:)` round-trips back through `parse`.
enum CoordinateFormat {
    // Parse "lat, lon" in decimal degrees. Tolerant of surrounding whitespace
    // and either a comma or whitespace between the two numbers (so "25.03,
    // 121.56", "25.03,121.56", and "25.03 121.56" all parse). Returns nil
    // unless the text is exactly two finite numbers with lat ∈ [-90, 90] and
    // lon ∈ [-180, 180].
    nonisolated static func parse(_ string: String) -> CLLocationCoordinate2D? {
        let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        // A comma is the canonical separator; fall back to whitespace so a
        // space-separated pair still works. Empty subsequences are kept on the
        // comma path so "25,," reads as three parts and is rejected, not two.
        let rawParts: [Substring] = cleaned.contains(",")
            ? cleaned.split(separator: ",", omittingEmptySubsequences: false)
            : cleaned.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard rawParts.count == 2 else { return nil }

        guard let lat = Double(String(rawParts[0]).trimmingCharacters(in: .whitespaces)),
              let lon = Double(String(rawParts[1]).trimmingCharacters(in: .whitespaces)),
              lat.isFinite, lon.isFinite,
              (-90.0...90.0).contains(lat),
              (-180.0...180.0).contains(lon) else { return nil }

        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    // A paste-able "lat, lon" string at ~0.1 m precision (6 fractional digits),
    // matching the comma-separated form `parse` accepts so a copied coordinate
    // pastes straight back into the entry field.
    nonisolated static func string(from coordinate: CLLocationCoordinate2D) -> String {
        String(format: "%.6f, %.6f", coordinate.latitude, coordinate.longitude)
    }
}
