import SwiftUI
import AuroraCore

@MainActor
struct LibraryView: View {
    @ObservedObject var store: AuroraStore
    @State private var selection = 0

    var body: some View {
        List {
            Picker("Library", selection: $selection) {
                Text("Bookmarks").tag(0)
                Text("History").tag(1)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)

            if selection == 0 {
                if store.bookmarkedRecords.isEmpty {
                    EmptyMessage(symbol: "bookmark", title: "No Bookmarks", message: "Bookmark packages from their detail page to keep them here.")
                }
                ForEach(store.bookmarkedRecords) { record in
                    NavigationLink { PackageDetailView(store: store, record: record) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.displayName)
                            Text(record.version.raw).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
            } else {
                if store.packageHistory.isEmpty {
                    EmptyMessage(symbol: "clock.arrow.circlepath", title: "No History", message: "Package actions you stage will appear here.")
                }
                ForEach(store.packageHistory) { event in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.package)
                        Text("\(event.kind.rawValue.capitalized)\(event.version.map { " · \($0)" } ?? "")")
                            .font(.caption).foregroundColor(.secondary)
                        Text(event.date, style: .relative).font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Library")
    }
}
