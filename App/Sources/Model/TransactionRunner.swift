import Combine
import Foundation
import AuroraCore

/// One line of the transaction screen.
///
/// Built from the plan before anything runs, so the user sees the whole shape of
/// the transaction up front and each line fills in as it happens.
struct TransactionStep: Identifiable, Equatable {

    enum Kind: Equatable {
        case remove
        case unpack
        case configure
    }

    enum State: Equatable {
        case pending
        case running
        case done
        case failed(String)
        case skipped(String)
    }

    let id: String
    let kind: Kind
    let packageName: String
    let title: String
    let detail: String?
    var state: State

    var isFinished: Bool {
        switch state {
        case .done, .failed, .skipped: return true
        case .pending, .running: return false
        }
    }
}

/// Drives one transaction and turns `InstallEngine`'s events into view state.
///
/// The engine does the work (download, verify, dpkg); this class only translates
/// `TransactionEvent`s into a step list, a log and a result. It is `@MainActor`
/// so the events can be applied directly to published properties.
// `@MainActor` because `AuroraStore` is main-actor isolated: only `body` is
// isolated by default, so helper members that touch the store need it explicitly.
@MainActor
final class TransactionRunner: ObservableObject, Identifiable {

    let id = UUID()
    let plan: TransactionPlan

    @Published private(set) var steps: [TransactionStep] = []
    @Published private(set) var status = "Starting…"
    @Published private(set) var log = ""
    @Published private(set) var report: TransactionReport?
    @Published private(set) var failureMessage: String?
    @Published private(set) var isRunning = true
    @Published private(set) var isCancelling = false

    private let sources: [RepositorySource]
    private let environment: JailbreakEnvironment
    private var downloadFraction: Double = 0
    private var task: Task<Void, Never>?

    /// Log lines are capped: a transaction that installs a hundred packages can
    /// produce megabytes of dpkg output, and this is a phone.
    private static let maximumLogLength = 200_000

    init(plan: TransactionPlan, sources: [RepositorySource], environment: JailbreakEnvironment) {
        self.plan = plan
        self.sources = sources
        self.environment = environment
        self.steps = TransactionRunner.makeSteps(for: plan)
    }

    // MARK: - Progress

    /// 0…1, from finished steps plus the download of the current one.
    var progress: Double {
        guard !steps.isEmpty else { return isRunning ? 0 : 1 }
        let total = Double(steps.count)
        let finished = Double(steps.filter { $0.isFinished }.count)
        return min(1, max(0, (finished + downloadFraction) / total))
    }

    var isFinished: Bool { report != nil || failureMessage != nil }

    var succeeded: Bool { report?.succeeded ?? false }

    // MARK: - Running

    func start() {
        guard task == nil else { return }
        isRunning = true
        isCancelling = false
        status = "Preparing…"

        let engine = InstallEngine(environment: environment)
        let plan = self.plan
        let sources = self.sources

        // The engine calls this from a background thread, so every event is
        // hopped back to the main actor before it touches published state.
        let handler: @Sendable (TransactionEvent) -> Void = { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }

        task = Task { @MainActor [weak self] in
            guard let self = self else { return }
            do {
                var localPaths: [String: String] = [:]
                for record in plan.unpackSteps where LocalPackageLoader.isLocalRecord(record) {
                    if let path = record.filename {
                        localPaths[InstallEngine.archiveKey(for: record)] = path
                    }
                }
                let report = try await engine.execute(
                    plan,
                    sources: sources,
                    localPaths: localPaths,
                    progress: handler
                )
                self.finish(with: report)
            } catch {
                self.fail(AuroraFormat.message(for: error))
            }
        }
    }

    /// Asks the transaction to stop.
    ///
    /// Cancellation is *not* instantaneous and the UI says so: `dpkg` cannot be
    /// interrupted safely halfway through an unpack, so the current step runs to
    /// completion and the transaction stops after it.
    func cancel() {
        guard isRunning, !isCancelling else { return }
        isCancelling = true
        status = "Cancelling…"
        append(log: "warning: cancellation requested; Aurora stops after the current step finishes.")
        task?.cancel()
    }

    // MARK: - Event handling

