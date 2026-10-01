import Foundation

/// What the user asked for, one entry per package.
///
/// This is the queue Sileo shows at the bottom of the screen: a list of
/// intentions, not yet a plan. Turning intentions into a safe plan is the
/// resolver's job.
public enum PackageAction: Hashable, Sendable {
    case install(PackageRecord)
    case reinstall(PackageRecord)
    case upgrade(PackageRecord)
    case downgrade(PackageRecord)
    case remove(name: String, purge: Bool)

    public var name: String {
        switch self {
        case .install(let record), .reinstall(let record), .upgrade(let record), .downgrade(let record):
            return record.name
        case .remove(let name, _):
            return name
        }
    }

    /// What the queue de-duplicates on. A name for a removal, an *instance* for
    /// anything else, so `foo:iphoneos-arm64` and `foo:iphoneos-arm` can both be
    /// queued — which is exactly what `Multi-Arch: same` packages need.
    public var key: String {
        record?.instanceKey ?? name
    }

    public var record: PackageRecord? {
        switch self {
        case .install(let record), .reinstall(let record), .upgrade(let record), .downgrade(let record):
            return record
        case .remove:
            return nil
        }
    }

    public var kind: Kind {
        switch self {
        case .install: return .install
        case .reinstall: return .reinstall
        case .upgrade: return .upgrade
        case .downgrade: return .downgrade
        case .remove(_, let purge): return purge ? .purge : .remove
        }
    }

    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case install
        case reinstall
        case upgrade
        case downgrade
        case remove
        case purge

        public var label: String {
            switch self {
            case .install: return "Install"
            case .reinstall: return "Reinstall"
            case .upgrade: return "Upgrade"
            case .downgrade: return "Downgrade"
            case .remove: return "Remove"
            case .purge: return "Remove with configuration files"
            }
        }
    }

    /// The action that undoes this one, for the "reset" button in the queue.
    ///
    /// The kind is the *opposite* of what is staged: undoing a staged downgrade
    /// means upgrading back to what is installed, and undoing an upgrade means
    /// staging the downgrade back to it. Getting this backwards makes the reset
    /// button emit a transaction the resolver refuses.
    public func inverted(installed: InstalledPackage?) -> PackageAction? {
        switch self {
        case .remove(let name, _):
            _ = name
            guard let installed else { return nil }
            return .reinstall(installed.record)
        case .install(let record), .reinstall(let record), .downgrade(let record), .upgrade(let record):
            guard let installed else { return nil }
            switch DebianVersion.compare(installed.version, record.version) {
            case 0:
                return .reinstall(installed.record)
            case 1:
                // The staged action goes backwards, so undoing it goes forwards.
                return .upgrade(installed.record)
            default:
                return .downgrade(installed.record)
            }
        }
    }
}

/// The staged changes.
public struct PackageQueue: Hashable, Sendable {

    public private(set) var actions: [PackageAction]

    public init(actions: [PackageAction] = []) {
        self.actions = actions
    }

    public var isEmpty: Bool { actions.isEmpty }
    public var count: Int { actions.count }

    /// One action per instance: staging a second action for the same package and
    /// architecture replaces the first, which is what a queue UI expects.
    public mutating func stage(_ action: PackageAction) {
        actions.removeAll { $0.key == action.key }
        actions.append(action)
    }

    public mutating func unstage(name: String) {
        actions.removeAll { $0.name == name }
    }

    public mutating func unstage(key: String) {
        actions.removeAll { $0.key == key }
    }

    public mutating func removeAll() {
        actions.removeAll()
    }

    public func action(for name: String) -> PackageAction? {
        actions.first { $0.name == name }
    }

    public func isStaged(_ name: String) -> Bool {
        action(for: name) != nil
    }

    /// Counts per action kind, for the confirmation sheet.
    public var summary: [(kind: PackageAction.Kind, count: Int)] {
        var counts: [PackageAction.Kind: Int] = [:]
        for action in actions { counts[action.kind, default: 0] += 1 }
        return PackageAction.Kind.allCases.compactMap { kind in
            guard let count = counts[kind], count > 0 else { return nil }
            return (kind, count)
        }
    }
}

/// A plan the resolver produced from a queue: an ordered, verified list of steps.
public struct TransactionPlan: Sendable {

    public enum Step: Sendable, Hashable {
        case remove(InstalledPackage, purge: Bool)
        case unpack(PackageRecord)
        case configure(String)
    }

    public let steps: [Step]
    public let installed: [PackageRecord]
    public let upgraded: [PackageRecord]
    public let downgraded: [PackageRecord]
    public let reinstalled: [PackageRecord]
    public let removed: [(package: InstalledPackage, purge: Bool)]
    /// Packages pulled in because something else needed them. The UI shows these
    /// separately: they are the answer to "why is this happening?".
    public let dependencies: [PackageRecord]
    public let warnings: [PlanWarning]
    public let downloadSize: Int
    public let installedSize: Int64

