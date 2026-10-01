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
            behaviorSection
            tabsSection
            backupSection
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
            Toggle("Auto-disable repeatedly failing repositories", isOn: Binding(
                get: { store.settings.autoDisableBadRepositories },
                set: { store.setAutoDisableBadRepositories($0) }
            ))
            Stepper("Disable after \(store.settings.badRepositoryFailureThreshold) failures", value: Binding(
                get: { store.settings.badRepositoryFailureThreshold },
                set: { store.setBadRepositoryFailureThreshold($0) }
            ), in: 1...10)
            .disabled(!store.settings.autoDisableBadRepositories)
            Toggle("Skip failed repositories during Refresh All", isOn: Binding(
                get: { store.settings.skipFailedRepositories },
                set: { store.setSkipFailedRepositories($0) }
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

        } header: {
            Text("Repositories")
        } footer: {
            Text("Failed-repository skipping keeps dead sources out of normal bulk refreshes; Retry Failed and per-repository refresh still test them. Most jailbreak repositories are unsigned; with signature checking enforced they are refused instead of being shown with a warning. Rootful packages use legacy root filesystem paths and are not automatically converted by Aurora.")
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

    // MARK: - Behavior

    private var behaviorSection: some View {
        Section {
            Toggle("Refresh repositories on launch", isOn: Binding(
                get: { store.settings.autoRefreshOnLaunch },
                set: { store.setAutoRefreshOnLaunch($0) }
            ))
            Toggle("Refresh stale repositories on foreground", isOn: Binding(
                get: { store.settings.refreshOnForeground },
                set: { store.setRefreshOnForeground($0) }
            ))
            Stepper("Foreground refresh interval: \(store.settings.foregroundRefreshIntervalMinutes) min", value: Binding(
                get: { store.settings.foregroundRefreshIntervalMinutes },
                set: { store.setForegroundRefreshIntervalMinutes($0) }
            ), in: 5...1440, step: 5)
            .disabled(!store.settings.refreshOnForeground)
            Stepper("Refresh concurrency: \(store.settings.refreshConcurrency)", value: Binding(
                get: { store.settings.refreshConcurrency },
                set: { store.setRefreshConcurrency($0) }
            ), in: 2...12)
            Stepper("Repository timeout: \(store.settings.repositoryTimeoutSeconds)s", value: Binding(
                get: { store.settings.repositoryTimeoutSeconds },
                set: { store.setRepositoryTimeoutSeconds($0) }
            ), in: 3...60)
            Menu("Performance Preset") {
                Button("Aggressive") { store.applyPerformancePreset("aggressive") }
                Button("Balanced") { store.applyPerformancePreset("balanced") }
                Button("Conservative") { store.applyPerformancePreset("conservative") }
            }
            Toggle("Fast parallel repository scan", isOn: Binding(
                get: { store.settings.fastRepositoryScan },
                set: { store.setFastRepositoryScan($0) }
            ))
            Stepper("Whole-repo deadline: \(store.settings.repositoryRefreshDeadlineSeconds)s", value: Binding(
                get: { store.settings.repositoryRefreshDeadlineSeconds },
                set: { store.setRepositoryRefreshDeadlineSeconds($0) }
            ), in: 10...180, step: 5)
            Toggle("Remember working index compression", isOn: Binding(
                get: { store.settings.preferCachedIndexFormat },
                set: { store.setPreferCachedIndexFormat($0) }
            ))
            Toggle("Use repository index cache", isOn: Binding(
                get: { store.settings.useRepositoryCache },
                set: { store.setUseRepositoryCache($0) }
            ))
            Stepper("Maximum index size: \(store.settings.maximumIndexSizeMB) MB", value: Binding(
                get: { store.settings.maximumIndexSizeMB },
                set: { store.setMaximumIndexSizeMB($0) }
            ), in: 32...1024, step: 32)
            Toggle("Show repository warnings", isOn: Binding(
                get: { store.settings.showRepositoryWarnings },
                set: { store.setShowRepositoryWarnings($0) }
            ))
            Toggle("Retry failed repositories during Refresh All", isOn: Binding(
                get: { store.settings.refreshFailedRepositories },
                set: { store.setRefreshFailedRepositories($0) }
            ))
            .disabled(!store.settings.skipFailedRepositories)
            Stepper("New package window: \(store.settings.newPackageDays) days", value: Binding(
                get: { store.settings.newPackageDays },
                set: { store.setNewPackageDays($0) }
            ), in: 1...90)
            Stepper("Home items: \(store.settings.homePackageLimit)", value: Binding(
                get: { store.settings.homePackageLimit },
                set: { store.setHomePackageLimit($0) }
            ), in: 3...20)
            Toggle("Show package icons", isOn: Binding(
                get: { store.settings.showPackageIcons },
                set: { store.setShowPackageIcons($0) }
            ))
            Toggle("Compact package rows", isOn: Binding(
                get: { store.settings.compactPackageRows },
                set: { store.setCompactPackageRows($0) }
            ))
            Toggle("Show package descriptions", isOn: Binding(
                get: { store.settings.showPackageDescriptions },
                set: { store.setShowPackageDescriptions($0) }
            ))
            .disabled(store.settings.compactPackageRows)
            Toggle("Confirm queue before installation", isOn: Binding(
                get: { store.settings.confirmQueueBeforeInstall },
                set: { store.setConfirmQueueBeforeInstall($0) }
            ))
            Toggle("Refresh after transactions", isOn: Binding(
                get: { store.settings.refreshAfterTransaction },
                set: { store.setRefreshAfterTransaction($0) }
            ))
        } header: {
            Text("Behavior & Appearance")
        } footer: {
            Text("Fast Scan races flat-repository index formats and uses a wider parallel source window. Per-request timeout controls individual metadata requests; the whole-repo deadline prevents one source from occupying a worker indefinitely. Remembering the last working compression format reduces probes on repeat refreshes.")
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

    // MARK: - Backup

    private var backupSection: some View {
        Section {
            ShareLink(item: store.exportedBackup, subject: Text("Aurora Backup")) {
                Label("Export Aurora Backup", systemImage: "square.and.arrow.up")
            }
            NavigationLink {
                BackupRestoreView(store: store)
            } label: {
                Label("Restore Backup", systemImage: "arrow.counterclockwise.icloud")
            }
        } header: {
            Text("Backup & Restore")
        } footer: {
            Text("Backups include sources, settings, tab layout, bookmarks, hidden packages, package holds/pins and the installed-package manifest.")
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
            ForEach(store.cacheBreakdown(), id: \.name) { item in
                DetailRow(label: item.name, value: AuroraFormat.bytes(item.bytes))
            }
            Toggle("Auto-clean repository data", isOn: Binding(
                get: { store.settings.autoCleanRepositoryData },
                set: { store.setAutoCleanRepositoryData($0) }
            ))
            Toggle("Auto-clean downloaded packages", isOn: Binding(
                get: { store.settings.autoCleanDownloadedPackages },
                set: { store.setAutoCleanDownloadedPackages($0) }
            ))
            Button {
                statusText = store.cleanRepositoryData()
            } label: {
                Label("Clean Repository Data", systemImage: "arrow.triangle.2.circlepath")
            }
            Button {
                statusText = store.pruneUnusedLocalPackages()
            } label: {
                Label("Clean Unused Local Packages", systemImage: "trash")
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
            Button("Reset Settings to Defaults", role: .destructive) { store.resetSettings() }
            Button("Show state files") { isShowingLogs = true }
            ShareLink(item: store.diagnosticsReport) {
                Label("Share Diagnostics Report", systemImage: "square.and.arrow.up")
            }
            Button {
                UIPasteboard.general.string = store.diagnosticsReport
                statusText = "Diagnostics copied to clipboard."
            } label: {
                Label("Copy Diagnostics", systemImage: "doc.on.doc")
            }
            if let message = store.sourcesPersistenceError {
                NoticeRow(symbol: "externaldrive.badge.exclamationmark", text: message, color: .orange)
            }
            if let message = store.settingsPersistenceError {
                NoticeRow(symbol: "gearshape.badge.xmark", text: message, color: .orange)
            }
            if let message = store.policyPersistenceError {
                NoticeRow(symbol: "pin.slash", text: message, color: .orange)
            }
            DetailRow(label: "Failed repositories", value: "\(store.failedSourceIDs.count)")
            DetailRow(label: "Held / pinned packages", value: "\(store.packagePolicy.pins.count)")
            NavigationLink {
                DiagnosticsView(store: store)
            } label: {
                Label("Open Diagnostics", systemImage: "stethoscope")
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
    private var alternatives: [AppTab] { AppTab.allCases.filter { $0 != .settings && !selected.contains($0) } }

    var body: some View {
        List {
            Section {
                ForEach(selected) { tab in
                    HStack {
                        Label(tab.label, systemImage: tab.symbol)
                        Spacer()
                        Menu {
                            ForEach(alternatives) { replacement in
                                Button {
                                    replace(tab, with: replacement)
                                } label: {
                                    Label(replacement.label, systemImage: replacement.symbol)
                                }
                            }
                            Divider()
                            Button(role: .destructive) { remove(tab) } label: {
                                Label("Remove Tab", systemImage: "minus.circle")
                            }
                            .disabled(selected.count <= 1)
                        } label: {
                            Label("Replace", systemImage: "arrow.left.arrow.right")
                                .labelStyle(.iconOnly)
                        }
                    }
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
                Text("Drag to reorder, tap the arrows to replace a tab immediately, or swipe to remove it. Up to five destinations can be selected.")
            }

            Section {
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
                Text("Available Destinations")
            } footer: {
                Text(selected.count >= 5 ? "Replace or remove a current tab to make room." : "Settings is always available from the Home page and does not use a tab slot.")
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
        guard tab != .settings, selected.count < 5, !selected.contains(tab) else { return }
        store.setTabs(selected + [tab])
    }

    private func replace(_ old: AppTab, with new: AppTab) {
        guard new != .settings, !selected.contains(new),
              let index = selected.firstIndex(of: old) else { return }
        var tabs = selected
        tabs[index] = new
        store.setTabs(tabs)
    }
}

@MainActor
struct BackupRestoreView: View {
    @ObservedObject var store: AuroraStore
    @State private var text = ""

    var body: some View {
        Form {
            Section {
                TextEditor(text: $text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 220)
            } header: {
                Text("Backup JSON")
            } footer: {
                Text("Paste an Aurora backup exported from this or another device.")
            }

            Button("Restore Backup") {
                _ = store.importBackup(text)
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .navigationTitle("Restore Backup")
        .navigationBarTitleDisplayMode(.inline)
    }
}


@MainActor
struct DiagnosticsView: View {
    @ObservedObject var store: AuroraStore

    var body: some View {
        List {
            Section("Environment") {
                DetailRow(label: "Layout", value: store.environment.layout.rawValue)
                DetailRow(label: "Architecture", value: store.environment.architecture)
                DetailRow(label: "Repositories", value: "\(store.sources.count)")
                DetailRow(label: "Packages", value: "\(store.totalPackageCount)")
                DetailRow(label: "Installed", value: "\(store.installed.present.count)")
                DetailRow(label: "Broken", value: "\(store.installed.brokenPackages.count)")
            }

            Section("Repository Failures") {
                if store.failedSourceIDs.isEmpty {
                    Label("No repository errors", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else {
                    Button("Retry All Failed") {
                        Task { await store.refreshFailedSources() }
                    }
                    .disabled(store.refreshState.isRefreshing)

                    ForEach(store.sources.filter { store.indexErrors[$0.id] != nil }) { source in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.name).font(.headline)
                            Text(source.normalizedURL).font(.caption2).foregroundColor(.secondary)
                            Text(store.indexErrors[source.id] ?? "Unknown error")
                                .font(.caption)
                                .foregroundColor(.red)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            Section("Package Policy") {
                if store.packagePolicy.pins.isEmpty {
                    Text("No package holds or pins.")
                        .foregroundColor(.secondary)
                }
                ForEach(store.packagePolicy.pins.keys.sorted(), id: \.self) { name in
                    HStack {
                        Text(name)
                        Spacer()
                        Text(store.packagePolicy.pin(for: name)?.label ?? "")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
    }
}
