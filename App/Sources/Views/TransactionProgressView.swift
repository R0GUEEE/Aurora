import SwiftUI
import AuroraCore

/// A transaction in flight: what it is doing, what it has done, what it said, and
/// how it ended.
// `@MainActor` because `AuroraStore` is main-actor isolated: only `body` is
// isolated by default, so helper members that touch the store need it explicitly.
@MainActor
struct TransactionProgressView: View {

    @ObservedObject var runner: TransactionRunner
    @ObservedObject var store: AuroraStore
    /// Called when the user is done with the result, so the queue screen can act
    /// on it (clear the queue, reload what is installed).
    let onFinish: (TransactionReport?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var isShowingLog = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ProgressView(value: runner.progress)
                        .tint(runner.isFinished ? (runner.succeeded ? .green : .orange) : Color.accentColor)
                    Text(runner.status)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text(runner.isFinished ? "Finished" : "Running")
                } footer: {
                    if runner.isRunning {
                        Text("Aurora verifies every archive before dpkg is allowed to unpack it.")
                    }
                }

                if runner.steps.isEmpty {
                    Section {
                        Text("This transaction has no steps.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } header: {
                        Text("Steps")
                    }
                } else {
                    Section {
                        ForEach(runner.steps) { step in
                            TransactionStepRow(step: step)
                        }
                    } header: {
                        Text("Steps")
                    }
                }

                if let report = runner.report {
                    Section {
                        Label(
                            report.summary,
                            systemImage: report.succeeded ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                        )
                        .foregroundColor(report.succeeded ? .green : .orange)
                        DetailRow(label: "Duration", value: AuroraFormat.duration(report.duration))
                        if !report.installed.isEmpty {
                            DetailRow(label: "Installed", value: report.installed.joined(separator: ", "))
                        }
                        if !report.upgraded.isEmpty {
                            DetailRow(label: "Upgraded", value: report.upgraded.joined(separator: ", "))
                        }
                        if !report.downgraded.isEmpty {
                            DetailRow(label: "Downgraded", value: report.downgraded.joined(separator: ", "))
                        }
                        if !report.reinstalled.isEmpty {
                            DetailRow(label: "Reinstalled", value: report.reinstalled.joined(separator: ", "))
                        }
                        if !report.removed.isEmpty {
                            DetailRow(label: "Removed", value: report.removed.joined(separator: ", "))
                        }
                    } header: {
                        Text("Result")
                    } footer: {
                        if !report.failures.isEmpty {
                            Text(failureSummary(report))
                        }
                    }
                }

                if let failure = runner.failureMessage {
                    Section {
                        NoticeRow(symbol: "xmark.octagon.fill", text: failure, color: .red)
                    } header: {
                        Text("Failed")
                    } footer: {
                        Text("Nothing above was installed. Check the environment in Settings: Aurora needs a jailbreak with dpkg to install anything.")
                    }
                }

                if runner.isFinished && !runner.succeeded && store.canInstall {
                    Section("Recovery") {
                        Button {
                            Task { await store.repairPendingConfiguration() }
                        } label: {
                            Label("Finish Pending dpkg Configuration", systemImage: "wrench.and.screwdriver")
                        }
                        Text("Runs dpkg --configure -a to finish packages left unpacked by an interrupted or failed transaction.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section {
                    DisclosureGroup("dpkg output", isExpanded: $isShowingLog) {
                        logView
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if runner.isRunning {
                        Button("Cancel") { runner.cancel() }
                            .disabled(runner.isCancelling)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if runner.isFinished {
                        Button("Done") {
                            onFinish(runner.report)
                            dismiss()
                        }
                        .bold()
                    }
                }
            }
        }
        // A transaction is not something to swipe away by accident.
        .interactiveDismissDisabled(runner.isRunning)
    }

    private var logView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(runner.log.isEmpty ? "No output yet." : runner.log)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .id("log-top")
                Color.clear
                    .frame(height: 1)
                    .id("log-bottom")
            }
            .frame(maxHeight: 240)
            .onChange(of: runner.log.count) { _ in
                // iOS 16: the two-parameter `onChange(of:initial:)` is iOS 17
                // only, so the single-parameter form is the one to use here.
                withAnimation {
                    proxy.scrollTo("log-bottom", anchor: .bottom)
                }
            }
        }
    }

    private func failureSummary(_ report: TransactionReport) -> String {
        report.failures
            .map { "\($0.key): \($0.value)" }
            .sorted()
            .joined(separator: "\n")
    }
}

/// One step of the plan, with the state it is in.
@MainActor
struct TransactionStepRow: View {

    let step: TransactionStep

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.callout)
                if let detail = step.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
                switch step.state {
                case .failed(let message):
                    Text(message)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                case .skipped(let reason):
                    Text(reason)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                case .pending, .running, .done:
                    EmptyView()
                }
            }
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private var icon: some View {
        switch step.state {
        case .pending:
            Image(systemName: "circle")
                .foregroundColor(.secondary)
        case .running:
            ProgressView()
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill")
                .foregroundColor(.red)
        case .skipped:
            Image(systemName: "minus.circle")
                .foregroundColor(.secondary)
        }
    }
}
