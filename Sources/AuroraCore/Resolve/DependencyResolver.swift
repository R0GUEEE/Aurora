import Foundation

/// Several problems can exist at once, and a package manager is expected to list
/// them all rather than the first one it trips over.
public struct ResolutionFailure: Error, CustomStringConvertible {
    public let errors: [ResolutionError]
    public init(errors: [ResolutionError]) { self.errors = errors }
    public var description: String { errors.map(\.description).joined(separator: "\n") }
}

/// Turns staged intentions into a verified, ordered transaction.
///
/// The algorithm is greedy with a repair loop rather than a SAT solver: it builds
/// the target set by walking dependencies depth-first (preferring what is already
/// installed, then the highest satisfying version), then repairs conflicts by
/// removing the loser, and finally re-checks every clause in the set before
/// emitting a plan. That is deliberately the same shape as `apt`'s problem
/// resolver at the scale a phone repository actually reaches, and it has one
/// important property: **nothing is emitted until the whole set type-checks**,
/// so a user cannot end up with dpkg configuring half a transaction.
public struct DependencyResolver: Sendable {

    public struct Policy: Sendable {
        public var architecture: String
        /// Install `Recommends` along with dependencies. Off by default: on a phone
        /// this pulls in hundreds of megabytes of things nobody asked for.
        public var installRecommends: Bool
        public var allowDowngrades: Bool
        /// When a package is removed, remove the packages that depend on it too
        /// (offer to), instead of refusing.
        public var removeDependentsWithPackage: Bool
        /// Never touch essential/required packages.
        public var protectEssential: Bool
        /// Remove dependencies that nothing needs any more after a transaction.
        public var removeOrphanedDependencies: Bool

        public init(
            architecture: String = "iphoneos-arm64",
            installRecommends: Bool = false,
            allowDowngrades: Bool = false,
            removeDependentsWithPackage: Bool = true,
            protectEssential: Bool = true,
            removeOrphanedDependencies: Bool = false
        ) {
            self.architecture = architecture
            self.installRecommends = installRecommends
            self.allowDowngrades = allowDowngrades
            self.removeDependentsWithPackage = removeDependentsWithPackage
            self.protectEssential = protectEssential
            self.removeOrphanedDependencies = removeOrphanedDependencies
        }

        public static let `default` = Policy()
    }

    private let available: PackageIndex
    private let installed: InstalledPackageDatabase
    public let policy: Policy

    public init(available: PackageIndex, installed: InstalledPackageDatabase, policy: Policy = .default) {
        self.available = available
        self.installed = installed
        self.policy = policy
    }

    public func resolve(_ queue: PackageQueue) throws -> TransactionPlan {
        let resolution = Resolution(available: available, installed: installed, policy: policy)
        let plan = resolution.plan(for: queue)
        guard resolution.errors.isEmpty else {
            throw ResolutionFailure(errors: resolution.errors)
        }
        return plan
    }

    /// Non-throwing variant for previewing a queue in the UI as the user edits it.
    public func attempt(_ queue: PackageQueue) -> Result<TransactionPlan, ResolutionFailure> {
        do {
            return .success(try resolve(queue))
        } catch let failure as ResolutionFailure {
            return .failure(failure)
        } catch {
            return .failure(ResolutionFailure(errors: [
                .unsatisfiedDependency(package: queue.actions.first?.name ?? "", clause: "\(error)")
            ]))
        }
    }
}

/// Mutable working state for one resolution. Kept private so the public type stays
/// a value type with no half-built state.
private final class Resolution {

    let available: PackageIndex
    let installed: InstalledPackageDatabase
    let policy: DependencyResolver.Policy

    private(set) var errors: [ResolutionError] = []
    private var warnings: [PlanWarning] = []

    /// The target set. One version per package name; conflicts between versions
    /// are resolved when a clause is walked.
    private var selected: [String: PackageRecord] = [:]
    /// Names the user explicitly asked for.
    private var explicit: [String: PackageRecord] = [:]
    /// Names the user explicitly asked to remove, with the purge flag.
    private var requestedRemovals: [String: Bool] = [:]
    /// Removals forced by conflicts or by dependent packages.
    private var forcedRemovals: [String: (purge: Bool, because: String)] = [:]
    private var dependencyNames: Set<String> = []

