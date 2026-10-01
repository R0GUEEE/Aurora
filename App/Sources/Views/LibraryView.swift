import SwiftUI
import AuroraCore

@MainActor
struct LibraryView: View {
    @ObservedObject var store: AuroraStore
    @State private var selection: LibraryScope = .bookmarks
    @State private var query = ""
    @State private var isClearingHistory = false
    @State private var isClearingRecent = false
    @State private var isCreatingCollection = false
    @State private var newCollectionName = ""
    @State private var message: String?

    private enum LibraryScope: String, CaseIterable, Identifiable {
        case bookmarks = "Bookmarks"
        case collections = "Collections"
        case recent = "Recent"
        case hidden = "Hidden"
        case history = "History"
        var id: String { rawValue }
    }

    private var savedNames: [String] {
        let saved = selection == .hidden ? store.userLibrary.hiddenPackages : store.userLibrary.bookmarks
        return saved.filter { name in
            matches(name) || matches(store.bestRecord(named: name)?.displayName ?? name)
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var recentVisits: [PackageVisit] {
        store.userLibrary.recentViews.filter {
            matches($0.package) || matches(store.bestRecord(named: $0.package)?.displayName ?? $0.package)
        }
    }

    private var history: [PackageActivity] {
        store.packageHistory.filter { matches($0.package) || matches($0.kind.rawValue) }
    }

    private var collections: [String] {
        store.collectionNames.filter { name in
            matches(name) || store.packageNames(inCollection: name).contains { package in
                matches(package) || matches(store.bestRecord(named: package)?.displayName ?? package)
            }
        }
    }

    private func matches(_ text: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty || text.localizedCaseInsensitiveContains(needle)
    }

    private var exportText: String {
        switch selection {
        case .bookmarks, .hidden:
            return savedNames.joined(separator: "\n")
        case .collections:
            return collections.flatMap { collection in
                ["[\(collection)]"] + store.packageNames(inCollection: collection)
            }.joined(separator: "\n")
        case .recent:
            return recentVisits.map {
                "\($0.date.ISO8601Format())\t\($0.package)"
            }.joined(separator: "\n")
        case .history:
            return history.map {
                "\($0.date.ISO8601Format())\t\($0.kind.rawValue)\t\($0.package)\t\($0.version ?? "")"
            }.joined(separator: "\n")
        }
    }

    var body: some View {
        let exportPayload = exportText
        return List {
            Picker("Library", selection: $selection) {
                ForEach(LibraryScope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu)

            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }

            switch selection {
            case .bookmarks, .hidden:
                savedPackages
            case .collections:
                collectionList
            case .recent:
                recentList
            case .history:
                historyList
            }
        }
        .navigationTitle("Library")
        .searchable(text: $query, prompt: "Search library")
        .onChange(of: selection) { _ in message = nil }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    if selection == .collections {
                        Button {
                            newCollectionName = ""
                            isCreatingCollection = true
                        } label: {
                            Label("New Collection", systemImage: "folder.badge.plus")
                        }
                    }

                    ShareLink(item: exportPayload, subject: Text("Aurora \(selection.rawValue)")) {
                        Label("Share \(selection.rawValue)", systemImage: "square.and.arrow.up")
                    }
                    .disabled(exportPayload.isEmpty)

                    if selection == .bookmarks {
                        Button {
                            let result = store.queueMissingBookmarks()
                            message = "Queued \(result.queued) missing packages; \(result.skipped) unavailable or incompatible. Open Queue to review."
                        } label: {
                            Label("Queue Missing Bookmarks", systemImage: "tray.and.arrow.down")
                        }
                        .disabled(store.userLibrary.bookmarks.isEmpty)

                        NavigationLink { QueueView(store: store) } label: {
                            Label("Review Queue", systemImage: "tray")
                        }
                    }

                    if selection == .recent {
                        Button(role: .destructive) { isClearingRecent = true } label: {
                            Label("Clear Recently Viewed", systemImage: "trash")
                        }
                        .disabled(store.userLibrary.recentViews.isEmpty)
                    }

                    if selection == .history {
                        Button(role: .destructive) { isClearingHistory = true } label: {
                            Label("Clear History", systemImage: "trash")
                        }
                        .disabled(store.packageHistory.isEmpty)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Library actions")
            }
        }
        .alert("New Collection", isPresented: $isCreatingCollection) {
            TextField("Collection name", text: $newCollectionName)
            Button("Create") {
                if let error = store.createCollection(named: newCollectionName) {
                    message = error
                } else {
                    message = "Created “\(newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines))”."
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Collections keep related packages together without changing their install state.")
        }
        .confirmationDialog("Clear package history?", isPresented: $isClearingHistory, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { store.clearPackageHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the activity log. Installed packages, bookmarks and collections are kept.")
        }
        .confirmationDialog("Clear recently viewed packages?", isPresented: $isClearingRecent, titleVisibility: .visible) {
            Button("Clear Recently Viewed", role: .destructive) { store.clearRecentViews() }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private var savedPackages: some View {
        if savedNames.isEmpty {
            EmptyMessage(
                symbol: selection == .hidden ? "eye.slash" : "bookmark",
                title: query.isEmpty ? "No \(selection.rawValue)" : "No matches",
                message: selection == .hidden
                    ? "Packages hidden from discovery appear here. Swipe to show them again."
                    : "Bookmark packages from their detail page. Saved IDs remain here even when their repository is unavailable."
            )
        }

        ForEach(savedNames, id: \.self) { name in
            savedRow(name)
                .swipeActions(edge: .trailing) {
                    if selection == .hidden {
                        Button { store.toggleHidden(name) } label: {
                            Label("Show Again", systemImage: "eye")
                        }.tint(.blue)
                    } else {
                        Button(role: .destructive) { store.toggleBookmark(name) } label: {
                            Label("Remove Bookmark", systemImage: "bookmark.slash")
                        }
                    }
                }
        }
    }

    @ViewBuilder
    private var collectionList: some View {
        if collections.isEmpty {
            EmptyMessage(
                symbol: "folder",
                title: query.isEmpty ? "No Collections" : "No matches",
                message: "Create collections for themes, setups, testing groups or packages you want to revisit."
            )
        }

        ForEach(collections, id: \.self) { name in
            NavigationLink {
                PackageCollectionView(store: store, collection: name)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                        let count = store.packageNames(inCollection: name).count
                        Text("\(count) package\(count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .swipeActions {
                Button(role: .destructive) {
                    store.deleteCollection(named: name)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private var recentList: some View {
        if recentVisits.isEmpty {
            EmptyMessage(
                symbol: "clock",
                title: query.isEmpty ? "Nothing Viewed Yet" : "No matches",
                message: "Packages you open appear here so you can quickly return to them."
            )
        }

        ForEach(recentVisits) { visit in
            Group {
                if let record = store.bestRecord(named: visit.package) {
                    NavigationLink { PackageDetailView(store: store, record: record) } label: {
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
                            Button { store.stage(store.defaultAction(for: record)) } label: {
                                Label("Queue", systemImage: "tray.and.arrow.down")
                            }.tint(.blue)
                        }
                    }
                } else {
                    unavailableRow(visit.package, subtitle: "Viewed \(visit.date.formatted(date: .abbreviated, time: .shortened))")
                }
            }
        }
    }

    @ViewBuilder
    private var historyList: some View {
        if history.isEmpty {
            EmptyMessage(symbol: "clock.arrow.circlepath", title: "No History", message: "Successfully completed package changes appear here.")
        }

        ForEach(history) { event in
            Group {
                if let record = store.bestRecord(named: event.package) {
                    NavigationLink { PackageDetailView(store: store, record: record) } label: {
                        historyRow(event)
                    }
                } else {
                    historyRow(event)
                }
            }
        }
    }

    @ViewBuilder
    private func savedRow(_ name: String) -> some View {
        if let record = store.bestRecord(named: name) {
            NavigationLink { PackageDetailView(store: store, record: record) } label: {
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
                    Button { store.stage(store.defaultAction(for: record)) } label: {
                        Label("Queue", systemImage: "tray.and.arrow.down")
                    }.tint(.blue)
                }
            }
        } else {
            unavailableRow(name, subtitle: "Unavailable in loaded repositories")
        }
    }

    private func unavailableRow(_ name: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(subtitle)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func historyRow(_ event: PackageActivity) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(event.package)
            Text("\(event.kind.rawValue.capitalized)\(event.version.map { " · \($0)" } ?? "")")
                .font(.caption).foregroundStyle(.secondary)
            Text(event.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

@MainActor
private struct PackageCollectionView: View {
    @ObservedObject var store: AuroraStore
    let collection: String
    @State private var query = ""
    @State private var message: String?

    private var names: [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.packageNames(inCollection: collection).filter { name in
            needle.isEmpty
                || name.localizedCaseInsensitiveContains(needle)
                || (store.bestRecord(named: name)?.displayName.localizedCaseInsensitiveContains(needle) == true)
        }
    }

    private var exportText: String {
        names.joined(separator: "\n")
    }

    var body: some View {
        List {
            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }

            if names.isEmpty {
                EmptyMessage(
                    symbol: "folder",
                    title: query.isEmpty ? "Empty Collection" : "No matches",
                    message: "Add packages from a package detail page."
                )
            }

            ForEach(names, id: \.self) { name in
                if let record = store.bestRecord(named: name) {
                    NavigationLink { PackageDetailView(store: store, record: record) } label: {
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
                            Button { store.stage(store.defaultAction(for: record)) } label: {
                                Label("Queue", systemImage: "tray.and.arrow.down")
                            }.tint(.blue)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.setPackage(name, inCollection: collection, included: false)
                        } label: {
                            Label("Remove", systemImage: "folder.badge.minus")
                        }
                    }
                } else {
                    HStack {
                        Image(systemName: "shippingbox").foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(name)
                            Text("Unavailable in loaded repositories").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            store.setPackage(name, inCollection: collection, included: false)
                        } label: {
                            Label("Remove", systemImage: "folder.badge.minus")
                        }
                    }
                }
            }
        }
        .navigationTitle(collection)
        .searchable(text: $query, prompt: "Search collection")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button {
                        let result = store.queueMissingPackages(store.packageNames(inCollection: collection))
                        message = "Queued \(result.queued) packages; \(result.skipped) unavailable or incompatible."
                    } label: {
                        Label("Queue Missing Packages", systemImage: "tray.and.arrow.down")
                    }
                    .disabled(store.packageNames(inCollection: collection).isEmpty)

                    NavigationLink { QueueView(store: store) } label: {
                        Label("Review Queue", systemImage: "tray")
                    }

                    ShareLink(item: exportText, subject: Text("Aurora \(collection)")) {
                        Label("Share Collection", systemImage: "square.and.arrow.up")
                    }
                    .disabled(exportText.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }
}
