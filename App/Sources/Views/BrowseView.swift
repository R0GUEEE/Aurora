import SwiftUI
import AuroraCore

/// Every available package, grouped by the repository's own `Section:` field.
// `@MainActor` because `AuroraStore` is main-actor isolated: only `body` is
// isolated by default, so helper members that touch the store need it explicitly.
@MainActor
struct BrowseView: View {

    @ObservedObject var store: AuroraStore

    @State private var query = ""
    @State private var sort: PackageSort = .name
    @State private var installedOnly = false
    @State private var updatesOnly = false
    @State private var compatibleOnly = false
    @State private var selectedArchitecture = "All"
    @State private var selectedSection = "All"
    @State private var isShowingFilters = false

    var body: some View {
        // Evaluate the filtered section tree once per body render.
        let visibleSections = filteredSections
        return List {
            if store.sections.isEmpty {
                Section {
                    if store.refreshState.isRefreshing {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(store.refreshState.label)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        EmptyMessage(
                            symbol: "square.grid.2x2",
                            title: "No packages yet",
                            message: store.sources.isEmpty
                                ? "Add a repository in the Sources tab to fill the store."
                                : "Pull to refresh, or open the Sources tab to see what each repository reported."
                        )
                    }
                }
            }

            ForEach(visibleSections) { section in
                Section {
                    ForEach(section.records) { record in
                        NavigationLink(value: record) {
                            PackageRow(record: record, state: store.state(for: record), showIcon: store.settings.showPackageIcons, compact: store.settings.compactPackageRows, showDescription: store.settings.showPackageDescriptions)
                        }
                    }
                } header: {
                    HStack {
                        Text(section.name)
                        Spacer()
                        Text("\(section.records.count)")
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Filter packages")
        .navigationTitle("Browse")
        .navigationDestination(for: PackageRecord.self) { record in
            PackageDetailView(store: store, record: record)
        }
        .refreshable {
            await store.refreshAll()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    isShowingFilters = true
                } label: {
                    Image(systemName: hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .accessibilityLabel("Browse filters")
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    if store.refreshState.isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(store.refreshState.isRefreshing)
                .accessibilityLabel("Refresh all repositories")
            }
        }
        .sheet(isPresented: $isShowingFilters) {
            NavigationStack {
                Form {
                    Section("Status") {
                        Toggle("Installed only", isOn: $installedOnly)
                        Toggle("Updates only", isOn: $updatesOnly)
                        Toggle("Compatible only", isOn: $compatibleOnly)
                    }

                    Section("Sort") {
                        Picker("Sort", selection: $sort) {
                            ForEach(PackageSort.allCases) { value in
                                Text(value.label).tag(value)
                            }
                        }
                    }

                    Section("Architecture") {
                        Picker("Architecture", selection: $selectedArchitecture) {
                            ForEach(architectures, id: \.self) { Text($0).tag($0) }
                        }
                    }

                    Section("Section") {
                        Picker("Section", selection: $selectedSection) {
                            ForEach(sections, id: \.self) { Text($0).tag($0) }
                        }
                    }

                    if hasActiveFilters || sort != .name {
                        Section {
                            Button("Clear Filters", role: .destructive) { clearFilters() }
                        }
                    }
                }
                .navigationTitle("Browse Filters")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { isShowingFilters = false }
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            if !store.sections.isEmpty {
                Text(footerText(for: visibleSections))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color(.secondarySystemBackground)))
                    .padding(.bottom, 6)
            }
        }
    }

    private var filteredSections: [PackageSection] {
        let hasQuery = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !hasQuery && !installedOnly && !updatesOnly && !compatibleOnly
            && selectedArchitecture == "All" && selectedSection == "All" && sort == .name {
            return store.sections
        }

        return store.browseRecords(matching: query).compactMap { section in
            if selectedSection != "All" && section.name != selectedSection { return nil }
            var records = section.records.filter { record in
                if installedOnly && !store.isInstalled(record.name) { return false }
                if updatesOnly && !store.hasUpdate(named: record.name) { return false }
                if compatibleOnly {
                    let compatibility = PackageCompatibility.evaluate(record, environment: store.environment)
                    if compatibility.level == .incompatible { return false }
                }
                if selectedArchitecture != "All" && record.architecture != selectedArchitecture { return false }
                return true
            }
            if sort != .name {
                records.sort { lhs, rhs in
                    switch sort {
                    case .name:
                        return false
                    case .version:
                        return DebianVersion.compare(lhs.version, rhs.version) > 0
                    case .size:
                        return (lhs.downloadSize ?? 0) > (rhs.downloadSize ?? 0)
                    }
                }
            }
            return records.isEmpty ? nil : PackageSection(name: section.name, records: records)
        }
    }


    private var architectures: [String] {
        ["All"] + store.architectureNames
    }

    private var sections: [String] {
        ["All"] + store.sections.map(\.name)
    }

    private var hasActiveFilters: Bool {
        installedOnly || updatesOnly || compatibleOnly || selectedArchitecture != "All" || selectedSection != "All"
    }

    private func clearFilters() {
        installedOnly = false
        updatesOnly = false
        compatibleOnly = false
        selectedArchitecture = "All"
        selectedSection = "All"
        sort = .name
    }

    private func footerText(for visibleSections: [PackageSection]) -> String {
        let shown = visibleSections.reduce(0) { $0 + $1.records.count }
        if shown == store.totalPackageCount {
            return "\(store.totalPackageCount) packages"
        }
        return "\(shown) of \(store.totalPackageCount) packages"
    }
}


private enum PackageSort: String, CaseIterable, Identifiable {
    case name, version, size
    var id: String { rawValue }
    var label: String {
        switch self {
        case .name: return "Name"
        case .version: return "Version"
        case .size: return "Download Size"
        }
    }
}