    init(available: PackageIndex, installed: InstalledPackageDatabase, policy: DependencyResolver.Policy) {
        self.available = available
        self.installed = installed
        self.policy = policy
    }

    // MARK: - Planning

    func plan(for queue: PackageQueue) -> TransactionPlan {
        seed(from: queue)
        if errors.isEmpty {
            resolveDependencies()
        }
        if errors.isEmpty {
            resolveRemovals()
        }
        if errors.isEmpty {
            resolveConflicts()
        }
        if errors.isEmpty {
            verify()
        }

        return buildPlan()
    }

    /// Applies the queue to the installed state.
    private func seed(from queue: PackageQueue) {
        for entry in installed.present {
            selected[entry.name] = entry.record
        }

        for action in queue.actions {
            switch action {
            case .remove(let name, let purge):
                if installed.package(named: name) == nil {
                    errors.append(.notInstalled(name: name))
                    continue
                }
                requestedRemovals[name] = purge

            case .install(let record), .reinstall(let record), .upgrade(let record), .downgrade(let record):
                if let existing = installed.package(named: record.name) {
                    // A version regression is refused whatever asked for it: an
                    // "upgrade" action that resolves to an older version is still
                    // a downgrade, and silently performing one is how a device
                    // ends up with a package its dependencies cannot use.
                    if DebianVersion.compare(record.version, existing.version) < 0, !policy.allowDowngrades {
                        errors.append(.downgradeRefused(
                            package: record.name,
                            from: existing.version.raw,
                            to: record.version.raw
                        ))
                        continue
                    }
                } else if case .reinstall = action {
                    // Reinstalling something that is not installed is just an install.
                    explicit[record.name] = record
                    selected[record.name] = record
                    continue
                }
                explicit[record.name] = record
                selected[record.name] = record
            }
        }
    }

    /// Depth-first closure over `Pre-Depends` and `Depends`.
    private func resolveDependencies() {
        var pending: [PackageRecord] = selected.values
            .filter { explicit[$0.name] != nil || installed.package(named: $0.name) != nil }
            .sorted { $0.name < $1.name }
        var processed: Set<String> = []

        while let record = pending.popLast() {
            guard processed.insert(record.name).inserted else { continue }

            // Pre-Depends first: those decide unpack order, not just presence.
            let clauses = record.relations.preDepends.clauses + record.relations.depends.clauses
            for clause in clauses {
                if let provider = satisfier(of: clause, in: selected) {
                    // Tell the user when a virtual name was satisfied by a real
                    // package: "why is this being installed?" is the most common
                    // question about a queue.
                    if provider.name != record.name,
                       let first = clause.alternatives.first?.name,
                       first != provider.name {
                        warnings.append(.packageProvides(virtual: first, providedBy: provider.name))
                    }
                    continue
                }
                guard let added = satisfy(clause: clause, because: record.name) else { continue }
                selected[added.name] = added
                if explicit[added.name] == nil, installed.package(named: added.name) == nil {
                    dependencyNames.insert(added.name)
                }
                pending.append(added)
            }

            if policy.installRecommends {
                for clause in record.relations.recommends.clauses where satisfier(of: clause, in: selected) == nil {
                    guard let added = satisfy(clause: clause, because: record.name) else { continue }
                    selected[added.name] = added
                    if explicit[added.name] == nil, installed.package(named: added.name) == nil {
                        dependencyNames.insert(added.name)
                    }
                    pending.append(added)
                }
            } else {
                let missing = record.relations.recommends.clauses
                    .filter { satisfier(of: $0, in: selected) == nil }
                    .map { $0.alternatives.map(\.name).joined(separator: " | ") }
                if !missing.isEmpty {
                    warnings.append(.recommendsNotInstalled(package: record.name, missing: missing))
                }
            }
        }
    }

