import SwiftUI
import AuroraCore

@MainActor
struct NewPackagesView: View {
    @ObservedObject var store: AuroraStore
    @State private var query = ""

    private var records: [PackageRecord] {
        let all = store.newPackageRecords()
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter {
            $0.name.lowercased().contains(needle)
                || $0.displayName.lowercased().contains(needle)
                || $0.synopsis.lowercased().contains(needle)
                || $0.section.lowercased().contains(needle)
        }
    }

    var body: some View {
        List {
            if records.isEmpty {
                EmptyMessage(
                    symbol: "sparkles",
                    title: "No new packages",
                    message: "Refresh your repositories to discover recently published packages."
                )
            } else {
                ForEach(records, id: \.self) { record in
                    NavigationLink {
                        PackageDetailView(store: store, record: record)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            PackageRow(record: record, state: store.state(for: record), showIcon: store.settings.showPackageIcons, compact: store.settings.compactPackageRows, showDescription: store.settings.showPackageDescriptions)
                            if let date = AuroraStore.publishedDate(for: record) {
                                Text("Published \(date.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("New Packages")
        .searchable(text: $query, prompt: "Search new packages")
        .refreshable { await store.refreshAll() }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { Task { await store.refreshAll() } } label: {
                    if store.refreshState.isRefreshing { ProgressView() }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(store.refreshState.isRefreshing)
            }
        }
    }
}
