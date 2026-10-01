import SwiftUI
import AuroraCore

@MainActor
struct InstalledView: View {
    @ObservedObject var store: AuroraStore
    @State private var scope: Scope = .updates
    @State private var query = ""

    enum Scope: String, CaseIterable, Identifiable {
        case updates = "Updates"
        case installed = "Installed"
        case orphaned = "Orphaned"
        case broken = "Broken"
        var id: String { rawValue }
    }

    var body: some View {
        List {
            Picker("View", selection: $scope) {
                ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)

            switch scope {
            case .updates: updatesSection
            case .installed: installedSection
            case .orphaned: orphanedSection
            case .broken: brokenSection
            }
        }
        .navigationTitle("Installed")
        .searchable(text: $query, prompt: "Filter packages")
        .refreshable {
            await store.reloadInstalled()
            await store.refreshAll()
        }
    }

    private var updates: [PackageRecord] {
        store.upgradePlan.upgradable.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private var orphans: [InstalledPackage] {
        let names = Set(store.upgradePlan.orphaned)
        return store.installed.present.filter { names.contains($0.name) }
    }

    @ViewBuilder private var updatesSection: some View {
        let records = filtered(updates)
        Section {
            if updates.isEmpty {
                EmptyMessage(symbol: "checkmark.circle", title: "Up to Date", message: "No newer package versions are available.")
            } else {
                Button {
                    for record in updates { store.stage(.upgrade(record)) }
                } label: {
                    Label("Upgrade All (\(updates.count))", systemImage: "arrow.up.circle.fill")
                        .font(.headline)
                }
                ForEach(records) { record in
                    NavigationLink {
                        PackageDetailView(store: store, record: record)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.displayName)
                            Text("\(installedVersion(record.name)) → \(record.version.raw)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        } header: { Text("\(updates.count) update\(updates.count == 1 ? "" : "s")") }
    }

    @ViewBuilder private var installedSection: some View {
        let packages = store.installed.present.filter(matches)
        Section {
            if packages.isEmpty {
                EmptyMessage(symbol: "shippingbox", title: "No Packages", message: "No installed packages match this filter.")
            }
            ForEach(packages, id: \.key) { package in
                if let record = store.bestRecord(named: package.name) {
                    NavigationLink { PackageDetailView(store: store, record: record) } label: { packageRow(package) }
                } else {
                    packageRow(package)
                }
            }
        } header: { Text("\(packages.count) installed") }
    }

    @ViewBuilder private var orphanedSection: some View {
        let packages = orphans.filter(matches)
        Section {
            if packages.isEmpty {
                EmptyMessage(symbol: "checkmark.circle", title: "No Orphans", message: "Every installed package is available from a configured repository.")
            }
            ForEach(packages, id: \.key) { packageRow($0) }
        } header: { Text("\(orphans.count) orphaned") }
    }

    @ViewBuilder private var brokenSection: some View {
        let packages = store.installed.brokenPackages.filter(matches)
        Section {
            if packages.isEmpty {
                EmptyMessage(symbol: "checkmark.shield", title: "Package Database Healthy", message: "dpkg reports no half-installed or half-configured packages.")
            }
            ForEach(packages, id: \.key) { package in
                VStack(alignment: .leading, spacing: 3) {
                    packageRow(package)
                    Text(package.status.serialized).font(.caption2.monospaced()).foregroundColor(.red)
                }
            }
        } header: { Text("\(packages.count) broken") }
    }

    private func packageRow(_ package: InstalledPackage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(package.record.displayName)
            Text("\(package.version.raw) · \(package.architecture)")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func installedVersion(_ name: String) -> String {
        store.installedPackage(named: name)?.version.raw ?? "?"
    }

    private func matches(_ package: InstalledPackage) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return needle.isEmpty || package.name.lowercased().contains(needle) || package.record.displayName.lowercased().contains(needle)
    }

    private func filtered(_ records: [PackageRecord]) -> [PackageRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return records }
        return records.filter { $0.name.lowercased().contains(needle) || $0.displayName.lowercased().contains(needle) }
    }
}
