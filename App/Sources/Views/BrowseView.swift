import SwiftUI
import AuroraCore

/// Every available package, grouped by the repository's own `Section:` field.
// `@MainActor` because `AuroraStore` is main-actor isolated: only `body` is
// isolated by default, so helper members that touch the store need it explicitly.
@MainActor
struct BrowseView: View {

    @ObservedObject var store: AuroraStore

    @State private var query = ""

    var body: some View {
        List {
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

            ForEach(filteredSections) { section in
                Section {
                    ForEach(section.records) { record in
                        NavigationLink(value: record) {
                            PackageRow(record: record, state: store.state(for: record))
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
        .overlay(alignment: .bottom) {
            if !store.sections.isEmpty {
                Text(footerText)
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
        store.browseRecords(matching: query)
    }

    private var footerText: String {
        let shown = filteredSections.reduce(0) { $0 + $1.records.count }
        if shown == store.totalPackageCount {
            return "\(store.totalPackageCount) packages"
        }
        return "\(shown) of \(store.totalPackageCount) packages"
    }
}
