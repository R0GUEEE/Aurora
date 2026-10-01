import Foundation
import AuroraCore

/// The six sections a staged change can fall into, in the order Sileo shows them.
///
/// Two of these are Aurora's presentation of `AuroraCore`'s five
/// `PackageAction`s:
///
/// * **Modify** is an `.upgrade` — the package is already installed and a newer
///   version is queued;
/// * **Downgrade / Reinstall** is a `.reinstall` whose record is *older* than the
///   installed version, which is the case where Sileo removes and reinstalls in
///   one go instead of merely swapping the version.
enum QueueSection: String, CaseIterable, Identifiable, Equatable {
    case install
    case modify
    case remove
    case reinstall
    case downgrade
    case downgradeReinstall

    var id: String { rawValue }

    var title: String {
        switch self {
        case .install: return "Install"
        case .modify: return "Modify"
        case .remove: return "Remove"
        case .reinstall: return "Reinstall"
        case .downgrade: return "Downgrade"
        case .downgradeReinstall: return "Downgrade / Reinstall"
        }
    }

    var symbolName: String {
        switch self {
        case .install: return "arrow.down.circle"
        case .modify: return "arrow.up.circle"
        case .remove: return "minus.circle"
        case .reinstall: return "arrow.clockwise.circle"
        case .downgrade: return "arrow.down.to.line"
        case .downgradeReinstall: return "arrow.triangle.2.circlepath"
        }
    }

    static func section(for action: PackageAction, installed: InstalledPackage?) -> QueueSection {
        switch action {
        case .install:
            return .install
        case .upgrade:
            return .modify
        case .remove:
            return .remove
        case .downgrade:
            return .downgrade
        case .reinstall(let record):
            if let installed = installed, DebianVersion.compare(record.version, installed.version) < 0 {
                return .downgradeReinstall
            }
            return .reinstall
        }
    }
}

/// A section of the queue screen with its staged actions.
struct QueueGroup: Identifiable {
    let section: QueueSection
    let actions: [PackageAction]
    var id: String { section.rawValue }
}

/// Everything the queue screen shows around the staged changes themselves.
struct QueueAnalysis {

    struct Entry: Identifiable, Equatable {
        let name: String
        let detail: String
        var id: String { name }
    }

    /// Packages the resolver will pull in that the user did not stage.
    var required: [Entry] = []
    /// Packages that will be removed (conflicts, or dependents of a removal).
    var conflicting: [Entry] = []
    /// Recommends that will not be satisfied.
    var suggested: [Entry] = []
    var warnings: [String] = []
    /// Resolution failures, when the queue cannot be planned at all.
    var errors: [String] = []
    var downloadSize: Int = 0
    var installedSize: Int64 = 0
    var summary: String = "No changes"

    var canConfirm: Bool { errors.isEmpty }

    static let empty = QueueAnalysis()
}

/// Turns a queue plus a resolver plan into the queue screen's model.
///
/// It is deliberately a pure function of (queue, installed, index, plan): the view
/// calls it on every render and nothing is cached that could go stale.
enum QueueAnalyzer {

    static func groups(queue: PackageQueue, installed: InstalledPackageDatabase) -> [QueueGroup] {
        var buckets: [QueueSection: [PackageAction]] = [:]
        for action in queue.actions {
            let section = QueueSection.section(for: action, installed: installed.package(named: action.name))
            buckets[section, default: []].append(action)
        }
        // `allCases` is the display order: additions, then changes, then removals.
        return QueueSection.allCases.compactMap { section in
            guard let actions = buckets[section], !actions.isEmpty else { return nil }
            return QueueGroup(section: section, actions: actions)
        }
    }

    static func analyse(
        queue: PackageQueue,
        installed: InstalledPackageDatabase,
        index: PackageIndex,
        architecture: String,
        attempt: Result<TransactionPlan, ResolutionFailure>
    ) -> QueueAnalysis {
        var analysis = QueueAnalysis()
        guard !queue.isEmpty else { return analysis }

        switch attempt {
        case .success(let plan):
            analysis.summary = plan.summary
            analysis.downloadSize = plan.downloadSize
            analysis.installedSize = plan.installedSize
            analysis.warnings = plan.warnings.map { $0.message }

            analysis.required = plan.dependencies
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                .map { record in
                    QueueAnalysis.Entry(
                        name: record.name,
                        detail: "\(record.version.raw) — pulled in as a dependency"
                    )
                }

            analysis.conflicting = plan.removed.map { removal in
                QueueAnalysis.Entry(
                    name: removal.package.name,
                    detail: removal.purge
                        ? "will be removed, configuration files included"
                        : "will be removed"
                )
            }

            analysis.suggested = suggestions(from: plan, queue: queue, installed: installed, index: index, architecture: architecture)

        case .failure(let failure):
            analysis.errors = failure.errors.map { $0.description }
            analysis.summary = "Cannot be planned"
        }

        return analysis
    }

    /// "Suggested" combines what the resolver found missing (`Recommends`) with
    /// the `Suggests` field of the staged packages, which no resolver acts on.
    private static func suggestions(
        from plan: TransactionPlan,
        queue: PackageQueue,
        installed: InstalledPackageDatabase,
        index: PackageIndex,
        architecture: String
    ) -> [QueueAnalysis.Entry] {
        var entries: [QueueAnalysis.Entry] = []
        var seen: Set<String> = []

        for warning in plan.warnings {
            guard case .recommendsNotInstalled(let package, let missing) = warning else { continue }
            for name in missing where seen.insert(name).inserted {
                entries.append(QueueAnalysis.Entry(name: name, detail: "recommended by \(package)"))
            }
        }

        // A staged package with no `index` hit for a suggestion is not offered:
        // suggesting something the user cannot install is noise.
        for action in queue.actions {
            guard let record = action.record else { continue }
            for term in record.relations.suggests.allTerms {
                guard seen.insert(term.name).inserted else { continue }
                guard !installed.isInstalled(term.name) else { continue }
                guard index.bestMatch(for: term, architecture: architecture) != nil else { continue }
                entries.append(QueueAnalysis.Entry(
                    name: term.name,
                    detail: "suggested by \(record.name)"
                ))
            }
        }

        return entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
