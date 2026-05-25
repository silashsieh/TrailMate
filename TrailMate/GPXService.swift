import Foundation
import CoreLocation

enum GPXService {
    static func parse(data: Data) -> [CLLocationCoordinate2D] {
        let delegate = GPXParserDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.coordinates
    }

    static func generate(coordinates: [CLLocationCoordinate2D], speedMPS: Double, startTime: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<gpx version=\"1.1\" creator=\"TrailMate\">\n"

        var time = startTime
        var prev: CLLocationCoordinate2D?

        for coord in coordinates {
            if let p = prev {
                let dist = CLLocation(latitude: p.latitude, longitude: p.longitude)
                    .distance(from: CLLocation(latitude: coord.latitude, longitude: coord.longitude))
                time = time.addingTimeInterval(dist / speedMPS)
            }

            xml += "  <wpt lat=\"\(coord.latitude)\" lon=\"\(coord.longitude)\">\n"
            xml += "    <time>\(formatter.string(from: time))</time>\n"
            xml += "  </wpt>\n"
            prev = coord
        }

        xml += "</gpx>\n"
        return xml
    }

    static func generate(timestamped points: [RecorderService.Point]) -> String {
        let formatter = ISO8601DateFormatter()
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<gpx version=\"1.1\" creator=\"TrailMate\">\n"
        for p in points {
            xml += "  <wpt lat=\"\(p.latitude)\" lon=\"\(p.longitude)\">\n"
            xml += "    <time>\(formatter.string(from: p.timestamp))</time>\n"
            xml += "  </wpt>\n"
        }
        xml += "</gpx>\n"
        return xml
    }

    static func parseTimestamped(data: Data) -> [(Date, CLLocationCoordinate2D)] {
        let delegate = GPXTimestampedDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.points
    }
}

private class GPXParserDelegate: NSObject, XMLParserDelegate {
    var coordinates: [CLLocationCoordinate2D] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "wpt" || elementName == "trkpt" || elementName == "rtept" {
            if let latStr = attributeDict["lat"], let lonStr = attributeDict["lon"],
               let lat = Double(latStr), let lon = Double(lonStr) {
                coordinates.append(CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
        }
    }
}

private class GPXTimestampedDelegate: NSObject, XMLParserDelegate {
    var points: [(Date, CLLocationCoordinate2D)] = []

    private var currentCoord: CLLocationCoordinate2D?
    private var currentText = ""
    private let formatter = ISO8601DateFormatter()

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName == "wpt" || elementName == "trkpt" || elementName == "rtept" {
            if let latStr = attributeDict["lat"], let lonStr = attributeDict["lon"],
               let lat = Double(latStr), let lon = Double(lonStr) {
                currentCoord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            }
        }
        if elementName == "time" {
            currentText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "time",
           let coord = currentCoord,
           let date = formatter.date(from: currentText.trimmingCharacters(in: .whitespacesAndNewlines)) {
            points.append((date, coord))
        }
        if elementName == "wpt" || elementName == "trkpt" || elementName == "rtept" {
            currentCoord = nil
        }
    }
}
