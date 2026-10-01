import SwiftUI
import AuroraCore

@main
struct AuroraApp: App {
    /// The one store for the whole app: every screen reads the same repositories,
    /// indexes, queue and settings.
    @StateObject private var store = AuroraStore()

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
        }
    }
}

/// The tab bar and the two pieces of chrome that must be visible everywhere: the
/// "no jailbreak" banner and the error alert.
// `@MainActor` because `AuroraStore` is main-actor isolated: only `body` is
// isolated by default, so helper members that touch the store need it explicitly.
@MainActor
struct RootView: View {

    @ObservedObject var store: AuroraStore
    @State private var selection: Tab = .browse
    @State private var isImportingDeb = false

    enum Tab: Hashable {
        case browse
        case newPackages
        case installed
        case library
        case sources
        case search
        case queue
        case settings
    }

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                BrowseView(store: store)
            }
            .tabItem { Label("Browse", systemImage: "square.grid.2x2") }
            .tag(Tab.browse)

            NavigationStack {
                NewPackagesView(store: store)
            }
            .tabItem { Label("New", systemImage: "sparkles") }
            .tag(Tab.newPackages)

            NavigationStack {
                InstalledView(store: store)
            }
            .tabItem { Label("Installed", systemImage: "shippingbox") }
            .badge(store.installed.present.filter { package in
                store.newestRecord(named: package.name, newerThan: package.version) != nil
            }.count)
            .tag(Tab.installed)

            NavigationStack {
                LibraryView(store: store)
            }
            .tabItem { Label("Library", systemImage: "bookmark") }
            .tag(Tab.library)

            NavigationStack {
                SourcesListView(store: store)
            }
            .tabItem { Label("Sources", systemImage: "square.stack.3d.up") }
            .tag(Tab.sources)

            NavigationStack {
                SearchView(store: store)
            }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }
            .tag(Tab.search)

            NavigationStack {
                QueueView(store: store)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button { isImportingDeb = true } label: {
                                Image(systemName: "doc.badge.plus")
                            }
                            .accessibilityLabel("Open local Debian package")
                        }
                    }
            }
            .tabItem { Label("Queue", systemImage: "arrow.down.circle") }
            .badge(store.queueCount)
            .tag(Tab.queue)

            NavigationStack {
                SettingsView(store: store)
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(Tab.settings)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            EnvironmentBanner(store: store)
        }
        .task {
            await store.start()
        }
        .fileImporter(
            isPresented: $isImportingDeb,
            allowedContentTypes: [.data],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls where url.pathExtension.lowercased() == "deb" {
                    store.stageLocalPackage(at: url)
                }
                if !urls.isEmpty && !urls.contains(where: { $0.pathExtension.lowercased() == "deb" }) {
                    store.lastError = "Select a .deb package."
                }
            case .failure(let error):
                store.lastError = "Could not open package: (error.localizedDescription)"
            }
        }
        .onOpenURL { url in
            guard url.pathExtension.lowercased() == "deb" else { return }
            store.stageLocalPackage(at: url)
            selection = .queue
        }
        .auroraAlert(store)
    }
}

/// Says plainly what this device can and cannot do.
///
/// An empty view when everything is normal, so it costs nothing on a jailbroken
/// device; anything else would be permanent noise.
@MainActor
struct EnvironmentBanner: View {

    @ObservedObject var store: AuroraStore

    var body: some View {
        if store.isJailbroken {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No jailbreak detected")
                        .font(.subheadline.weight(.semibold))
                    Text("Browsing, searching and the queue work, but installing and removing are disabled: Aurora found no dpkg at any of the usual paths.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.18))
        }
    }
}

/// Presents `store.lastError` as an alert, without every screen having to build the
/// same binding.
@MainActor
struct AuroraAlertModifier: ViewModifier {

    @ObservedObject var store: AuroraStore

    func body(content: Content) -> some View {
        content.alert(
            "Aurora",
            isPresented: Binding(
                get: { store.lastError != nil },
                set: { presented in
                    if !presented { store.lastError = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }
}

extension View {
    func auroraAlert(_ store: AuroraStore) -> some View {
        modifier(AuroraAlertModifier(store: store))
    }
}
