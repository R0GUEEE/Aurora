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
    @State private var selection: AppTab = .home
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView(selection: $selection) {
            ForEach(store.settings.tabs) { tab in
                tabView(tab)
                    .tabItem { Label(tab.label, systemImage: tab.symbol) }
                    .tag(tab)
                    .badge(badge(for: tab))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            EnvironmentBanner(store: store)
        }
        .task {
            await store.start()
            if !store.settings.tabs.contains(selection), let first = store.settings.tabs.first {
                selection = first
            }
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active else { return }
            Task { await store.refreshIfStale() }
        }
        .onChange(of: store.settings.tabs) { tabs in
            if !tabs.contains(selection), let first = tabs.first {
                selection = first
            }
        }
        .onOpenURL { url in
            guard url.pathExtension.lowercased() == "deb" else { return }
            store.stageLocalPackage(at: url)
            if store.settings.tabs.contains(.queue) { selection = .queue }
        }
        .auroraAlert(store)
    }

    @ViewBuilder
    private func tabView(_ tab: AppTab) -> some View {
        switch tab {
        case .browse:
            NavigationStack { BrowseView(store: store) }
        case .home:
            NavigationStack { HomeView(store: store) }
        case .newPackages:
            NavigationStack { NewPackagesView(store: store) }
        case .installed:
            NavigationStack { InstalledView(store: store) }
        case .library:
            NavigationStack { LibraryView(store: store) }
        case .sources:
            NavigationStack { SourcesListView(store: store) }
        case .search:
            NavigationStack { SearchView(store: store) }
        case .queue:
            NavigationStack { QueueView(store: store) }
        case .settings:
            NavigationStack { SettingsView(store: store) }
        }
    }

    private func badge(for tab: AppTab) -> Int {
        switch tab {
        case .installed: return store.upgradePlan.count
        case .queue: return store.queueCount
        default: return 0
        }
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