    private func handle(_ event: TransactionEvent) {
        switch event {
        case .stage(let text):
            status = text

        case .downloading(let package, let received, let total):
            downloadFraction = total > 0 ? min(1, Double(received) / Double(total)) : 0
            status = "Downloading \(package) (\(AuroraFormat.bytes(Int(received))) of \(AuroraFormat.bytes(Int(total))))"
            begin(kind: .unpack, package: package)

        case .verifying(let package):
            status = "Verifying \(package)"

        case .removing(let package):
            status = "Removing \(package)"
            begin(kind: .remove, package: package)

        case .unpacking(let package):
            status = "Unpacking \(package)"
            begin(kind: .unpack, package: package)

        case .configuring(let package):
            status = "Configuring \(package)"
            begin(kind: .configure, package: package)

        case .dpkgProgress(let package, let phase, _):
            if let package {
                status = "\(phase.capitalized) \(package)"
            } else {
                status = phase
            }

        case .output(let text):
            append(log: text)

        case .finished(let report):
            finish(with: report)

        case .failed(let package, let message):
            markFailed(package: package, message: message)
        }
    }

    /// Moves the "running" marker: the engine only emits an event when a phase
    /// *starts*, so the previous running step is closed as this one opens.
    private func begin(kind: TransactionStep.Kind, package: String) {
        downloadFraction = 0
        if let running = steps.firstIndex(where: { $0.state == .running }) {
            steps[running].state = .done
        }
        if let next = steps.firstIndex(where: {
            $0.state == .pending && $0.kind == kind && $0.packageName == package
        }) {
            steps[next].state = .running
        }
    }

    private func markFailed(package: String?, message: String) {
        if let running = steps.firstIndex(where: { $0.state == .running }) {
            steps[running].state = .failed(message)
        } else if let package = package,
                  let match = steps.firstIndex(where: { $0.packageName == package && $0.state == .pending }) {
            steps[match].state = .failed(message)
        }
        append(log: "error: \(message)")
        status = message
    }

    private func finish(with report: TransactionReport) {
        self.report = report
        log = report.log
        isRunning = false
        isCancelling = false
        downloadFraction = 0
        status = report.summary

        for index in steps.indices {
            switch steps[index].state {
            case .pending:
                steps[index].state = .skipped(report.succeeded ? "already satisfied" : "not reached")
            case .running:
                steps[index].state = report.succeeded ? .done : .failed("did not complete")
            case .done, .failed, .skipped:
                break
            }
        }
    }

    private func fail(_ message: String) {
        failureMessage = message
        isRunning = false
        isCancelling = false
        status = message
        append(log: "error: \(message)")
        for index in steps.indices where steps[index].state == .pending || steps[index].state == .running {
            steps[index].state = .skipped("transaction did not run")
        }
    }

    private func append(log text: String) {
        let trimmed = text.hasSuffix("\n") ? String(text.dropLast()) : text
        guard !trimmed.isEmpty else { return }
        log += log.isEmpty ? trimmed : "\n" + trimmed
        if log.count > TransactionRunner.maximumLogLength {
            log = String(log.suffix(TransactionRunner.maximumLogLength / 2))
        }
    }

    // MARK: - Plan to steps

    static func makeSteps(for plan: TransactionPlan) -> [TransactionStep] {
        plan.steps.enumerated().map { index, step in
            switch step {
            case .remove(let package, let purge):
                return TransactionStep(
                    id: "\(index)-remove-\(package.name)",
                    kind: .remove,
                    packageName: package.name,
                    title: "Remove \(package.name) \(package.version.raw)",
                    detail: purge ? "including configuration files" : nil,
                    state: .pending
                )
            case .unpack(let record):
                return TransactionStep(
                    id: "\(index)-unpack-\(record.name)",
                    kind: .unpack,
                    packageName: record.name,
                    title: "\(verb(for: record, in: plan)) \(record.name) \(record.version.raw)",
                    detail: record.synopsis.isEmpty ? nil : record.synopsis,
                    state: .pending
                )
            case .configure(let name):
                return TransactionStep(
                    id: "\(index)-configure-\(name)",
                    kind: .configure,
                    packageName: name,
                    title: "Configure \(name)",
                    detail: nil,
                    state: .pending
                )
            }
        }
    }

    private static func verb(for record: PackageRecord, in plan: TransactionPlan) -> String {
        if plan.upgraded.contains(where: { $0.name == record.name }) { return "Upgrade" }
        if plan.downgraded.contains(where: { $0.name == record.name }) { return "Downgrade" }
        if plan.reinstalled.contains(where: { $0.name == record.name }) { return "Reinstall" }
        return "Install"
    }
}
