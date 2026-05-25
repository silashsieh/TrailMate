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