    /// The first alternative that can be satisfied wins, which is the documented
    /// meaning of `a | b`: the order is the packager's preference.
    private func satisfy(clause: DependencyClause, because: String) -> PackageRecord? {
        for term in clause.alternatives {
            guard let candidate = available.bestMatch(
                for: term,
                architecture: policy.architecture,
                allowedArchitectures: Set([policy.architecture])
            ) else { continue }
            // Already the right one: nothing to add, and *not* an error.
            if let chosen = selected[term.name], DebianVersion.compare(chosen.version, candidate.version) == 0 {
                return nil
            }
            return candidate
        }
        errors.append(.unsatisfiedDependency(
            package: because,
            clause: clause.description
        ))
        // Also report the individual terms when nothing at all matched, so the UI
        // can say exactly which name is missing.
        for term in clause.alternatives where available.bestMatch(
            for: DependencyTerm(name: term.name),
            architecture: policy.architecture
        ) == nil {
            errors.append(.packageNotFound(term: term.name, requestedBy: because))
        }
        return nil
    }

    /// The best package in the target set that satisfies a clause.
    private func satisfier(of clause: DependencyClause, in set: [String: PackageRecord], excluding excluded: String? = nil) -> PackageRecord? {
        for term in clause.alternatives {
            if term.name == excluded { continue }
            if let direct = set[term.name] {
                if let constraint = term.constraint {
                    if constraint.isSatisfied(by: direct.version) { return direct }
                } else {
                    return direct
                }
            }
            for record in set.values where record.name != excluded {
                for provided in record.relations.provides where provided.name == term.name {
                    if let constraint = term.constraint {
                        // Only a versioned Provides satisfies a versioned dependency.
                        guard let providedVersion = provided.version,
                              constraint.isSatisfied(by: providedVersion) else { continue }
                    }
                    return record
                }
            }
        }
        return nil
    }

    /// Handles explicit removals, the packages that depend on them, and — when
    /// asked — the dependencies nothing needs any more.
    private func resolveRemovals() {
        for (name, purge) in requestedRemovals {
            guard let entry = installed.package(named: name) else { continue }
            if policy.protectEssential, entry.record.isProtected {
                errors.append(.protectedPackage(name: name, reason: "it is an essential package"))
                continue
            }
            selected.removeValue(forKey: name)
            forcedRemovals[name] = (purge, "you asked to remove it")
            removeDependents(of: name, depth: 0)
        }

        if policy.removeOrphanedDependencies, errors.isEmpty {
            removeOrphans()
        }
    }

    /// Every installed package whose dependency is gone must go too, or refuse.
    private func removeDependents(of name: String, depth: Int) {
        guard depth < 64 else { return } // a cycle must not loop forever
        var dependents: [String] = []
        for entry in installed.present where entry.name != name && selected[entry.name] != nil {
            let clauses = entry.record.relations.preDepends.clauses + entry.record.relations.depends.clauses
            let stillSatisfied = clauses.allSatisfy { satisfier(of: $0, in: selected) != nil }
            if !stillSatisfied && !dependents.contains(entry.name) {
                dependents.append(entry.name)
            }
        }
        guard !dependents.isEmpty else { return }

        if !policy.removeDependentsWithPackage {
            for dependent in dependents where selected[dependent] != nil {
                errors.append(.protectedPackage(
                    name: dependent,
                    reason: "it depends on \(name), which you are removing"
                ))
            }
            return
        }

        warnings.append(.removingDependents(package: name, dependents: dependents))
        for dependent in dependents {
            guard let entry = installed.package(named: dependent) else { continue }
            if policy.protectEssential, entry.record.isProtected {
                errors.append(.protectedPackage(name: dependent, reason: "it is an essential package"))
                continue
            }
            selected.removeValue(forKey: dependent)
            forcedRemovals[dependent] = (false, "it depends on \(name)")
            removeDependents(of: dependent, depth: depth + 1)
        }
    }

    /// Drops dependencies that are installed, were only pulled in as
    /// dependencies, and are no longer needed by anything left.
    private func removeOrphans() {
        var changed = true
        while changed {
            changed = false
            for entry in installed.present where selected[entry.name] != nil {
                let record = entry.record
                let isExplicit = explicit[record.name] != nil
                let isEssential = record.isProtected
                guard !isExplicit, !isEssential else { continue }
                let needed = selected.values.contains { other in
                    guard other.name != record.name else { return false }
                    let clauses = other.relations.preDepends.clauses + other.relations.depends.clauses
                    return clauses.contains { clause in
                        clause.alternatives.contains { $0.name == record.name }
                    }
                }
                if !needed {
                    selected.removeValue(forKey: record.name)
                    forcedRemovals[record.name] = (false, "nothing needs it any more")
                    changed = true
                }
            }
        }
    }

