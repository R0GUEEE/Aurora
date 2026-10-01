import SwiftUI
import AuroraCore

/// Everything one package has to say about itself, plus the actions you can take
/// on it.
// `@MainActor` because `AuroraStore` is main-actor isolated: only `body` is
// isolated by default, so helper members that touch the store need it explicitly.
@MainActor
struct PackageDetailView: View {

    @ObservedObject var store: AuroraStore
    let record: PackageRecord

    @State private var isChoosingVersion = false
    @State private var depictionTarget: DepictionTarget?
    @State private var showingRawMetadata = false

    var body: some View {
        List {
            headerSection
            actionSection
            informationSection
            dependencySection
            descriptionSection
            depictionSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(record.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                ShareLink(item: packageShareText) {
                    Image(systemName: "square.and.arrow.up")
                }
                Menu {
                    Button {
                        UIPasteboard.general.string = record.name
                    } label: {
                        Label("Copy Package ID", systemImage: "doc.on.doc")
                    }
                    Button {
                        UIPasteboard.general.string = record.version.raw
                    } label: {
                        Label("Copy Version", systemImage: "number")
                    }
                    Button {
                        showingRawMetadata = true
                    } label: {
                        Label("Raw Metadata", systemImage: "doc.plaintext")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                Button { store.toggleBookmark(record.name) } label: {
                    Image(systemName: store.isBookmarked(record.name) ? "bookmark.fill" : "bookmark")
                }
                .accessibilityLabel(store.isBookmarked(record.name) ? "Remove bookmark" : "Bookmark package")
            }
        }
        .sheet(isPresented: $isChoosingVersion) {
            VersionChooserSheet(
                store: store,
                versions: store.allRecords(named: record.name),
                installedVersion: store.installedPackage(named: record.name)?.version,
                onPick: { candidate in store.stage(store.defaultAction(for: candidate)) }
            )
        }
        .sheet(item: $depictionTarget) { target in
            DepictionScreen(title: target.title, url: target.url)
        }
        .sheet(isPresented: $showingRawMetadata) {
            NavigationStack {
                ScrollView {
                    Text(rawMetadata)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("Package Metadata")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }

    private var resolvedIconURL: String? {
        guard let icon = record.icon?.trimmingCharacters(in: .whitespacesAndNewlines), !icon.isEmpty else { return nil }
        if URL(string: icon)?.scheme != nil { return icon }
        guard let base = record.origin?.url,
              let url = URL(string: icon, relativeTo: URL(string: base + "/")) else { return nil }
        return url.absoluteURL.absoluteString
    }

    private var packageShareText: String {
        "\(record.displayName) (\(record.name)) \(record.version.raw)"
    }

    private var rawMetadata: String {
        let origin = record.origin.map { "Repository: \($0.description)\n\n" } ?? ""
        return origin + record.stanza.serialized
    }

    // MARK: - Header

    private var headerSection: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                PackageIcon(urlString: resolvedIconURL, size: 72, fallbackText: record.displayName)
                VStack(alignment: .leading, spacing: 5) {
                    Text(record.displayName)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(record.name)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        Text(record.version.raw)
                            .font(.caption)
                            .foregroundColor(.secondary)
                        StateBadge(state: store.state(for: record))
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Actions

    private var actionSection: some View {
        Section {
            if let staged = store.stagedAction(for: record.name) {
                HStack {
                    Label("Staged: \(staged.kind.label)", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Spacer()
                    Button("Unstage") { store.unstage(record.name) }
                        .buttonStyle(.borderless)
                }
            } else {
                Button {
                    store.stage(store.defaultAction(for: record))
                } label: {
                    Label(primaryActionTitle, systemImage: primaryActionSymbol)
                }

                if store.isInstalled(record.name) {
                    Button {
                        store.stage(.reinstall(record))
                    } label: {
                        Label("Reinstall", systemImage: "arrow.clockwise")
                    }

                    Menu {
                        Button("Remove") {
                            store.stage(.remove(name: record.name, purge: false))
                        }
                        Button("Remove with configuration files", role: .destructive) {
                            store.stage(.remove(name: record.name, purge: true))
                        }
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                }

                // The version chooser is how a downgrade is requested: the list
                // marks the installed version and each row shows the action it
                // would stage.
                Button {
                    isChoosingVersion = true
                } label: {
                    Label("Choose a version…", systemImage: "list.bullet.below.rectangle")
                }
                .disabled(store.allRecords(named: record.name).count < 2)

                Toggle("Hold package", isOn: Binding(
                    get: { store.isHeld(record.name) },
                    set: { store.setHeld(record.name, held: $0) }
                ))

                Menu {
                    Button("Pin to \(record.version.raw)") { store.pinVersion(record) }
                    Button("Clear hold / version pin") { store.clearPin(record.name) }
                    Divider()
                    Button(store.isHidden(record.name) ? "Show in package lists" : "Hide from package lists") {
                        store.toggleHidden(record.name)
                    }
                } label: {
                    Label("Package preferences", systemImage: "slider.horizontal.3")
                }
            }
        } header: {
            Text("Actions")
        } footer: {
            if store.stagedAction(for: record.name) == nil {
                Text("Nothing is installed until you confirm the queue, which is in the Queue tab.")
            } else {
                Text("Review the staged changes in the Queue tab before confirming.")
            }
        }
    }

    private var primaryActionTitle: String {
        guard let installed = store.installedPackage(named: record.name) else {
            return "Install"
        }
        let order = DebianVersion.compare(record.version, installed.version)
        if order > 0 { return "Update to \(record.version.raw)" }
        if order < 0 { return "Downgrade to \(record.version.raw)" }
        return "Reinstall \(record.version.raw)"
    }

    private var primaryActionSymbol: String {
        guard let installed = store.installedPackage(named: record.name) else {
            return "arrow.down.circle"
        }
        let order = DebianVersion.compare(record.version, installed.version)
        if order > 0 { return "arrow.up.circle" }
        if order < 0 { return "arrow.down.to.line" }
        return "arrow.clockwise"
    }

    // MARK: - Metadata

    private var informationSection: some View {
        Section {
            DetailRow(label: "Author", value: authorText)
            DetailRow(label: "Section", value: record.section.isEmpty ? "Uncategorised" : record.section)
            DetailRow(label: "Architecture", value: record.architecture)
            DetailRow(label: "Download size", value: AuroraFormat.bytes(record.downloadSize))
            DetailRow(label: "Installed size", value: AuroraFormat.kibibytes(record.installedSize))
            if let origin = record.origin {
                DetailRow(label: "Repository", value: origin.description)
            }
            if let installed = store.installedPackage(named: record.name) {
                DetailRow(label: "Installed", value: installed.version.raw)
            }
            if let homepage = record.homepage, let url = URL(string: homepage) {
                Link(destination: url) {
                    HStack {
                        Text("Homepage")
                        Spacer()
                        Text(url.host ?? homepage)
                            .foregroundColor(.secondary)
                        Image(systemName: "arrow.up.right.square")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            let compatibility = PackageCompatibility.evaluate(record, environment: store.environment)
            HStack {
                Text("Compatibility")
                Spacer()
                Label(
                    compatibility.level.rawValue.capitalized,
                    systemImage: compatibility.level == .compatible ? "checkmark.circle.fill" :
                        (compatibility.level == .warning ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                )
                .font(.caption)
                .foregroundColor(compatibility.level == .compatible ? .green :
                    (compatibility.level == .warning ? .orange : .red))
            }
            ForEach(compatibility.reasons, id: \.self) { reason in
                Text(reason).font(.caption).foregroundColor(.secondary)
            }
            if let changelog = record.changelogURL, let url = URL(string: changelog) {
                Link("Changelog", destination: url)
            }
            if let support = record.supportURL, let url = URL(string: support) {
                Link("Support", destination: url)
            }
            if !record.tags.isEmpty {
                DetailRow(label: "Tags", value: record.tags.joined(separator: ", "))
            }
        } header: {
            Text("Information")
        }
    }

    private var authorText: String {
        if let author = record.author, !author.isEmpty { return author }
        if !record.maintainer.isEmpty { return record.maintainer }
        return "Unknown"
    }

    // MARK: - Dependencies

    private var dependencySection: some View {
        Section {
            if dependencies.isEmpty {
                Text("No declared dependencies.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                ForEach(dependencies, id: \.self) { term in
                    HStack {
                        Text(term.description)
                            .font(.callout)
                        Spacer()
                        Text(store.isInstalled(term.name) ? "installed" : "missing")
                            .font(.caption)
                            .foregroundColor(store.isInstalled(term.name) ? .secondary : .orange)
                    }
                }
            }
            if !record.relations.conflicts.allTerms.isEmpty {
                ForEach(record.relations.conflicts.allTerms, id: \.self) { term in
                    HStack {
                        Text(term.description)
                            .font(.callout)
                        Spacer()
                        Text("conflicts")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }
        } header: {
            Text("Dependencies")
        } footer: {
            Text("Aurora resolves these itself; anything missing is added to the queue automatically.")
        }
    }

    private var dependencies: [DependencyTerm] {
        record.relations.preDepends.allTerms + record.relations.depends.allTerms
    }

    // MARK: - Description

    @ViewBuilder
    private var descriptionSection: some View {
        Section {
            if record.synopsis.isEmpty && record.extendedDescription == nil {
                Text("This package has no description.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                if !record.synopsis.isEmpty {
                    Text(record.synopsis)
                        .font(.callout.weight(.medium))
                }
                if let extended = record.extendedDescription, !extended.isEmpty {
                    Text(extended)
                        .font(.footnote)
                }
            }
        } header: {
            Text("Description")
        }
    }

    // MARK: - Depiction

    @ViewBuilder
    private var depictionSection: some View {
        switch store.settings.depictionPreference {
        case .fallback:
            fallbackDepiction
        case .native:
            if let url = nativeDepictionURL ?? classicDepictionURL {
                depictionLink(url)
            } else {
                fallbackDepiction
            }
        case .classic:
            if let url = classicDepictionURL ?? nativeDepictionURL {
                depictionLink(url)
            } else {
                fallbackDepiction
            }
        }
    }

    private var nativeDepictionURL: URL? {
        guard let value = record.nativeDepiction else { return nil }
        return URL(string: value)
    }

    private var classicDepictionURL: URL? {
        guard let value = record.depiction else { return nil }
        return URL(string: value)
    }

    private func depictionLink(_ url: URL) -> some View {
        Section {
            Button {
                depictionTarget = DepictionTarget(title: record.displayName, url: url)
            } label: {
                HStack {
                    Label("Open depiction", systemImage: "safari")
                    Spacer()
                    Text(url.host ?? "")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Text(url.absoluteString)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(2)
        } header: {
            Text("Depiction")
        } footer: {
            Text("Opens in an in-app web view, so you never leave Aurora.")
        }
    }

    /// What Aurora shows when there is no depiction to load, or when the user has
    /// asked for depictions to be rendered natively.
    private var fallbackDepiction: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(record.displayName)
                    .font(.headline)
                Text(authorText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if !record.synopsis.isEmpty {
                    Text(record.synopsis)
                        .font(.callout)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Depiction")
        } footer: {
            Text("This repository publishes no depiction Aurora can load, so the package metadata is shown instead.")
        }
    }
}

/// A label/value row that does not depend on `LabeledContent` (iOS 16 only) and
/// wraps long values properly.
@MainActor
struct DetailRow: View {

    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top) {
            Text(label)
            Spacer(minLength: 12)
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

/// The sheet a depiction is presented in.
struct DepictionTarget: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
}

/// Lists every version of a package, showing what picking each one would do.
@MainActor
struct VersionChooserSheet: View {

    @ObservedObject var store: AuroraStore
    /// Newest first, as `PackageIndex.candidates(named:)` returns them.
    let versions: [PackageRecord]
    let installedVersion: DebianVersion?
    let onPick: (PackageRecord) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if versions.isEmpty {
                    EmptyMessage(
                        symbol: "questionmark.folder",
                        title: "No versions",
                        message: "No repository in the store publishes this package."
                    )
                }
                ForEach(versions) { candidate in
                    Button {
                        onPick(candidate)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.version.raw)
                                Text(store.defaultAction(for: candidate).kind.label)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if isInstalled(candidate) {
                                Text("installed")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Choose a version")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func isInstalled(_ candidate: PackageRecord) -> Bool {
        guard let installedVersion = installedVersion else { return false }
        return DebianVersion.compare(candidate.version, installedVersion) == 0
    }
}
