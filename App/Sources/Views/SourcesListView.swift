import SwiftUI
import WebKit
import AuroraCore

/// Add, remove, enable, disable and refresh repositories.
// `@MainActor` because `AuroraStore` is main-actor isolated: only `body` is
// isolated by default, so helper members that touch the store need it explicitly.
@MainActor
struct SourcesListView: View {

    @ObservedObject var store: AuroraStore

    @State private var isAddingSource = false
    @State private var isConfirmingRestore = false
    @State private var isImportingSources = false
    @State private var isBrowsingRepoUpdates = false
    @State private var query = ""
    @State private var filter: SourceFilter = .all
    @State private var isExportingSources = false
    @State private var exportDocument = TextTransferDocument(text: "")

    private enum SourceFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case enabled = "Enabled"
        case failed = "Needs Attention"
        case disabled = "Disabled"
        var id: String { rawValue }
    }

    private var displayedSources: [RepositorySource] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.sources.filter { source in
            let matches: Bool
            switch filter {
            case .all: matches = true
            case .enabled: matches = source.isEnabled
            case .failed: matches = store.indexErrors[source.id] != nil
            case .disabled: matches = !source.isEnabled
            }
            return matches && (needle.isEmpty
                || source.name.localizedCaseInsensitiveContains(needle)
                || source.normalizedURL.localizedCaseInsensitiveContains(needle))
        }
    }

    private var isFiltering: Bool {
        filter != .all || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        List {
            if let message = store.sourcesPersistenceError {
                Section {
                    NoticeRow(symbol: "externaldrive.badge.exclamationmark", text: message, color: .orange)
                }
            }

            Section {
                if store.sources.isEmpty {
                    EmptyMessage(
                        symbol: "square.stack.3d.up.slash",
                        title: "No repositories",
                        message: "Add a repository by URL, or restore the defaults."
                    )
                } else if displayedSources.isEmpty {
                    EmptyMessage(
                        symbol: "line.3.horizontal.decrease.circle",
                        title: "No matching repositories",
                        message: "Try another name or URL, or change the health filter."
                    )
                } else {
                    // Swipe left to delete, swipe right to refresh one repository.
                    ForEach(displayedSources) { source in
                        NavigationLink {
                            RepositoryDetailView(store: store, sourceID: source.id)
                        } label: {
                            SourceRow(store: store, source: source)
                        }
                            .swipeActions(edge: .leading) {
                                Button {
                                    Task { await store.refresh(sourceID: source.id) }
                                } label: {
                                    Label("Refresh", systemImage: "arrow.clockwise")
                                }
                                .tint(.blue)
                            }
                            .moveDisabled(isFiltering)
                    }
                    .onMove { offsets, destination in
                        if !isFiltering { store.moveSources(from: offsets, to: destination) }
                    }
                    .onDelete { offsets in
                        // Capture the ids first: removing a source shifts the
                        // indices of the ones after it.
                        let visible = displayedSources
                        let ids = offsets.compactMap { offset in
                            offset < visible.count ? visible[offset].id : nil
                        }
                        for id in ids {
                            store.removeSource(id: id)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Repositories")
                    Spacer()
                    if isFiltering { Text("\(displayedSources.count) of \(store.sources.count)") }
                }
            } footer: {
                Text("\(store.totalPackageCount) packages in the merged index.")
            }

            if store.refreshState.isRefreshing {
                RefreshActivitySection(store: store)
            }

            Section("Repository Health") {
                LabeledContent("Enabled", value: "\(store.sources.filter(\.isEnabled).count) / \(store.sources.count)")
                LabeledContent("Failed", value: "\(store.failedSourceIDs.count)")
                if store.skippedFailedSourceCount > 0 {
                    LabeledContent("Skipped on bulk refresh", value: "\(store.skippedFailedSourceCount)")
                    Text("Failed repositories are skipped during normal refreshes so unreachable sources cannot hold up the rest. Retry them explicitly when you want Aurora to test them again.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Button("Retry Failed Repositories") {
                    Task { await store.refreshFailedSources() }
                }
                .disabled(store.failedSourceIDs.isEmpty || store.refreshState.isRefreshing)

                Menu("Bulk Actions") {
                    Button("Enable All") { store.setAllSourcesEnabled(true) }
                    Button("Disable All") { store.setAllSourcesEnabled(false) }
                    Button("Enable Failed") { store.enableFailedSources(true) }
                        .disabled(store.failedSourceIDs.isEmpty)
                    Button("Disable Failed") { store.enableFailedSources(false) }
                        .disabled(store.failedSourceIDs.isEmpty)
                    Button("Remove Failed Custom Repositories", role: .destructive) {
                        store.removeFailedSources()
                    }
                    .disabled(store.failedSourceIDs.isEmpty)
                }
            }

            Section("Transfer") {
                Button {
                    exportDocument = TextTransferDocument(text: store.exportedSources)
                    isExportingSources = true
                } label: {
                    Label("Save Sources to Files", systemImage: "doc.badge.arrow.up")
                }
                ShareLink(item: store.exportedSources, subject: Text("Aurora Sources")) {
                    Label("Export Sources", systemImage: "square.and.arrow.up")
                }
                Button {
                    isImportingSources = true
                } label: {
                    Label("Import Sources", systemImage: "square.and.arrow.down")
                }
                Button {
                    isBrowsingRepoUpdates = true
                } label: {
                    Label("Browse iOS Repo Updates", systemImage: "safari")
                }
            }

            Section {
                Button("Restore default repositories") {
                    isConfirmingRestore = true
                }
            } footer: {
                Text("Adds back the repositories Aurora ships with (Procursus, Chariz, Havoc) without removing the ones you added.")
            }

            if let message = store.installedError {
                Section {
                    NoticeRow(symbol: "shippingbox.and.arrow.backward", text: message, color: .orange)
                } header: {
                    Text("Installed packages")
                } footer: {
                    Text("Without the dpkg database Aurora cannot tell what is installed, so every action would look like a fresh install.")
                }
            }
        }
        .navigationTitle("Sources")
        .searchable(text: $query, prompt: "Repository name or URL")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    Task { await store.refreshAll() }
                } label: {
                    if store.refreshState.isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(store.refreshState.isRefreshing)
                .accessibilityLabel("Refresh all repositories")
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Menu {
                    Picker("Show Repositories", selection: $filter) {
                        ForEach(SourceFilter.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                } label: {
                    Image(systemName: filter == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityLabel("Filter repositories")
                EditButton()
                Button {
                    isAddingSource = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add repository")
            }
        }
        .refreshable {
            await store.refreshAll()
        }
        .sheet(isPresented: $isAddingSource) {
            AddSourceSheet(store: store)
        }
        .sheet(isPresented: $isImportingSources) {
            ImportSourcesSheet(store: store)
        }
        .sheet(isPresented: $isBrowsingRepoUpdates) {
            IOSRepoUpdatesBrowser(store: store)
        }
        .fileExporter(isPresented: $isExportingSources, document: exportDocument, contentType: .plainText, defaultFilename: "aurora-sources.txt") { result in
            if case .failure(let error) = result { store.lastError = error.localizedDescription }
        }
        .confirmationDialog(
            "Restore default repositories?",
            isPresented: $isConfirmingRestore,
            titleVisibility: .visible
        ) {
            Button("Restore") { store.restoreDefaultSources() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Repositories you removed earlier will come back.")
        }
        .overlay(alignment: .bottom) {
            if store.refreshState.isRefreshing {
                Text(store.refreshState.label)
                    .font(.caption)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color(.secondarySystemBackground)))
                    .padding(.bottom, 8)
            }
        }
    }
}


@MainActor
private struct RefreshActivitySection: View {
    @ObservedObject var store: AuroraStore

    private var activeSources: [RepositorySource] {
        store.sources.filter { store.repositoryRefreshActivity[$0.id] != nil }
    }

    var body: some View {
        Section("Refresh Activity") {
            ForEach(activeSources) { source in
                RefreshActivityRow(
                    source: source,
                    activity: store.repositoryRefreshActivity[source.id]
                )
            }
        }
    }
}

private struct RefreshActivityRow: View {
    let source: RepositorySource
    let activity: RepositoryRefreshActivity?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                Text(activity?.message ?? activity?.phase.rawValue ?? "Queued")
                    .font(.caption2)
                    .foregroundColor(activity?.phase == .failed ? .red : .secondary)
                    .lineLimit(2)
            }
            Spacer()
            if activity?.phase == .refreshing {
                ProgressView()
            } else if let phase = activity?.phase {
                Text(phase.rawValue)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}


@MainActor
struct RepositoryDetailView: View {
    @ObservedObject var store: AuroraStore
    let sourceID: UUID
    @State private var query = ""
    @State private var confirmingRemoval = false
    @State private var editingSource = false
    @State private var confirmingReset = false

    private var source: RepositorySource? {
        store.sources.first { $0.id == sourceID }
    }

    private var records: [PackageRecord] {
        store.packageRecords(for: sourceID, matching: query)
    }

    var body: some View {
        List {
            if let source {
                Section {
                    HStack(spacing: 14) {
                        RepositoryIcon(source: source, size: 64)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.name).font(.title3.weight(.semibold))
                            Text(source.normalizedURL)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.vertical, 4)
                    LabeledContent("URL", value: source.normalizedURL)
                    LabeledContent("Layout", value: source.isFlat ? "Flat" : "Dists")
                    LabeledContent("Packages", value: "\(store.packageCount(for: sourceID))")
                    LabeledContent("Updated", value: AuroraFormat.relative(source.lastRefreshed))
                    Stepper(
                        "Priority: \(store.sourcePriority(id: sourceID))",
                        value: Binding(
                            get: { store.sourcePriority(id: sourceID) },
                            set: { store.setSourcePriority(id: sourceID, priority: $0) }
                        ),
                        in: 0...1000,
                        step: 50
                    )
                    if let signature = store.signatureDescription(for: sourceID) {
                        LabeledContent("Signature", value: signature)
                    }
                } header: {
                    Text("Repository")
                }

                if let error = store.indexErrors[sourceID] {
                    Section {
                        NoticeRow(symbol: "exclamationmark.triangle.fill", text: error, color: .red)
                    }
                }

                Section {
                    if records.isEmpty {
                        EmptyMessage(
                            symbol: query.isEmpty ? "shippingbox" : "magnifyingglass",
                            title: query.isEmpty ? "No packages loaded" : "No matching packages",
                            message: query.isEmpty
                                ? "Refresh this repository to download its package index."
                                : "Try a different package name, identifier, description, or section."
                        )
                    } else {
                        ForEach(records, id: \.self) { record in
                            NavigationLink {
                                PackageDetailView(store: store, record: record)
                            } label: {
                                PackageRow(record: record, state: store.state(for: record), showIcon: store.settings.showPackageIcons, compact: store.settings.compactPackageRows, showDescription: store.settings.showPackageDescriptions)
                            }
                        }
                    }
                } header: {
                    Text("Packages")
                } footer: {
                    Text("\(records.count) package\(records.count == 1 ? "" : "s") shown.")
                }
            } else {
                EmptyMessage(
                    symbol: "exclamationmark.triangle",
                    title: "Repository removed",
                    message: "This repository is no longer configured."
                )
            }
        }
        .navigationTitle(source?.name ?? "Repository")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search this repository")
        .refreshable {
            await store.refresh(sourceID: sourceID)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if let source {
                    ShareLink(item: source.normalizedURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Menu {
                        Button {
                            UIPasteboard.general.string = source.normalizedURL
                        } label: {
                            Label("Copy Repository URL", systemImage: "doc.on.doc")
                        }
                        Button { editingSource = true } label: {
                            Label("Edit Repository", systemImage: "pencil")
                        }
                        Button {
                            store.setSourceEnabled(id: sourceID, enabled: !source.isEnabled)
                        } label: {
                            Label(source.isEnabled ? "Disable Repository" : "Enable Repository",
                                  systemImage: source.isEnabled ? "pause.circle" : "play.circle")
                        }
                        if store.indexErrors[sourceID] != nil {
                            Button {
                                store.clearSourceError(id: sourceID)
                            } label: {
                                Label("Clear Error State", systemImage: "checkmark.circle")
                            }
                        }
                        Button { confirmingReset = true } label: {
                            Label("Reset Repository Data", systemImage: "arrow.counterclockwise")
                        }
                        if !source.isBuiltIn {
                            Divider()
                            Button(role: .destructive) { confirmingRemoval = true } label: {
                                Label("Remove Repository", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                Button {
                    Task { await store.refresh(sourceID: sourceID) }
                } label: {
                    if store.refreshState.isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(store.refreshState.isRefreshing || source == nil)
                .accessibilityLabel("Refresh repository")
            }
        }
        .sheet(isPresented: $editingSource) {
            if let source {
                EditSourceSheet(store: store, source: source)
            }
        }
        .confirmationDialog("Reset repository data?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset Repository", role: .destructive) { store.resetSourceData(id: sourceID) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Clears Aurora's loaded package index, warnings, signature state, error and refresh timestamp for this source. Installed packages are untouched.")
        }
        .confirmationDialog("Remove this repository?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove Repository", role: .destructive) { store.removeSource(id: sourceID) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Installed packages are not removed. Aurora will stop using this repository for package discovery and updates.")
        }
    }
}

/// A repository row: identity, state, count, last refresh and the error that
/// refresh produced.
@MainActor
struct SourceRow: View {

    @ObservedObject var store: AuroraStore
    let source: RepositorySource

    @State private var isShowingWarnings = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RepositoryIcon(source: source)
            VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(source.name)
                    .font(.body)
                    .lineLimit(1)
                if source.isBuiltIn {
                    Text("Built-in")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.18)))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 6)
                Toggle("", isOn: Binding(
                    get: { source.isEnabled },
                    set: { store.setSourceEnabled(id: source.id, enabled: $0) }
                ))
                .labelsHidden()
            }

            Text(source.normalizedURL)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 10) {
                Text(source.isFlat ? "Flat" : "Distribution")
                Text("\(store.packageCount(for: source.id)) pkgs")
                Text("refreshed \(AuroraFormat.relative(source.lastRefreshed))")
            }
            .font(.caption2)
            .foregroundColor(.secondary)

            if let signature = store.signatureDescription(for: source.id), source.isEnabled {
                Text(signature)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            // The last refresh error, kept per source so one dead repository does
            // not hide the state of the others.
            if let error = store.indexErrors[source.id] {
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundColor(.red)
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            let warnings = store.settings.showRepositoryWarnings ? store.warnings(for: source.id) : []
            if !warnings.isEmpty {
                DisclosureGroup(isExpanded: $isShowingWarnings) {
                    ForEach(warnings, id: \.self) { warning in
                        Text(warning)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } label: {
                    Text("\(warnings.count) warning\(warnings.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
            }
            }
        }
        .padding(.vertical, 5)
    }
}

/// A single explanatory line with an icon.
@MainActor
struct NoticeRow: View {

    let symbol: String
    let text: String
    var color: Color = .orange

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundColor(color)
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The add-repository form.
@MainActor
struct AddSourceSheet: View {

    @ObservedObject var store: AuroraStore

    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var name = ""
    @State private var errorMessage: String?
    @State private var isValidating = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://repo.example.com", text: $urlText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    TextField("Name (optional)", text: $name)
                } header: {
                    Text("Repository")
                } footer: {
                    Text("Paste a repository URL, bare host, direct Packages/Release link, or Sileo/Zebra add-source link. Aurora normalizes it automatically and detects distribution paths when present.")
                }

                if let errorMessage = errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Add Repository")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await add() }
                    } label: {
                        if isValidating { ProgressView() } else { Text("Add") }
                    }
                    .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || isValidating)
                }
            }
        }
    }

    private func add() async {
        isValidating = true
        defer { isValidating = false }
        let value = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let message = store.addSource(urlText: value, name: name) {
            errorMessage = message
            return
        }
        guard let id = store.sourceID(matchingURL: value) else {
            errorMessage = "Repository was added but could not be validated."
            return
        }
        if let validationError = await store.validateSource(id: id) {
            // Keep the source visible for diagnostics/manual retry, but disable it
            // immediately so a bad URL cannot poison Refresh All.
            store.setSourceEnabled(id: id, enabled: false)
            errorMessage = "Repository could not be validated and was disabled: \(validationError)"
            return
        }
        dismiss()
    }
}



