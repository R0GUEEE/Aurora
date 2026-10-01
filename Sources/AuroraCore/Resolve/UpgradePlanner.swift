import Foundation

/// Decides which installed packages have an upgrade worth offering.
///
/// Shared by the CLI and the app so that "12 updates available" means the same
/// thing in both places, and so that a held package cannot be upgraded by one of
/// them and not the other.
public struct UpgradePlanner: Sendable {

    public struct Plan: Sendable {
        /// Newer candidates, one per installed instance.
        public let upgradable: [PackageRecord]
        /// Installed, upgradable, but held back on purpose.
        public let held: [String]
        /// Installed but forbidden by a pin, so Aurora will not touch it.
        public let forbidden: [String]
        /// Installed at a version newer than anything available, because a pin
        /// says so.
        public let pinnedBackwards: [(name: String, installed: String, allowed: String)]
        /// Installed packages whose repository no longer offers them at all.
        public let orphaned: [String]

        public var isEmpty: Bool { upgradable.isEmpty }
        public var count: Int { upgradable.count }

        /// One line for a header. Only the things that need a decision appear:
        /// "not in any repository" is a property of the device, not an update, and
        /// counting it here made "1 update" read as "1 update, 1 problem".
        public var summary: String {
            if upgradable.isEmpty {
                return held.isEmpty ? "Everything is up to date" : "\(held.count) held back"
            }
            var parts = ["\(upgradable.count) update\(upgradable.count == 1 ? "" : "s")"]
            if !held.isEmpty { parts.append("\(held.count) held") }
            if !forbidden.isEmpty { parts.append("\(forbidden.count) forbidden") }
            return parts.joined(separator: ", ")
        }
    }

    private let available: PackageIndex
    private let installed: InstalledPackageDatabase
    private let policy: DependencyResolver.Policy

    public init(
        available: PackageIndex,
        installed: InstalledPackageDatabase,
        policy: DependencyResolver.Policy
    ) {
        self.available = available
        self.installed = installed
        self.policy = policy
    }

    /// `includeHeld` is for the "upgrade everything, including what I held" case:
    /// a hold is a default, not a lock.
    public func plan(includeHeld: Bool = false) -> Plan {
        var upgradable: [PackageRecord] = []
        var held: [String] = []
        var forbidden: [String] = []
        var pinnedBackwards: [(name: String, installed: String, allowed: String)] = []
        var orphaned: [String] = []

        for entry in installed.present {
            let name = entry.name
            guard policy.packagePolicy.allows(name) else {
                forbidden.append(name)
                continue
            }

            let candidate = available.bestMatch(
                for: DependencyTerm(name: name),
                architecture: policy.architecture,
                requestedArchitecture: entry.architecture,
                allowedArchitectures: policy.allowedArchitectures,
                policy: policy.packagePolicy
            )
            guard let candidate else {
                // Nothing at all: either the repository dropped it, or a pin
                // excludes every available version.
                orphaned.append(name)
                continue
            }

            let comparison = DebianVersion.compare(candidate.version, entry.version)
            if comparison > 0 {
                if policy.packagePolicy.isHeld(name), !includeHeld {
                    held.append(name)
                    continue
                }
                upgradable.append(candidate)
            } else if let allowed = policy.packagePolicy.requiredVersion(for: name), allowed != entry.version.raw {
                // What the pin allows is not what is installed, so the package is
                // being held somewhere other than where it actually is. Saying so
                // beats reporting "nothing to do" while a pin quietly disagrees
                // with the device.
                pinnedBackwards.append((name: name, installed: entry.version.raw, allowed: allowed))
            }
        }

        return Plan(
            upgradable: upgradable,
            held: held,
            forbidden: forbidden,
            pinnedBackwards: pinnedBackwards,
            orphaned: orphaned
        )
    }

    /// The queue that ``plan(includeHeld:)`` describes, ready for the resolver.
    public func queue(includeHeld: Bool = false) -> PackageQueue {
        var queue = PackageQueue()
        for record in plan(includeHeld: includeHeld).upgradable {
            queue.stage(.upgrade(record))
        }
        return queue
    }
}
