import SwiftUI
import AuroraCore

@MainActor
struct HomeView: View {
    @ObservedObject var store: AuroraStore

    private var recent: [PackageRecord] { Array(store.newPackageRecords(limit: 8)) }
    private var updates: [PackageRecord] { Array(store.upgradePlan.upgradable.prefix(8)) }

    var body: some View {
        List {
            Section {
                HStack {
                    summary("Packages", "\(store.totalPackageCount)", "shippingbox")
                    summary("Updates", "\(store.upgradePlan.count)", "arrow.up.circle")
                    summary("Repos", "\(store.sources.filter(\.isEnabled).count)", "square.stack.3d.up")
                }
                .padding(.vertical, 4)
            }

            if !updates.isEmpty {
                Section("Updates") {
                    ForEach(updates) { record in
                        NavigationLink {
                            PackageDetailView(store: store, record: record)
                        } label: {
                            PackageRow(record: record, state: store.state(for: record))
                        }
                    }
                }
            }

            Section("Recently Discovered") {
                if recent.isEmpty {
                    Text("Refresh repositories to discover packages.")
                        .foregroundColor(.secondary)
                }
                ForEach(recent) { record in
                    NavigationLink {
                        PackageDetailView(store: store, record: record)
                    } label: {
                        PackageRow(record: record, state: store.state(for: record))
                    }
                }
            }

            Section("More") {
                ForEach(moreDestinations) { destination in
                    NavigationLink {
                        destinationView(destination)
                    } label: {
                        Label(destination.label, systemImage: destination.symbol)
                    }
                }
            }

            if !store.failedSourceIDs.isEmpty {
                Section {
                    Button {
                        Task { await store.refreshFailedSources() }
                    } label: {
                        Label("Retry \(store.failedSourceIDs.count) Failed Repositories", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    }
                } header: {
                    Text("Repository Health")
                }
            }
        }
        .navigationTitle("Aurora")
        .refreshable { await store.refreshAll() }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { Task { await store.refreshAll() } } label: {
                    if store.refreshState.isRefreshing { ProgressView() }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(store.refreshState.isRefreshing)

                NavigationLink {
                    SettingsView(store: store)
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
    }


    private var moreDestinations: [AppTab] {
        AppTab.allCases.filter {
            $0 != .home && $0 != .settings && !store.settings.tabs.contains($0)
        }
    }

    @ViewBuilder
    private func destinationView(_ destination: AppTab) -> some View {
        switch destination {
        case .browse: BrowseView(store: store)
        case .newPackages: NewPackagesView(store: store)
        case .installed: InstalledView(store: store)
        case .library: LibraryView(store: store)
        case .sources: SourcesListView(store: store)
        case .search: SearchView(store: store)
        case .queue: QueueView(store: store)
        case .settings: SettingsView(store: store)
        case .home: EmptyView()
        }
    }

    private func summary(_ title: String, _ value: String, _ symbol: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.title3)
            Text(value).font(.headline)
            Text(title).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
