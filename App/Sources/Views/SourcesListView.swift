import SwiftUI
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
                } else {
                    // Swipe left to delete, swipe right to refresh one repository.
                    ForEach(store.sources) { source in
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
                    }
                    .onDelete { offsets in
                        // Capture the ids first: removing a source shifts the
                        // indices of the ones after it.
                        let ids = offsets.compactMap { offset in
                            offset < store.sources.count ? store.sources[offset].id : nil
                        }
                        for id in ids {
                            store.removeSource(id: id)
                        }
                    }
                }
            } header: {
                Text("Repositories")
            } footer: {
                Text("\(store.totalPackageCount) packages in the merged index.")
            }

            Section("Transfer") {
                ShareLink(item: store.exportedSources, subject: Text("Aurora Sources")) {
                    Label("Export Sources", systemImage: "square.and.arrow.up")
                }
                Button {
                    isImportingSources = true
                } label: {
                    Label("Import Sources", systemImage: "square.and.arrow.down")
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
            ToolbarItem(placement: .navigationBarTrailing) {
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
struct RepositoryDetailView: View {
    @ObservedObject var store: AuroraStore
    let sourceID: UUID
    @State private var query = ""

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
                    LabeledContent("URL", value: source.normalizedURL)
                    LabeledContent("Layout", value: source.isFlat ? "Flat" : "Dists")
                    LabeledContent("Suite", value: source.suite)
                    LabeledContent("Packages", value: "\(store.packageCount(for: sourceID))")
                    LabeledContent("Updated", value: AuroraFormat.relative(source.lastRefreshed))
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
                                PackageRow(record: record, state: store.state(for: record))
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
            ToolbarItem(placement: .navigationBarTrailing) {
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
                Text(source.isFlat ? "flat · \(source.suite)" : "dists · \(source.suite)")
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

            let warnings = store.warnings(for: source.id)
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
        .padding(.vertical, 2)
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
    @State private var isFlat = true
    @State private var suite = "stable"
    @State private var errorMessage: String?

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
                    Text("Apt sources-style URLs are accepted too; the scheme and host are what matter.")
                }

                Section {
                    Toggle("Flat repository", isOn: $isFlat)
                    if !isFlat {
                        TextField("Suite (stable, bookworm…)", text: $suite)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                    }
                } header: {
                    Text("Layout")
                } footer: {
                    Text(isFlat
                         ? "Flat repositories publish Packages at their root and use the suite “./”. Most jailbreak repositories are flat."
                         : "A dists repository publishes Release and Packages under dists/<suite>/<component>/binary-<arch>/.")
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
                    Button("Add") { add() }
                        .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func add() {
        let message = store.addSource(
            urlText: urlText,
            suite: isFlat ? "./" : suite,
            name: name
        )
        if let message = message {
            errorMessage = message
            return
        }
        dismiss()
    }
}


@MainActor
struct ImportSourcesSheet: View {
    @ObservedObject var store: AuroraStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 220)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                } header: {
                    Text("Sources")
                } footer: {
                    Text("Paste repository URLs or APT lines such as: deb https://repo.example stable main")
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
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
