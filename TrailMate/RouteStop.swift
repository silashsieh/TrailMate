import CoreLocation

@Observable
@MainActor
final class RouteStop: Identifiable {
    let id = UUID()
    let search = LocationSearch()
    var coordinate: CLLocationCoordinate2D?
}