    public init(
        steps: [Step],
        installed: [PackageRecord],
        upgraded: [PackageRecord],
        downgraded: [PackageRecord],
        reinstalled: [PackageRecord],
        removed: [(package: InstalledPackage, purge: Bool)],
        dependencies: [PackageRecord],
        warnings: [PlanWarning],
        downloadSize: Int,
        installedSize: Int64
    ) {
        self.steps = steps
        self.installed = installed
        self.upgraded = upgraded
        self.downgraded = downgraded
        self.reinstalled = reinstalled
        self.removed = removed
        self.dependencies = dependencies
        self.warnings = warnings
        self.downloadSize = downloadSize
        self.installedSize = installedSize
    }

    public var isEmpty: Bool { steps.isEmpty }

    public var unpackSteps: [PackageRecord] {
        steps.compactMap { if case .unpack(let record) = $0 { return record } else { return nil } }
    }

    public var removeSteps: [(package: InstalledPackage, purge: Bool)] {
        steps.compactMap { if case .remove(let package, let purge) = $0 { return (package, purge) } else { return nil } }
    }

    /// A one-line description, e.g. "Install 3, Upgrade 1, Remove 2".
    public var summary: String {
        var parts: [String] = []
        if !installed.isEmpty { parts.append("Install \(installed.count)") }
        if !upgraded.isEmpty { parts.append("Upgrade \(upgraded.count)") }
        if !downgraded.isEmpty { parts.append("Downgrade \(downgraded.count)") }
        if !reinstalled.isEmpty { parts.append("Reinstall \(reinstalled.count)") }
        if !removed.isEmpty { parts.append("Remove \(removed.count)") }
        return parts.isEmpty ? "No changes" : parts.joined(separator: ", ")
    }
}

/// Something worth telling the user about before they tap Install.
public enum PlanWarning: Hashable, Sendable {
    case removingDependents(package: String, dependents: [String])
    case conflictingPackageRemoved(package: String, because: String)
    case packageProvides(virtual: String, providedBy: String)
    case recommendsNotInstalled(package: String, missing: [String])
    case downgrade(package: String, from: String, to: String)
    case unsignedRepository(source: String)
    case essentialTouched(packages: [String])
    case dependencyCycle(packages: [String])
    /// `Multi-Arch: same` instances were moved to one version together.
    case multiArchAligned(name: String, version: String, architectures: [String])
    /// They could not be aligned, so the transaction leaves them alone.
    case multiArchCannotAlign(name: String, reason: String)
    /// A pin or a hold changed what was selected.
    case policyApplied(name: String, detail: String)

    public var message: String {
        switch self {
        case .removingDependents(let package, let dependents):
            return "Removing \(package) will also remove \(dependents.joined(separator: ", "))."
        case .conflictingPackageRemoved(let package, let because):
            return "\(package) will be removed because it conflicts with \(because)."
        case .packageProvides(let virtual, let providedBy):
            return "\(virtual) is satisfied by \(providedBy), which will be installed."
        case .recommendsNotInstalled(let package, let missing):
            return "\(package) recommends \(missing.joined(separator: ", ")), which will not be installed."
        case .downgrade(let package, let from, let to):
            return "\(package) will be downgraded from \(from) to \(to)."
        case .unsignedRepository(let source):
            return "\(source) is not signed by a trusted key."
        case .essentialTouched(let packages):
            return "This transaction touches essential packages: \(packages.joined(separator: ", "))."
        case .dependencyCycle(let packages):
            return "\(packages.joined(separator: ", ")) depend on each other; they will be unpacked together."
        case .multiArchAligned(let name, let version, let architectures):
            return "\(name) is installed for \(architectures.joined(separator: " and ")); all instances move to \(version) together."
        case .multiArchCannotAlign(let name, let reason):
            return "\(name) cannot be aligned across architectures: \(reason)"
        case .policyApplied(let name, let detail):
            return "\(name): \(detail)"
        }
    }
}

/// Why a queue could not be turned into a plan.
public enum ResolutionError: Error, Hashable, Sendable, CustomStringConvertible {
    case packageNotFound(term: String, requestedBy: String?)
    case unsatisfiedDependency(package: String, clause: String)
    case versionConflict(package: String, wanted: String, available: String)
    case protectedPackage(name: String, reason: String)
    case downgradeRefused(package: String, from: String, to: String)
    case notInstalled(name: String)
    case sameVersion(name: String, version: String)

    public var description: String {
        switch self {
        case .packageNotFound(let term, let requestedBy):
            return "no package provides \(term)\(requestedBy.map { " (required by \($0))" } ?? "")"
        case .unsatisfiedDependency(let package, let clause):
            return "\(package) needs \(clause), which cannot be satisfied"
        case .versionConflict(let package, let wanted, let available):
            return "\(package) is pinned to \(available) but \(wanted) is required"
        case .protectedPackage(let name, let reason):
            return "\(name) cannot be removed: \(reason)"
        case .downgradeRefused(let package, let from, let to):
            return "refusing to downgrade \(package) from \(from) to \(to)"
        case .notInstalled(let name):
            return "\(name) is not installed"
        case .sameVersion(let name, let version):
            return "\(name) \(version) is already installed"
        }
    }
}