@MainActor
struct EditSourceSheet: View {
    @ObservedObject var store: AuroraStore
    let source: RepositorySource
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var url: String
    @State private var suite: String
    @State private var components: String
    @State private var architectures: String
    @State private var errorMessage: String?

    init(store: AuroraStore, source: RepositorySource) {
        self.store = store
        self.source = source
        _name = State(initialValue: source.name)
        _url = State(initialValue: source.url)
        _suite = State(initialValue: source.suite)
        _components = State(initialValue: source.components.joined(separator: " "))
        _architectures = State(initialValue: source.architectures.joined(separator: " "))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Identity") {
                    TextField("Name", text: $name)
                    TextField("Repository URL", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
                Section {
                    TextField("Suite (./ for a flat repository)", text: $suite)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    TextField("Components (space separated)", text: $components)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    TextField("Architectures (optional)", text: $architectures)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                } header: {
                    Text("Package Index")
                } footer: {
                    Text("Use ./ and no components for a flat repository. Distribution repositories usually use a suite such as stable and a component such as main. Changing the URL alone selects defaults for the new host.")
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundColor(.red).font(.footnote) }
                }
            }
            .navigationTitle("Edit Repository")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        if let error = store.updateSource(
                            id: source.id,
                            name: name,
                            url: url,
                            suite: suite,
                            components: components.split(whereSeparator: \.isWhitespace).map(String.init),
                            architectures: architectures.split(whereSeparator: \.isWhitespace).map(String.init)
                        ) {
                            errorMessage = error
                        } else {
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

@MainActor
struct IOSRepoUpdatesBrowser: View {
    @ObservedObject var store: AuroraStore
    @Environment(\.dismiss) private var dismiss
    @State private var candidateURL = ""
    @State private var result: String?

    private let directoryURL = URL(string: "https://www.ios-repo-updates.com/repositories/popular/")!

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                RepoUpdatesWebView(url: directoryURL) { url in
                    candidateURL = url.absoluteString
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Add repository URL")
                        .font(.caption.weight(.semibold))
                    HStack {
                        TextField("https://repo.example.com", text: $candidateURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                        Button("Add") { addCandidate() }
                            .buttonStyle(.borderedProminent)
                            .disabled(candidateURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let result {
                        Text(result)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Text("Browse iOS Repo Updates, open a repository, then paste or select its APT repository URL here. Aurora validates and deduplicates it before adding.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(.secondarySystemBackground))
            }
            .navigationTitle("iOS Repo Updates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func addCandidate() {
        let value = candidateURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = store.addSource(urlText: value, suite: "./", name: "") {
            result = error
        } else {
            result = "Repository added. Refresh Sources to load its packages."
            candidateURL = ""
        }
    }
}

struct RepoUpdatesWebView: UIViewRepresentable {
    let url: URL
    let onRepositoryURL: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
        return view
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: RepoUpdatesWebView
        init(parent: RepoUpdatesWebView) { self.parent = parent }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               scheme != "http" && scheme != "https" {
                if let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                   let repository = components.queryItems?.first(where: {
                       ["url", "repo", "source"].contains($0.name.lowercased())
                   })?.value,
                   let repositoryURL = URL(string: repository) {
                    parent.onRepositoryURL(repositoryURL)
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }
    }
}

@MainActor
struct ImportSourcesSheet: View {
    @ObservedObject var store: AuroraStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var result: String?
    @State private var isOpeningFile = false
    @State private var preview: [RepositorySource] = []

    private func alreadyAdded(_ source: RepositorySource) -> Bool {
        store.sources.contains {
            $0.normalizedURL.caseInsensitiveCompare(source.normalizedURL) == .orderedSame && $0.suite == source.suite
        }
    }

    private var newCount: Int { preview.filter { !alreadyAdded($0) }.count }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { isOpeningFile = true } label: {
                        Label("Open Source File", systemImage: "folder")
                    }
                }
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 220)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                } header: {
                    Text("Sources")
                } footer: {
                    Text("Paste repository URLs, APT deb lines, or Sileo deb822 source blocks (Types, URIs, Suites, Components).")
                }
                if !preview.isEmpty {
                    Section {
                        ForEach(preview.prefix(20)) { source in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(source.normalizedURL).font(.subheadline)
                                Text(alreadyAdded(source) ? "Already added · will skip" : (source.isEnabled ? "Ready to add" : "Will add disabled"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if preview.count > 20 { Text("And \(preview.count - 20) more…").font(.caption) }
                    } header: {
                        Text("\(newCount) new · \(preview.count - newCount) already added")
                    }
                } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No valid repositories found in this text.").foregroundStyle(.orange)
                }
                if let result {
                    Section { Text(result).font(.footnote).foregroundColor(.secondary) }
                }
            }
            .navigationTitle("Import Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Import") {
                        let outcome = store.importSources(text)
                        result = "Added \(outcome.added); skipped \(outcome.skipped)."
                        if outcome.added > 0 { dismiss() }
                    }
                    .disabled(newCount == 0)
                }
            }
        }
        .onChange(of: text) { value in
            preview = SourceInterchange.parse(value)
            result = nil
        }
        .fileImporter(isPresented: $isOpeningFile, allowedContentTypes: [.data]) { outcome in
            do {
                text = try TextTransferDocument.readText(from: outcome.get())
            } catch {
                result = "Could not open source file: \(error.localizedDescription)"
            }
        }
    }
}
