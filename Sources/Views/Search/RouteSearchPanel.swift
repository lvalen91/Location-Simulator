import SwiftUI
import MapKit

/// Maps.app-style From/To search fields with autocomplete suggestions,
/// displayed at the top of the sidebar.
struct RouteSearchPanel: View {
    @Bindable var appState: AppState
    @State private var fromCompleter = SearchCompleterManager()
    @State private var toCompleter = SearchCompleterManager()
    @State private var showFromSuggestions = false
    @State private var showToSuggestions = false
    @FocusState private var focusedField: SearchField?

    private enum SearchField {
        case from, to
    }

    var body: some View {
        Section {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    // Dots + fields
                    VStack(spacing: 6) {
                        // From field
                        HStack(spacing: 6) {
                            Circle()
                                .fill(.green)
                                .frame(width: 8, height: 8)
                            TextField("Current Location", text: $appState.fromText)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)
                                .focused($focusedField, equals: .from)
                                .onChange(of: appState.fromText) { _, newValue in
                                    fromCompleter.search(newValue)
                                    showFromSuggestions = !newValue.isEmpty
                                }
                        }
                        // To field
                        HStack(spacing: 6) {
                            Circle()
                                .fill(.red)
                                .frame(width: 8, height: 8)
                            TextField("Search destination", text: $appState.toText)
                                .textFieldStyle(.roundedBorder)
                                .controlSize(.small)
                                .focused($focusedField, equals: .to)
                                .onChange(of: appState.toText) { _, newValue in
                                    toCompleter.search(newValue)
                                    showToSuggestions = !newValue.isEmpty
                                }
                        }
                    }

                    // Swap button to the right of both fields
                    Button(action: { appState.swapFromTo() }) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.borderless)
                    .help("Swap origin and destination")
                }

                // From suggestions
                if showFromSuggestions && !fromCompleter.suggestions.isEmpty && focusedField == .from {
                    SuggestionsList(suggestions: fromCompleter.suggestions) { suggestion in
                        fromCompleter.resolve(suggestion) { coord, name in
                            if let coord = coord {
                                appState.fromCoordinate = coord
                                appState.fromText = name ?? suggestion.title
                                appState.fromName = name ?? suggestion.title
                                showFromSuggestions = false
                                focusedField = .to
                                tryCalculateRoutes()
                            }
                        }
                    }
                }

                // To suggestions
                if showToSuggestions && !toCompleter.suggestions.isEmpty && focusedField == .to {
                    SuggestionsList(suggestions: toCompleter.suggestions) { suggestion in
                        toCompleter.resolve(suggestion) { coord, name in
                            if let coord = coord {
                                appState.toCoordinate = coord
                                appState.toText = name ?? suggestion.title
                                appState.toName = name ?? suggestion.title
                                showToSuggestions = false
                                focusedField = nil
                                tryCalculateRoutes()
                            }
                        }
                    }
                }

                // Clear button
                HStack {
                    Spacer()

                    // Clear button
                    if !appState.fromText.isEmpty || !appState.toText.isEmpty {
                        Button(action: { appState.clearSearch() }) {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Clear search")
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Route")
        }
    }

    private func tryCalculateRoutes() {
        if appState.toCoordinate != nil &&
           (appState.fromCoordinate != nil || appState.spoofing.currentLocation != nil) {
            appState.calculateRoutes()
        }
    }
}

// MARK: - Suggestions List

private struct SuggestionsList: View {
    let suggestions: [MKLocalSearchCompletion]
    let onSelect: (MKLocalSearchCompletion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(suggestions.prefix(5), id: \.self) { suggestion in
                Button(action: { onSelect(suggestion) }) {
                    HStack {
                        Image(systemName: "mappin.circle")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(suggestion.title)
                                .font(.callout)
                                .lineLimit(1)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 3)
                    .padding(.horizontal, 4)
                }
                .buttonStyle(.plain)
                if suggestion != suggestions.prefix(5).last {
                    Divider()
                }
            }
        }
        .background(.background.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
