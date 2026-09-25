import CoreLocation
import MapKit
@testable import TrailMate

// A deterministic route kernel shared by WP7 and the AI dispatch suites.
// Tests supply a complete plan or a labeled failure; it never starts MapKit.
@MainActor
final class FakeRoutingService: RoutingService {
    enum Outcome: Sendable {
        case plan(RoutePlan)
        case legNotFound(Int)
        case degenerate
    }

    private(set) var requestedWaypoints: [[CLLocationCoordinate2D]] = []
    private(set) var requestedTransportTypes: [MKDirectionsTransportType] = []
    let outcome: Outcome

    init(_ outcome: Outcome) {
        self.outcome = outcome
    }

    func calculateRoute(
        waypoints: [CLLocationCoordinate2D],
        transportType: MKDirectionsTransportType
    ) async throws -> RoutePlan {
        requestedWaypoints.append(waypoints)
        requestedTransportTypes.append(transportType)
        switch outcome {
        case .plan(let plan): return plan
        case .legNotFound(let index): throw RoutingError.legNotFound(index: index)
        case .degenerate: throw RoutingError.degenerate
        }
    }

    func calculateHop(
        from: CLLocationCoordinate2D,
        to: CLLocationCoordinate2D,
        transportType: MKDirectionsTransportType
    ) async throws -> RouteHop {
        throw RoutingError.degenerate
    }
}
