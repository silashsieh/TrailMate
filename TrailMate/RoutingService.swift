import CoreLocation
import MapKit

// The routing kernel seam (decision D4). All MKDirections work lives behind this
// protocol so the kernel is swappable — `MapKitRoutingService` today, a future
// self-hosted-OSRM implementation later — while MapKit stays the map *display*.
// The service is a stateless value type: routing is a per-process shared kernel
// (MapKit's rate limit is per-Mac, not per-route), so multi-device sessions share
// one instance and keep only the per-session route *output*.
protocol RoutingService: Sendable {
    // Route through [from, via…, to]; legs are joined into one polyline.
    func calculateRoute(
        waypoints: [CLLocationCoordinate2D],
        transportType: MKDirectionsTransportType
    ) async throws -> RoutePlan

    // A single leg, used by the wander builder's chained hops. Returns an empty
    // segment (not an error) when no route exists — the caller treats that as a
    // skipped hop.
    func calculateHop(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        transportType: MKDirectionsTransportType
    ) async throws -> RouteHop
}

struct RoutePlan: Sendable {
    var coordinates: [CLLocationCoordinate2D]
    var distanceMeters: Double
    var travelTimeSeconds: TimeInterval
}

struct RouteHop: Sendable {
    var coordinates: [CLLocationCoordinate2D]
    var distanceMeters: Double
}

// Carries the failing leg index so the caller can label it ("From → Stop 1")
// without the kernel knowing anything about the UI's stop naming.
enum RoutingError: Error {
    case legNotFound(index: Int)                  // MKDirections returned no routes for this leg
    case legFailed(index: Int, underlying: Error) // calculate() threw for this leg
    case degenerate                                // fewer than 2 joined coordinates
}

struct MapKitRoutingService: RoutingService {
    func calculateRoute(
        waypoints: [CLLocationCoordinate2D],
        transportType: MKDirectionsTransportType
    ) async throws -> RoutePlan {
        var combined: [CLLocationCoordinate2D] = []
        var totalDistance = 0.0
        var totalTime: TimeInterval = 0.0

        for i in 0..<(waypoints.count - 1) {
            let a = waypoints[i]
            let b = waypoints[i + 1]
            let aLoc = CLLocation(latitude: a.latitude, longitude: a.longitude)
            let bLoc = CLLocation(latitude: b.latitude, longitude: b.longitude)
            if aLoc.distance(from: bLoc) < 1.0 { continue }

            let request = MKDirections.Request()
            request.source = MKMapItem(location: aLoc, address: nil)
            request.destination = MKMapItem(location: bLoc, address: nil)
            request.transportType = transportType

            do {
                let response = try await MKDirections(request: request).calculate()
                guard let route = response.routes.first else {
                    throw RoutingError.legNotFound(index: i)
                }
                let segCoords = Self.extractCoordinates(from: route.polyline)
                combined = RouteMath.joinSegments(combined, segCoords)
                totalDistance += route.distance
                totalTime += route.expectedTravelTime
            } catch let error as RoutingError {
                throw error
            } catch {
                throw RoutingError.legFailed(index: i, underlying: error)
            }
        }

        guard combined.count >= 2 else { throw RoutingError.degenerate }
        return RoutePlan(coordinates: combined, distanceMeters: totalDistance, travelTimeSeconds: totalTime)
    }

    func calculateHop(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        transportType: MKDirectionsTransportType
    ) async throws -> RouteHop {
        let request = MKDirections.Request()
        request.source = MKMapItem(location: CLLocation(latitude: from.latitude, longitude: from.longitude), address: nil)
        request.destination = MKMapItem(location: CLLocation(latitude: to.latitude, longitude: to.longitude), address: nil)
        request.transportType = transportType

        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else {
            return RouteHop(coordinates: [], distanceMeters: 0)
        }
        return RouteHop(coordinates: Self.extractCoordinates(from: route.polyline), distanceMeters: route.distance)
    }

    static func extractCoordinates(from polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(),
            count: polyline.pointCount
        )
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
        return coords
    }
}
