import SwiftUI
import AuroraCore

@MainActor
struct SearchView: View {
    @ObservedObject var store: AuroraStore

    private enum SearchSort: String, CaseIterable, Identifiable {
        case relevance = "Relevance"
        case name = "Name"
        case newest = "Newest Version"
        var id: String { rawValue }
    }

    @State private var query = ""
    @State private var section: String?
    @State private var sourceID: UUID?
    @State private var architecture: String?
    @State private var installedOnly = false
    @State private var updatesOnly = false
    @State private var compatibleOnly = false
    @State private var sort: SearchSort = .relevance
    @AppStorage("aurora.search.recents") private var recentStorage = ""

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !recentQueries.isEmpty {
                    Section("Recent Searches") {
                        ForEach(recentQueries, id: \.self) { item in
                            Button {
                                query = item
                            } label: {
                                Label(item, systemImage: "clock")
                            }
                        }
                        Button("Clear Recent Searches", role: .destructive) { recentStorage = "" }
                    }
                }
                Section {
                    EmptyMessage(symbol: "magnifyingglass", title: "Search",
                                 message: "Search package IDs, names, descriptions and sections across all loaded repositories.")
                }
            } else if results.isEmpty {
                Section {
                    EmptyMessage(symbol: "questionmark.circle", title: "No matches",
                                 message: "No loaded package matches “\(query)” with the current filters.")
                }
            } else {
                Section {
                    ForEach(results) { record in
                        NavigationLink(value: record) {
                            PackageRow(record: record, state: store.state(for: record),
                                       showIcon: store.settings.showPackageIcons,
                                       compact: store.settings.compactPackageRows,
                                       showDescription: store.settings.showPackageDescriptions)
                        }
                    }
                } header: {
                    Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                }
            }
        }
        .searchable(text: $query, prompt: "Package name, ID, description, section")
        .onSubmit(of: .search) { rememberQuery() }
        .navigationTitle("Search")
        .navigationDestination(for: PackageRecord.self) { PackageDetailView(store: store, record: $0) }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Section("Status") {
                        Toggle("Installed only", isOn: $installedOnly)
                        Toggle("Updates only", isOn: $updatesOnly)
                        Toggle("Compatible only", isOn: $compatibleOnly)
                    }
                    Section("Section") {
                        Button("All Sections") { section = nil }
                        ForEach(store.sectionNames, id: \.self) { value in
                            Button(value) { section = value }
                        }
                    }
                    Section("Repository") {
                        Button("All Repositories") { sourceID = nil }
                        ForEach(store.sources.filter(\.isEnabled)) { source in
                            Button(source.name) { sourceID = source.id }
                        }
                    }
                    Section("Architecture") {
                        Button("All Architectures") { architecture = nil }
                        ForEach(architectures, id: \.self) { value in
                            Button(value) { architecture = value }
                        }
                    }
                    Section("Sort") {
                        Picker("Sort", selection: $sort) {
                            ForEach(SearchSort.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                    if hasFilters {
                        Divider()
                        Button("Clear Filters") { clearFilters() }
                    }
                } label: {
                    Image(systemName: hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Search filters")
            }
        }
    }

    private var architectures: [String] {
        Array(Set(store.combinedIndex.records.map(\.architecture).filter { !$0.isEmpty })).sorted()
    }

    private var results: [PackageRecord] {
        var values = store.searchResults(query: query, section: section)
        if let sourceID { values = values.filter { $0.origin?.id == sourceID } }
        if let architecture { values = values.filter { $0.architecture == architecture } }
        if installedOnly { values = values.filter { store.state(for: $0).isInstalled } }
        if updatesOnly { values = values.filter { store.hasUpdate(named: $0.name) } }
        if compatibleOnly {
            values = values.filter {
                if case .incompatible = PackageCompatibility.evaluate($0, environment: store.environment) { return false }
                return true
            }
        }
        switch sort {
        case .relevance:
            break
        case .name:
            values.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .newest:
            values.sort {
                let order = DebianVersion.compare($0.version, $1.version)
                if order != 0 { return order > 0 }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }
        return values
    }

    private var hasFilters: Bool {
        section != nil || sourceID != nil || architecture != nil || installedOnly || updatesOnly || compatibleOnly || sort != .relevance
    }

    private var recentQueries: [String] {
        recentStorage.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private func rememberQuery() {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var items = recentQueries.filter { $0.caseInsensitiveCompare(value) != .orderedSame }
        items.insert(value, at: 0)
        recentStorage = items.prefix(8).joined(separator: "\n")
    }

    private func clearFilters() {
        section = nil
        sourceID = nil
        architecture = nil
        installedOnly = false
        updatesOnly = false
        compatibleOnly = false
        sort = .relevance
    }
}