    /// Removes whatever the incoming packages conflict with, then re-checks the
    /// packages that depended on the losers.
    private func resolveConflicts() {
        for record in selected.values.sorted(by: { $0.name < $1.name }) {
            let clauses = record.relations.conflicts.clauses + record.relations.breaks.clauses
            for clause in clauses {
                guard let loser = satisfier(of: clause, in: selected, excluding: record.name) else { continue }
                // `Replaces` on its own means "these two can coexist and I take
                // over the files" — in that case there is no Conflicts/Breaks
                // clause to walk in the first place, so no exemption belongs here.
                // When `Conflicts` *is* declared, the other package must go, which
                // is how `Conflicts` + `Replaces` pairs are meant to be read.
                if policy.protectEssential, loser.isProtected {
                    errors.append(.protectedPackage(
                        name: loser.name,
                        reason: "\(record.name) conflicts with it"
                    ))
                    continue
                }
                guard installed.package(named: loser.name) != nil else {
                    // Not installed: just keep it out of the target set.
                    selected.removeValue(forKey: loser.name)
                    continue
                }
                selected.removeValue(forKey: loser.name)
                forcedRemovals[loser.name] = (false, "it conflicts with \(record.name)")
                warnings.append(.conflictingPackageRemoved(package: loser.name, because: record.name))
                removeDependents(of: loser.name, depth: 0)
                if !errors.isEmpty { return }
            }
        }
    }

    /// The plan is only trustworthy if every clause of every package *in the
    /// transaction* is satisfied.
    ///
    /// Packages that are merely installed and untouched are skipped on purpose: a
    /// device with a pre-existing unmet dependency (very common on jailbreaks,
    /// where a repository disappeared years ago) must still be able to install
    /// something new. The dependency closure above already refuses to touch
    /// anything that would make those worse.
    private func verify() {
        let inTransaction = Set(explicit.keys).union(dependencyNames)
        for record in selected.values.sorted(by: { $0.name < $1.name }) {
            guard inTransaction.contains(record.name) else { continue }
            let clauses = record.relations.preDepends.clauses + record.relations.depends.clauses
            for clause in clauses where satisfier(of: clause, in: selected) == nil {
                errors.append(.unsatisfiedDependency(package: record.name, clause: clause.description))
            }
        }
    }

    // MARK: - Emitting the plan

