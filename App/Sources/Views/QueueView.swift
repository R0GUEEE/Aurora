import SwiftUI
import AuroraCore

/// The staged changes, the parts of the plan the user did not ask for, and the
/// button that turns all of it into one transaction.
// `@MainActor` because `AuroraStore` is main-actor isolated: only `body` is
// isolated by default, so helper members that touch the store need it explicitly.
@MainActor
struct QueueView: View {

    @ObservedObject var store: AuroraStore

    @State private var runner: TransactionRunner?
    @State private var pendingPlan: TransactionPlan?

    var body: some View {
        List {
            if store.queue.isEmpty {
                Section {
                    EmptyMessage(
                        symbol: "tray",
                        title: "Nothing staged",
                        message: "Install, upgrade, downgrade, reinstall or remove packages; they queue up here until you confirm, and nothing touches the system before that."
                    )
                }
            } else {
                ForEach(QueueAnalyzer.groups(queue: store.queue, installed: store.installed)) { group in
                    Section {
                        ForEach(group.actions, id: \.self) { action in
                            actionRow(action)
                        }
                    } header: {
                        Label(
                            "\(group.section.title) (\(group.actions.count))",
                            systemImage: group.section.symbolName
                        )
                    }
                }

                let analysis = store.queueAnalysis

                if !analysis.errors.isEmpty {
                    Section {
                        ForEach(analysis.errors, id: \.self) { message in
                            NoticeRow(symbol: "xmark.octagon.fill", text: message, color: .red)
                        }
                    } header: {
                        Text("Cannot be planned")
                    }
                }

                if !analysis.required.isEmpty {
                    Section {
                        ForEach(analysis.required) { entry in
                            entryRow(entry, color: .blue)
                        }
                    } header: {
                        Text("Required")
                    } footer: {
                        Text("Added automatically because something above depends on it.")
                    }
                }

                if !analysis.conflicting.isEmpty {
                    Section {
                        ForEach(analysis.conflicting) { entry in
                            entryRow(entry, color: .red)
                        }
                    } header: {
                        Text("Conflicting")
                    } footer: {
                        Text("These conflict with the staged changes, or depend on a package being removed.")
                    }
                }

                if !analysis.suggested.isEmpty {
                    Section {
                        ForEach(analysis.suggested) { entry in
                            entryRow(entry, color: .orange)
                        }
                    } header: {
                        Text("Suggested")
                    } footer: {
                        Text("Recommended by the packages you staged. They are not installed unless you stage them yourself.")
                    }
                }

                if !analysis.warnings.isEmpty {
                    Section {
                        ForEach(analysis.warnings, id: \.self) { warning in
                            NoticeRow(symbol: "exclamationmark.triangle.fill", text: warning, color: .orange)
                        }
                    } header: {
                        Text("Warnings")
                    }
                }

                Section {
                    DetailRow(label: "Summary", value: analysis.summary)
                    DetailRow(label: "Download", value: AuroraFormat.bytes(analysis.downloadSize))
                    DetailRow(label: "On disk after", value: AuroraFormat.bytes(Int(analysis.installedSize)))
                } header: {
                    Text("Cost")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Queue")
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !store.queue.isEmpty {
                confirmBar
            }
        }
        .confirmationDialog(
            "Install queued changes?",
            isPresented: Binding(
                get: { pendingPlan != nil },
                set: { if !$0 { pendingPlan = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Install") {
                if let plan = pendingPlan {
                    pendingPlan = nil
                    start(plan)
                }
            }
            Button("Cancel", role: .cancel) { pendingPlan = nil }
        } message: {
            Text(pendingPlan?.summary ?? "")
        }
        .sheet(item: $runner) { active in
            TransactionProgressView(runner: active, store: store) { report in
                runner = nil
                if report?.succeeded == true {
                    store.recordCompletedTransaction(active.plan)
                    store.clearQueue()
                }
                Task {
                    await store.reloadInstalled()
                    if report?.succeeded == true {
                        if store.settings.autoCleanDownloadedPackages {
                            _ = store.pruneDownloadedPackages()
                        }
                        _ = store.pruneUnusedLocalPackages()
                        if store.settings.refreshAfterTransaction {
                            await store.refreshAll(forceReload: false)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Rows

    private func actionRow(_ action: PackageAction) -> some View {
        HStack(alignment: .top, spacing: 10) {
            PackageIcon(urlString: action.record?.icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(for: action))
                Text(subtitle(for: action))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer(minLength: 6)
            Button {
                store.unstage(action.name)
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundColor(.red)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(action.name) from the queue")
        }
    }

    private func entryRow(_ entry: QueueAnalysis.Entry, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "shippingbox")
                .font(.caption)
                .foregroundColor(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                Text(entry.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func displayName(for action: PackageAction) -> String {
        if let record = action.record { return record.displayName }
        if let installed = store.installedPackage(named: action.name) { return installed.name }
        return action.name
    }

    private func subtitle(for action: PackageAction) -> String {
        let installed = store.installedPackage(named: action.name)?.version.raw
        switch action {
        case .install(let record):
            return "\(record.version.raw) · new install"
        case .upgrade(let record):
            return "\(installed ?? "?") → \(record.version.raw)"
        case .downgrade(let record):
            return "\(installed ?? "?") → \(record.version.raw) · downgrade"
        case .reinstall(let record):
            return "\(record.version.raw) · reinstall"
        case .remove(_, let purge):
            if let installed = installed {
                return purge ? "\(installed) · removes configuration too" : installed
            }
            return purge ? "remove everything" : "remove"
        }
    }

    // MARK: - Confirmation

    private var confirmBar: some View {
        VStack(spacing: 8) {
            if !store.queueAnalysis.canConfirm {
                Text("This queue cannot be planned yet. Nothing will be installed.")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            HStack {
                Button("Clear", role: .destructive) {
                    store.clearQueue()
                }
                Spacer()
                Button {
                    confirm()
                } label: {
                    Text(store.settings.confirmQueueBeforeInstall ? "Confirm" : "Install").bold()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!store.queueAnalysis.canConfirm)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func confirm() {
        switch store.attemptPlan() {
        case .failure(let failure):
            store.lastError = failure.errors.map { $0.description }.joined(separator: "\n")
        case .success(let plan):
            guard !plan.isEmpty else {
                store.lastError = "There is nothing to do: every staged package is already in that state."
                return
            }
            if store.settings.confirmQueueBeforeInstall {
                pendingPlan = plan
            } else {
                start(plan)
            }
        }
    }

    private func start(_ plan: TransactionPlan) {
        let active = TransactionRunner(
            plan: plan,
            sources: store.sources,
            environment: store.environment
        )
        runner = active
        active.start()
    }
}
