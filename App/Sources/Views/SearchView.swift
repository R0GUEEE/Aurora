import SwiftUI
import AuroraCore

/// Name and description search across every loaded repository, optionally
/// narrowed to one section.
// `@MainActor` because `AuroraStore` is main-actor isolated: only `body` is
// isolated by default, so helper members that touch the store need it explicitly.
@MainActor
struct SearchView: View {

    @ObservedObject var store: AuroraStore

    @State private var query = ""
    /// nil means "every section".
    @State private var scope: String?

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section {
                    EmptyMessage(
                        symbol: "magnifyingglass",
                        title: "Search",
                        message: "Type to search package names and short descriptions across all \(store.totalPackageCount) loaded packages."
                    )
                }
            } else if results.isEmpty {
                Section {
                    EmptyMessage(
                        symbol: "questionmark.circle",
                        title: "No matches",
                        message: scope == nil
                            ? "Nothing in the loaded indexes matches “\(query)”."
                            : "Nothing in “\(scope ?? "")” matches “\(query)”. Try searching every section."
                    )
                }
            } else {
                Section {
                    ForEach(results) { record in
                        NavigationLink(value: record) {
                            PackageRow(record: record, state: store.state(for: record), showIcon: store.settings.showPackageIcons, compact: store.settings.compactPackageRows, showDescription: store.settings.showPackageDescriptions)
                        }
                    }
                } header: {
                    HStack {
                        Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                        Spacer()
                        Text(scope ?? "All sections")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Name or description")
        .navigationTitle("Search")
        .navigationDestination(for: PackageRecord.self) { record in
            PackageDetailView(store: store, record: record)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button("All sections") { scope = nil }
                    // The repository's own `Section:` values, alphabetical.
                    ForEach(store.sectionNames, id: \.self) { name in
                        Button(name) { scope = name }
                    }
                } label: {
                    Image(systemName: scope == nil
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                }
                .disabled(store.sectionNames.isEmpty)
                .accessibilityLabel("Filter by section")
            }
        }
    }

    private var results: [PackageRecord] {
        store.searchResults(query: query, section: scope)
    }
}
