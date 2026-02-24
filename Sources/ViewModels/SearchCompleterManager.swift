import Foundation
import MapKit

/// Wraps MKLocalSearchCompleter for use with SwiftUI.
/// Provides autocomplete suggestions as the user types.
@Observable
final class SearchCompleterManager: NSObject, MKLocalSearchCompleterDelegate {
    var suggestions: [MKLocalSearchCompletion] = []
    var isSearching = false

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest, .query]
    }

    /// Update the search query. Empty string clears suggestions.
    func search(_ query: String) {
        if query.isEmpty {
            suggestions = []
            isSearching = false
            return
        }
        isSearching = true
        completer.queryFragment = query
    }

    /// Resolve a search completion to a coordinate.
    func resolve(_ completion: MKLocalSearchCompletion, handler: @escaping (CLLocationCoordinate2D?, String?) -> Void) {
        let request = MKLocalSearch.Request(completion: completion)
        MKLocalSearch(request: request).start { response, _ in
            DispatchQueue.main.async {
                if let item = response?.mapItems.first {
                    let name = completion.title
                    handler(item.placemark.coordinate, name)
                } else {
                    handler(nil, nil)
                }
            }
        }
    }

    // MARK: - MKLocalSearchCompleterDelegate

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        suggestions = completer.results
        isSearching = false
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        isSearching = false
    }
}
