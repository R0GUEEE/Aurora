import SwiftUI
import AuroraCore

@MainActor
struct HomeView: View {
    @ObservedObject var store: AuroraStore

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]
    private var recent: [PackageRecord] { Array(store.newPackageRecords(limit: store.settings.homePackageLimit)) }
    private var updates: [PackageRecord] { Array(store.upgradePlan.upgradable.prefix(store.settings.homePackageLimit)) }

    var body: some View {
        List {
            Section {
                overview
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
            }

            Section("At a Glance") {
                LazyVGrid(columns: columns, spacing: 10) {
                    metric("Available", value: store.totalPackageCount, symbol: "shippingbox.fill", tint: .blue)
                    metric("Updates", value: store.upgradePlan.count, symbol: "arrow.up.circle.fill", tint: .orange)
                    metric("Installed", value: store.installed.present.count, symbol: "checkmark.seal.fill", tint: .green)
                    metric("Repositories", value: store.sources.filter(\.isEnabled).count, symbol: "square.stack.3d.up.fill", tint: .purple)
                }
                .padding(.vertical, 5)
                .listRowBackground(Color.clear)
            }

            Section("Explore") {
                LazyVGrid(columns: columns, spacing: 10) {
                    shortcut(.browse, subtitle: "Explore categories", tint: .blue)
                    shortcut(.search, subtitle: "Find a package", tint: .purple)
                    shortcut(.sources, subtitle: "Manage repositories", tint: .teal)
                    shortcut(.queue, subtitle: "Review staged changes", tint: .orange)
                }
                .padding(.vertical, 5)
                .listRowBackground(Color.clear)
            }

            if !updates.isEmpty {
                Section {
                    ForEach(updates) { record in
                        NavigationLink { PackageDetailView(store: store, record: record) } label: {
                            packageRow(record)
                        }
                    }
                } header: {
                    HStack {
                        Text("Updates")
                        Spacer()
                        NavigationLink("View All") { InstalledView(store: store) }
                            .font(.caption)
                    }
                }
            }

            Section("Recently Discovered") {
                if recent.isEmpty {
                    EmptyMessage(symbol: "sparkles", title: "Ready to discover", message: "Refresh repositories to find recently published packages.")
                }
                ForEach(recent) { record in
                    NavigationLink { PackageDetailView(store: store, record: record) } label: {
                        packageRow(record)
                    }
                }
            }

            if !moreDestinations.isEmpty {
                Section("More") {
                    ForEach(moreDestinations) { destination in
                        NavigationLink { destinationView(destination) } label: {
                            Label(destination.label, systemImage: destination.symbol)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Aurora")
        .refreshable { await store.refreshAll() }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button { Task { await store.refreshAll() } } label: {
                    if store.refreshState.isRefreshing { ProgressView() }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .disabled(store.refreshState.isRefreshing)
                .accessibilityLabel("Refresh repositories")
                NavigationLink { SettingsView(store: store) } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.title2)
                    .accessibilityHidden(true)
                Spacer()
                Text(store.layoutName.uppercased())
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.white.opacity(0.18)))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(headline).font(.title2.weight(.bold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if case .refreshing(let done, let total) = store.refreshState {
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .tint(.white)
                    .accessibilityLabel("Refreshing \(done) of \(total) repositories")
            } else if !store.failedSourceIDs.isEmpty {
                Button {
                    Task { await store.refreshFailedSources() }
                } label: {
                    Label("Retry \(store.failedSourceIDs.count) failed repositories", systemImage: "arrow.clockwise")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.white)
            } else if store.queueCount > 0 {
                NavigationLink { QueueView(store: store) } label: {
                    Label("Review \(store.queueCount) staged changes", systemImage: "tray.full.fill")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.12, green: 0.32, blue: 0.68), Color(red: 0.28, green: 0.19, blue: 0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .accessibilityElement(children: .contain)
    }

    private var headline: String {
        if store.refreshState.isRefreshing { return "Refreshing sources" }
        if store.upgradePlan.count > 0 { return "Updates are ready" }
        return "Your package hub"
    }

    private var subtitle: String {
        if store.refreshState.isRefreshing { return store.refreshState.label }
        if !store.failedSourceIDs.isEmpty { return "\(store.failedSourceIDs.count) repositories need attention." }
        if store.queueCount > 0 { return "\(store.queueCount) changes are waiting in your queue." }
        if store.totalPackageCount == 0 { return "Add or refresh a repository to get started." }
        return "Discover, manage, and update your packages."
    }

    private func metric(_ title: String, value: Int, symbol: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(value.formatted()).font(.title3.weight(.bold))
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(title.lowercased())")
    }

    private func shortcut(_ destination: AppTab, subtitle: String, tint: Color) -> some View {
        NavigationLink { destinationView(destination) } label: {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: destination.symbol).font(.title3).foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(destination.label).font(.subheadline.weight(.semibold))
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(destination.label), \(subtitle)")
    }

    private func packageRow(_ record: PackageRecord) -> some View {
        PackageRow(record: record, state: store.state(for: record), showIcon: store.settings.showPackageIcons, compact: store.settings.compactPackageRows, showDescription: store.settings.showPackageDescriptions)
    }

    private var moreDestinations: [AppTab] {
        AppTab.allCases.filter {
            $0 != .home && $0 != .settings && ![.browse, .search, .sources, .queue].contains($0)
                && !store.settings.tabs.contains($0)
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
}
