import MapKit

@Observable
@MainActor
final class LocationSearch {
    var query: String = ""
    var suggestions: [MKLocalSearchCompletion] = []

    private let completer: MKLocalSearchCompleter
    private let delegate: CompleterDelegate

    init() {
        self.completer = MKLocalSearchCompleter()
        self.delegate = CompleterDelegate()
        completer.delegate = delegate
        completer.resultTypes = [.pointOfInterest, .address]
        delegate.onResults = { [weak self] results in
            self?.suggestions = results
        }
    }

    func updateQuery(_ text: String) {
        query = text
        if text.isEmpty {
            suggestions = []
        } else {
            completer.queryFragment = text
        }
    }

    // Seed the field text without kicking off autocompletion — used when
    // restoring saved state (e.g., loadSavedRoute) where suggestions would
    // be visual noise.
    func setQuery(_ text: String) {
        query = text
        suggestions = []
    }

    func select(_ completion: MKLocalSearchCompletion) {
        query = completion.title
        suggestions = []
    }

    func resolve(_ completion: MKLocalSearchCompletion) async -> CLLocationCoordinate2D? {
        let request = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: request)
        guard let response = try? await search.start() else { return nil }
        return response.mapItems.first?.location.coordinate
    }
}

private class CompleterDelegate: NSObject, MKLocalSearchCompleterDelegate {
    var onResults: (([MKLocalSearchCompletion]) -> Void)?

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        onResults?(completer.results)
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        onResults?([])
    }
}
