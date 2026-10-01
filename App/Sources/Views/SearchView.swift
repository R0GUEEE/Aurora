import SwiftUI
import AuroraCore

@MainActor
struct SearchView: View {
    @ObservedObject var store: AuroraStore

    private enum SearchSort: String, CaseIterable, Identifiable {
        case relevance = "Relevance"
        case name = "Name"
        case newest = "Newest Version"
        case downloadSize = "Download Size"
        case installedSize = "Installed Size"
        var id: String { rawValue }
    }

    private enum CommercialFilter: String, CaseIterable, Identifiable {
        case all = "All Packages"
        case free = "Free Only"
        case commercial = "Commercial Only"
        var id: String { rawValue }
    }

    @State private var query = ""
    @State private var section: String?
    @State private var sourceID: UUID?
    @State private var architecture: String?
    @State private var installedOnly = false
    @State private var updatesOnly = false
    @State private var compatibleOnly = false
    @State private var bookmarkedOnly = false
    @State private var verifiedSourcesOnly = false
    @State private var depictionOnly = false
    @State private var commercial: CommercialFilter = .all
    @State private var sort: SearchSort = .relevance
    @State private var isShowingFilters = false
    @AppStorage("aurora.search.recents") private var recentStorage = ""

    var body: some View {
        // Compute the scan/sort once per body evaluation. This value is consumed
        // by emptiness, row rendering and the result count below.
        let visibleResults = results
        return List {
            if hasFilters {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(Array(activeFilterLabels.indices), id: \.self) { index in
                                Text(activeFilterLabels[index])
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(Color(.secondarySystemBackground)))
                            }
                            Button("Clear") { clearFilters() }
                                .font(.caption)
                        }
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }

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
                    EmptyMessage(
                        symbol: "magnifyingglass",
                        title: "Search",
                        message: "Search package IDs, names, descriptions and sections. Filters can narrow results by repository, architecture, install state, trust, bookmarks and package type."
                    )
                }
            } else if visibleResults.isEmpty {
                Section {
                    EmptyMessage(symbol: "questionmark.circle", title: "No matches",
                                 message: "No loaded package matches “\(query)” with the current filters.")
                }
            } else {
                Section {
                    ForEach(visibleResults) { record in
                        NavigationLink(value: record) {
                            PackageRow(
                                record: record,
                                state: store.state(for: record),
                                showIcon: store.settings.showPackageIcons,
                                compact: store.settings.compactPackageRows,
                                showDescription: store.settings.showPackageDescriptions
                            )
                        }
                        .swipeActions(edge: .leading) {
                            if !store.state(for: record).isInstalled {
                                Button {
                                    store.stage(store.defaultAction(for: record))
                                } label: {
                                    Label("Queue", systemImage: "tray.and.arrow.down")
                                }
                                .tint(.blue)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button {
                                store.toggleBookmark(record.name)
                            } label: {
                                Label(
                                    store.isBookmarked(record.name) ? "Unbookmark" : "Bookmark",
                                    systemImage: store.isBookmarked(record.name) ? "bookmark.slash" : "bookmark"
                                )
                            }
                            .tint(.orange)
                        }
                    }
                } header: {
                    Text("\(visibleResults.count) result\(visibleResults.count == 1 ? "" : "s")")
                }
            }
        }
        .searchable(text: $query, prompt: "Package name, ID, description, section")
        .onSubmit(of: .search) { rememberQuery() }
        .navigationTitle("Search")
        .navigationDestination(for: PackageRecord.self) { PackageDetailView(store: store, record: $0) }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    isShowingFilters = true
                } label: {
                    Image(systemName: hasFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Search filters")
            }
        }
        .sheet(isPresented: $isShowingFilters) {
            NavigationStack {
                Form {
                    Section("Status") {
                        Toggle("Installed only", isOn: $installedOnly)
                        Toggle("Updates only", isOn: $updatesOnly)
                        Toggle("Compatible only", isOn: $compatibleOnly)
                        Toggle("Bookmarked only", isOn: $bookmarkedOnly)
                    }

                    Section("Package") {
                        Picker("Commercial", selection: $commercial) {
                            ForEach(CommercialFilter.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Toggle("Has depiction", isOn: $depictionOnly)
                    }

                    Section("Trust") {
                        Toggle("Verified repositories only", isOn: $verifiedSourcesOnly)
                    }

                    Section("Section") {
                        Picker("Section", selection: $section) {
                            Text("All Sections").tag(String?.none)
                            ForEach(store.sectionNames, id: \.self) { value in
                                Text(value).tag(Optional(value))
                            }
                        }
                    }

                    Section("Repository") {
                        Picker("Repository", selection: $sourceID) {
                            Text("All Repositories").tag(UUID?.none)
                            ForEach(enabledSources) { source in
                                Text(source.name).tag(Optional(source.id))
                            }
                        }
                    }

                    Section("Architecture") {
                        Picker("Architecture", selection: $architecture) {
                            Text("All Architectures").tag(String?.none)
                            ForEach(architectures, id: \.self) { value in
                                Text(value).tag(Optional(value))
                            }
                        }
                    }

                    Section("Sort") {
                        Picker("Sort", selection: $sort) {
                            ForEach(SearchSort.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }

                    if hasFilters {
                        Section {
                            Button("Clear Filters", role: .destructive) { clearFilters() }
                        }
                    }
                }
                .navigationTitle("Search Filters")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { isShowingFilters = false }
                    }
                }
            }
        }
    }

    private var architectures: [String] { store.architectureNames }
    private var enabledSources: [RepositorySource] { store.sources.filter(\.isEnabled) }

    private var results: [PackageRecord] {
        var values = store.searchResults(
            query: query,
            section: section,
            sourceID: sourceID,
            architecture: architecture,
            installedOnly: installedOnly,
            updatesOnly: updatesOnly,
            compatibleOnly: compatibleOnly,
            bookmarkedOnly: bookmarkedOnly,
            verifiedSourcesOnly: verifiedSourcesOnly,
            depictionOnly: depictionOnly,
            commercial: commercial == .all ? nil : commercial == .commercial
        )

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
        case .downloadSize:
            values.sort {
                let lhs = $0.downloadSize ?? -1
                let rhs = $1.downloadSize ?? -1
                if lhs != rhs { return lhs > rhs }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        case .installedSize:
            values.sort {
                let lhs = $0.installedSize ?? -1
                let rhs = $1.installedSize ?? -1
                if lhs != rhs { return lhs > rhs }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }
        return values
    }


    private var hasFilters: Bool {
        section != nil
            || sourceID != nil
            || architecture != nil
            || installedOnly
            || updatesOnly
            || compatibleOnly
            || bookmarkedOnly
            || verifiedSourcesOnly
            || depictionOnly
            || commercial != .all
            || sort != .relevance
    }

    private var activeFilterLabels: [String] {
        var labels: [String] = []
        if installedOnly { labels.append("Installed") }
        if updatesOnly { labels.append("Updates") }
        if compatibleOnly { labels.append("Compatible") }
        if bookmarkedOnly { labels.append("Bookmarked") }
        if verifiedSourcesOnly { labels.append("Verified repo") }
        if depictionOnly { labels.append("Depiction") }
        if commercial != .all { labels.append(commercial.rawValue) }
        if let section { labels.append(section) }
        if let architecture { labels.append(architecture) }
        if let sourceID, let source = store.sources.first(where: { $0.id == sourceID }) {
            labels.append(source.name)
        }
        if sort != .relevance { labels.append("Sort: \(sort.rawValue)") }
        return labels
    }

    private var recentQueries: [String] {
        recentStorage.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    private func rememberQuery() {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        var items = recentQueries.filter { $0.caseInsensitiveCompare(value) != .orderedSame }
        items.insert(value, at: 0)
        recentStorage = items.prefix(10).joined(separator: "\n")
    }

    private func clearFilters() {
        section = nil
        sourceID = nil
        architecture = nil
        installedOnly = false
        updatesOnly = false
        compatibleOnly = false
        bookmarkedOnly = false
        verifiedSourcesOnly = false
        depictionOnly = false
        commercial = .all
        sort = .relevance
    }
}