    private func buildPlan() -> TransactionPlan {
        let removals = forcedRemovals
            .sorted { $0.key < $1.key }
            .compactMap { name, info -> (package: InstalledPackage, purge: Bool)? in
                guard let entry = installed.package(named: name) else { return nil }
                return (entry, info.purge)
            }

        let changed = selected.values.filter { record in
            guard let existing = installed.package(named: record.name) else {
                // Brand new, unless it is nothing but an available candidate that
                // never ended up needed.
                return !removals.contains { $0.package.name == record.name }
            }
            return DebianVersion.compare(existing.version, record.version) != 0
        }

        var toInstall: [PackageRecord] = []
        var toUpgrade: [PackageRecord] = []
        var toDowngrade: [PackageRecord] = []
        var toReinstall: [PackageRecord] = []

        for record in changed.sorted(by: { $0.name < $1.name }) {
            guard let existing = installed.package(named: record.name) else {
                // Already-downloaded identical version: still an install.
                toInstall.append(record)
                continue
            }
            let comparison = DebianVersion.compare(record.version, existing.version)
            if comparison > 0 {
                toUpgrade.append(record)
            } else if comparison < 0 {
                toDowngrade.append(record)
                warnings.append(.downgrade(
                    package: record.name,
                    from: existing.version.raw,
                    to: record.version.raw
                ))
            } else {
                toReinstall.append(record)
            }
        }

        // Explicit reinstalls that are not otherwise "changed".
        for (name, record) in explicit.sorted(by: { $0.key < $1.key }) {
            guard let existing = installed.package(named: name),
                  DebianVersion.compare(existing.version, record.version) == 0,
                  !toReinstall.contains(where: { $0.name == name }) else { continue }
            toReinstall.append(record)
        }

        let toUnpack = (toInstall + toUpgrade + toDowngrade + toReinstall).sorted { $0.name < $1.name }
        let (ordered, cycles) = topologicalOrder(toUnpack)
        if !cycles.isEmpty {
            warnings.append(.dependencyCycle(packages: cycles.flatMap { $0 }))
        }

        // dpkg needs a conflicting package gone before the newcomer unpacks.
        var steps: [TransactionPlan.Step] = []
        for removal in removals {
            steps.append(.remove(removal.package, purge: removal.purge))
        }
        for record in ordered {
            steps.append(.unpack(record))
        }
        for record in ordered {
            steps.append(.configure(record.name))
        }

        let essentialTouched = (removals.map { $0.package.name } + toUnpack.map(\.name))
            .filter { name in
                let record = selected[name] ?? installed.package(named: name)?.record
                return record?.isProtected ?? false
            }
        if !essentialTouched.isEmpty {
            warnings.append(.essentialTouched(packages: Array(Set(essentialTouched)).sorted()))
        }

        let downloadSize = toUnpack.reduce(0) { $0 + ($1.downloadSize ?? 0) }
        // An upgrade *replaces* the installed copy, so its size must be
        // subtracted; counting only additions would overstate the space needed.
        let replacedSize = (toUpgrade + toDowngrade + toReinstall).reduce(Int64(0)) { total, record in
            total + Int64((installed.package(named: record.name)?.record.installedSize ?? 0) * 1024)
        }
        let installedSize = toUnpack.reduce(Int64(0)) { $0 + Int64(($1.installedSize ?? 0) * 1024) }
            - replacedSize
            - removals.reduce(Int64(0)) { $0 + Int64(($1.package.record.installedSize ?? 0) * 1024) }

        let dependencies = toUnpack.filter { dependencyNames.contains($0.name) }

        return TransactionPlan(
            steps: steps,
            installed: toInstall,
            upgraded: toUpgrade,
            downgraded: toDowngrade,
            reinstalled: toReinstall,
            removed: removals.map { (package: $0.package, purge: $0.purge) },
            dependencies: dependencies,
            warnings: warnings,
            downloadSize: downloadSize,
            installedSize: installedSize
        )
    }

    /// Dependencies must be unpacked before their dependents, which is a
    /// topological sort of the subgraph induced by the packages being unpacked.
    private func topologicalOrder(_ records: [PackageRecord]) -> (ordered: [PackageRecord], cycles: [[String]]) {
        let byName = Dictionary(uniqueKeysWithValues: records.map { ($0.name, $0) })
        // Virtual name → real names that provide it, built once instead of
        // rescanning the set at every edge.
        var providers: [String: [String]] = [:]
        for record in records {
            for provided in record.relations.provides {
                providers[provided.name, default: []].append(record.name)
            }
        }

        var ordered: [PackageRecord] = []
        var cycleProducts: [[String]] = []
        var state: [String: Int] = [:] // 0 = unvisited, 1 = in progress, 2 = done
        var stack: [String] = []

        func visit(_ name: String) {
            switch state[name] ?? 0 {
            case 1:
                // Found a cycle: record the members and stop descending.
                if let start = stack.firstIndex(of: name) {
                    cycleProducts.append(Array(stack[start...]))
                }
                return
            case 2:
                return
            default:
                break
            }
            state[name] = 1
            stack.append(name)
            if let record = byName[name] {
                let clauses = record.relations.preDepends.clauses + record.relations.depends.clauses
                for clause in clauses {
                    for term in clause.alternatives {
                        if byName[term.name] != nil, term.name != name {
                            visit(term.name)
                        }
                        for provider in providers[term.name] ?? [] where provider != name {
                            visit(provider)
                        }
                    }
                }
            }
            stack.removeLast()
            state[name] = 2
            if let record = byName[name] {
                ordered.append(record)
            }
        }

        for record in records.sorted(by: { $0.name < $1.name }) {
            visit(record.name)
        }
        return (ordered, cycleProducts)
    }
}
