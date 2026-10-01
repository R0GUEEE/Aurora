import SwiftUI
import AuroraCore

/// What Aurora found on this device, and the handful of things it lets a user
/// change.
// `@MainActor` because `AuroraStore` is main-actor isolated: only `body` is
// isolated by default, so helper members that touch the store need it explicitly.
@MainActor
struct SettingsView: View {

    @ObservedObject var store: AuroraStore

    @State private var isConfirmingCacheClear = false
    @State private var isShowingLogs = false
    @State private var statusText: String?

    var body: some View {
        List {
            environmentSection
            refreshSection
            renderingSection
            tabsSection
            storageSection
            diagnosticsSection
            aboutSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Settings")
        .confirmationDialog(
            "Clear caches?",
            isPresented: $isConfirmingCacheClear,
            titleVisibility: .visible
        ) {
            Button("Clear caches", role: .destructive) {
                statusText = store.clearCaches()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes the downloaded repository indexes and package files, and drops the loaded indexes. Repositories stay configured.")
        }
        .sheet(isPresented: $isShowingLogs) {
            StateFilesSheet(store: store)
        }
    }

    // MARK: - Environment

    private var environmentSection: some View {
        Section {
            DetailRow(label: "Layout", value: store.layoutName)
            DetailRow(label: "Root", value: store.environment.root)
            DetailRow(label: "Architecture", value: store.environment.architecture)
            DetailRow(label: "dpkg", value: store.environment.dpkgPath ?? "not found")
            DetailRow(label: "Status file", value: store.environment.statusFilePath)
            DetailRow(label: "Installed packages", value: "\(store.installed.count)")
            if let free = store.environment.freeSpace() {
                DetailRow(label: "Free space", value: AuroraFormat.bytes(Int(free)))
            }
            DetailRow(
                label: "Can install",
                value: store.canInstall ? "yes" : "no"
            )
        } header: {
            Text("Environment")
        } footer: {
            if store.canInstall {
                Text("Detected by AuroraCore.JailbreakEnvironment, which every path Aurora touches goes through.")
            } else {
                Text("No dpkg was found, so Aurora cannot install, remove or configure anything. Browsing, searching and staging still work. On a rootless jailbreak dpkg lives at /var/jb/usr/bin/dpkg.")
            }
        }
    }

    // MARK: - Behaviour

    private var refreshSection: some View {
        Section {
            Toggle("Refresh on launch", isOn: Binding(
                get: { store.settings.autoRefreshOnLaunch },
                set: { store.setAutoRefresh($0) }
            ))
            Toggle("Ignore signature failures", isOn: Binding(
                get: { store.settings.ignoreSignatureFailures },
                set: { store.setIgnoreSignatureFailures($0) }
            ))
            Toggle("Include rootful packages", isOn: Binding(
                get: { !store.settings.showOnlyRootlessCompatible },
                set: { store.setRootlessOnly(!$0) }
            ))
            .disabled(store.environment.layout != .rootless)

            Toggle("Offer rootful → rootless conversion", isOn: Binding(
                get: { store.settings.allowRootfulConversion },
                set: { store.setAllowRootfulConversion($0) }
            ))
            .disabled(store.environment.layout != .rootless || store.settings.showOnlyRootlessCompatible)
        } header: {
            Text("Repositories")
        } footer: {
            Text("Most jailbreak repositories are unsigned; with signature checking enforced they are refused instead of being shown with a warning. Rootful packages use legacy root filesystem paths. Conversion is opt-in and best-effort; packages with hard-coded paths, incompatible binaries, or complex maintainer scripts may still fail after conversion.")
        }
    }

    // MARK: - Depiction

    private var renderingSection: some View {
        Section {
            Picker("Package pages", selection: Binding(
                get: { store.settings.depictionPreference },
                set: { store.setDepictionPreference($0) }
            )) {
                ForEach(DepictionPreference.allCases) { preference in
                    Text(preference.label).tag(preference)
                }
            }
        } header: {
            Text("Depictions")
        } footer: {
            Text(store.settings.depictionPreference.explanation)
        }
    }

    // MARK: - Tabs

    private var tabsSection: some View {
        Section {
            NavigationLink {
                TabCustomizationView(store: store)
            } label: {
                HStack {
                    Label("Customize Tabs", systemImage: "rectangle.bottomthird.inset.filled")
                    Spacer()
                    Text("\(store.settings.tabs.count)")
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("Navigation")
        } footer: {
            Text("Choose up to five tabs, replace destinations you do not use, and drag the selected tabs into any order.")
        }
    }

    // MARK: - Storage

    private var storageSection: some View {
        Section {
            Button {
                isConfirmingCacheClear = true
            } label: {
                HStack {
                    Text("Clear caches")
                    Spacer()
                    Text(AuroraFormat.bytes(store.cacheSizeBytes()))
                        .foregroundColor(.secondary)
                }
            }
            if let statusText = statusText {
                Text(statusText)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("The cache holds repository indexes and downloaded packages under \(store.environment.cacheDirectory).")
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        Section {
            Button("Show state files") { isShowingLogs = true }
            if let message = store.sourcesPersistenceError {
                NoticeRow(symbol: "externaldrive.badge.exclamationmark", text: message, color: .orange)
            }
            if let message = store.settingsPersistenceError {
                NoticeRow(symbol: "gearshape.badge.xmark", text: message, color: .orange)
            }
            if let message = store.installedError {
                NoticeRow(symbol: "shippingbox.and.arrow.backward", text: message, color: .orange)
            }
        } header: {
            Text("Diagnostics")
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            DetailRow(label: "Version", value: AuroraBuildInfo.version)
            DetailRow(label: "Build", value: AuroraBuildInfo.build)
            DetailRow(label: "Bundle", value: AuroraBuildInfo.bundleIdentifier)
            DetailRow(label: "Packages loaded", value: "\(store.totalPackageCount)")
            DetailRow(label: "Repositories", value: "\(store.sources.filter(\.isEnabled).count) enabled")
        } header: {
            Text("About Aurora")
        } footer: {
            Text("Aurora is a package manager for jailbroken iOS. It reads Debian repositories directly, resolves dependencies itself and stages every change in a queue you confirm.")
        }
    }
}

/// Where Aurora keeps its state, and what is in it. Useful when a repository
/// misbehaves: you can see exactly what the app read.
@MainActor
struct StateFilesSheet: View {

    @ObservedObject var store: AuroraStore

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(store.stateDirectoryDescription)
                        .font(.system(.footnote, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("State directory")
                } footer: {
                    Text("sources.json and settings.json live here. Both are written atomically and a corrupt file falls back to the defaults instead of stopping Aurora.")
                }

                Section {
                    if store.sources.isEmpty {
                        Text("No repositories configured.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    ForEach(store.sources) { source in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.name)
                                .font(.callout)
                            Text("\(source.normalizedURL) · suite \(source.suite)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("\(store.packageCount(for: source.id)) packages · last refresh \(AuroraFormat.relative(source.lastRefreshed))")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            if let error = store.indexErrors[source.id] {
                                Text(error)
                                    .font(.caption2)
                                    .foregroundColor(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("Repositories")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("State")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}


@MainActor
struct TabCustomizationView: View {
    @ObservedObject var store: AuroraStore

    private var selected: [AppTab] { store.settings.tabs }
    private var alternatives: [AppTab] { AppTab.allCases.filter { !selected.contains($0) } }

    var body: some View {
        List {
            Section {
                ForEach(selected) { tab in
                    Label(tab.label, systemImage: tab.symbol)
                        .swipeActions {
                            if selected.count > 1 {
                                Button(role: .destructive) { remove(tab) } label: {
                                    Label("Remove", systemImage: "minus.circle")
                                }
                            }
                        }
                }
                .onMove(perform: move)
            } header: {
                Text("Tab Bar")
            } footer: {
                Text("Drag to rearrange. Aurora keeps at least one destination and shows at most five tabs.")
            }

            Section {
                if alternatives.isEmpty {
                    Text("Every destination is already selected.")
                        .foregroundColor(.secondary)
                }
                ForEach(alternatives) { tab in
                    Button { add(tab) } label: {
                        HStack {
                            Label(tab.label, systemImage: tab.symbol)
                            Spacer()
                            Image(systemName: "plus.circle")
                        }
                    }
                    .disabled(selected.count >= 5)
                }
            } header: {
                Text("Alternative Tabs")
            } footer: {
                if selected.count >= 5 {
                    Text("Remove one of the current tabs before adding another.")
                } else {
                    Text("Available: Browse, New, Installed, Library, Sources, Search, Queue, and Settings.")
                }
            }

            Section {
                Button("Restore Default Tabs") { store.resetTabs() }
            }
        }
        .navigationTitle("Customize Tabs")
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(.active))
    }

    private func move(from source: IndexSet, to destination: Int) {
        var tabs = selected
        tabs.move(fromOffsets: source, toOffset: destination)
        store.setTabs(tabs)
    }

    private func remove(_ tab: AppTab) {
        guard selected.count > 1 else { return }
        store.setTabs(selected.filter { $0 != tab })
    }

    private func add(_ tab: AppTab) {
        guard selected.count < 5, !selected.contains(tab) else { return }
        store.setTabs(selected + [tab])
    }
}
