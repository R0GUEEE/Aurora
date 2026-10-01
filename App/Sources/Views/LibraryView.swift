import SwiftUI
import AuroraCore

@MainActor
struct LibraryView: View {
    @ObservedObject var store: AuroraStore
    @State private var selection: LibraryScope = .bookmarks
    @State private var query = ""
    @State private var isClearingHistory = false
    @State private var message: String?

    private enum LibraryScope: String, CaseIterable, Identifiable {
        case bookmarks = "Bookmarks", hidden = "Hidden", history = "History"
        var id: String { rawValue }
    }

    private var names: [String] {
        let saved = selection == .hidden ? store.userLibrary.hiddenPackages : store.userLibrary.bookmarks
        return saved.filter { name in
            matches(name) || matches(store.bestRecord(named: name)?.displayName ?? name)
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var history: [PackageActivity] {
        store.packageHistory.filter { matches($0.package) || matches($0.kind.rawValue) }
    }

    private func matches(_ text: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return needle.isEmpty || text.localizedCaseInsensitiveContains(needle)
    }

    private var exportText: String {
        if selection == .history {
            return history.map {
                "\($0.date.ISO8601Format())\t\($0.kind.rawValue)\t\($0.package)\t\($0.version ?? "")"
            }.joined(separator: "\n")
        }
        return names.joined(separator: "\n")
    }

    var body: some View {
        List {
            Picker("Library", selection: $selection) {
                ForEach(LibraryScope.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)

            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }

            if selection != .history {
                if names.isEmpty {
                    EmptyMessage(
                        symbol: selection == .hidden ? "eye.slash" : "bookmark",
                        title: query.isEmpty ? "No \(selection.rawValue)" : "No matches",
                        message: selection == .hidden
                            ? "Packages hidden from discovery appear here. Swipe to show them again."
                            : "Bookmark packages from their detail page. Saved IDs remain here even when their repository is unavailable."
                    )
                }
                ForEach(names, id: \.self) { name in
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
            } else {
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
        }
        .navigationTitle("Library")
        .searchable(text: $query, prompt: "Search saved packages or history")
        .onChange(of: selection) { _ in message = nil }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    ShareLink(item: exportText, subject: Text("Aurora \(selection.rawValue)")) {
                        Label("Share \(selection.rawValue)", systemImage: "square.and.arrow.up")
                    }
                    .disabled(exportText.isEmpty)
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
        .confirmationDialog("Clear package history?", isPresented: $isClearingHistory, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { store.clearPackageHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes the activity log. Installed packages and bookmarks are kept.")
        }
    }

    @ViewBuilder
    private func savedRow(_ name: String) -> some View {
        if let record = store.bestRecord(named: name) {
            NavigationLink { PackageDetailView(store: store, record: record) } label: {
                PackageRow(record: record, state: store.state(for: record),
                           showIcon: store.settings.showPackageIcons, compact: store.settings.compactPackageRows,
                           showDescription: store.settings.showPackageDescriptions)
            }
        } else {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    Text("Unavailable in loaded repositories")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
