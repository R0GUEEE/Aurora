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
/// the target set by walking dependencies depth-first, then repairs conflicts by
/// removing the loser, aligns `Multi-Arch: same` instances, and finally re-checks
/// every clause of everything it is about to touch. That is deliberately the same
/// shape as apt's problem resolver at the scale a phone repository reaches, and it
/// has one important property: **nothing is emitted until the whole set
/// type-checks**, so a user cannot end up with dpkg configuring half a
/// transaction.
///
/// The target set is keyed per *instance* (`name:architecture`), not per name, so
/// a `Multi-Arch: same` package can be upgraded in every architecture it is
/// installed for, and a package built for another architecture is a separate
/// thing rather than a replacement.
public struct DependencyResolver: Sendable {

    public struct Policy: Sendable {
        /// The device's dpkg architecture.
        public var architecture: String
        /// Architectures the client has indexes for.
        public var allowedArchitectures: Set<String>
        /// Repository priorities, pins and holds.
        public var packagePolicy: PackagePolicy
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
            allowedArchitectures: Set<String> = [],
            packagePolicy: PackagePolicy = .default,
            installRecommends: Bool = false,
            allowDowngrades: Bool = false,
            removeDependentsWithPackage: Bool = true,
            protectEssential: Bool = true,
            removeOrphanedDependencies: Bool = false
        ) {
            self.architecture = architecture
            self.allowedArchitectures = allowedArchitectures
            self.packagePolicy = packagePolicy
            self.installRecommends = installRecommends
            self.allowDowngrades = allowDowngrades
            self.removeDependentsWithPackage = removeDependentsWithPackage
            self.protectEssential = protectEssential
            self.removeOrphanedDependencies = removeOrphanedDependencies
        }

        public static let `default` = Policy()

        /// The Multi-Arch rules, in one place.
        public var satisfier: DependencySatisfier {
            DependencySatisfier(
                nativeArchitecture: architecture,
                allowedArchitectures: allowedArchitectures,
                policy: packagePolicy
            )
        }
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

/// The set of packages a transaction is trying to end up with.
///
/// Keyed by instance so that two architectures of a `Multi-Arch: same` package are
/// two entries, while an `all` package is one entry regardless of which
/// architecture asked for it.
struct TargetSet {

    private var byKey: [String: PackageRecord] = [:]

    var isEmpty: Bool { byKey.isEmpty }
    var count: Int { byKey.count }

    var all: [PackageRecord] {
        byKey.values.sorted { $0.instanceKey < $1.instanceKey }
    }

    func record(forKey key: String) -> PackageRecord? { byKey[key] }

    func instances(of name: String) -> [PackageRecord] {
        byKey.values.filter { $0.name == name }.sorted { $0.architecture < $1.architecture }
    }

    func contains(name: String) -> Bool {
        byKey.values.contains { $0.name == name }
    }

    mutating func insert(_ record: PackageRecord) {
        byKey[record.instanceKey] = record
    }

    mutating func remove(key: String) {
        byKey.removeValue(forKey: key)
    }

    mutating func removeAll(named name: String) {
        byKey = byKey.filter { $0.value.name != name }
    }

    func filter(_ predicate: (PackageRecord) -> Bool) -> [PackageRecord] {
        byKey.values.filter(predicate)
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

    /// Which warnings are produced by the alignment pass, so re-running the
    /// dependency walk does not duplicate them.
    static func isAlignmentWarning(_ warning: PlanWarning) -> Bool {
        switch warning {
        case .multiArchAligned, .multiArchCannotAlign: return true
        default: return false
        }
    }

    private var target = TargetSet()
    /// Names the user asked for explicitly.
    private var explicitNames: Set<String> = []
    /// Names pulled in because something else needed them (for the UI's "why is
    /// this happening?" section).
    private var pulledInNames: Set<String> = []
    /// Everything the resolver touched: only these are re-verified, so a device
    /// with a pre-existing unmet dependency can still install something new.
    private var inTransaction: Set<String> = []

    /// Names the user asked to remove, with the purge flag.
    private var requestedRemovals: [String: Bool] = [:]
    /// Removals forced by conflicts, dependents or orphanhood — keyed by instance.
    private var forcedRemovals: [String: (purge: Bool, because: String)] = [:]
    /// Removals that also take out installed instances of a *different*
    /// architecture of the same name (an architecture switch).
    private var replacedArchitectures: [String: String] = [:]

    init(available: PackageIndex, installed: InstalledPackageDatabase, policy: DependencyResolver.Policy) {
        self.available = available
        self.installed = installed
        self.policy = policy
    }

    // MARK: - Planning

    func plan(for queue: PackageQueue) -> TransactionPlan {
        seed(from: queue)
        if errors.isEmpty {
            // Dependencies, then alignment, then dependencies again: aligning a
            // `Multi-Arch: same` set can introduce a version whose own
            // dependencies have not been looked at yet. Two passes are enough for
            // the sets a phone repository produces; a third only repeats work.
            //
            // The second pass re-walks the same packages, so its warnings are
            // dropped rather than duplicated.
            resolveDependencies()
            if errors.isEmpty {
                // Alignment records into its own list so the repeated dependency
                // walk below cannot duplicate its warnings.
                warnings.removeAll { Self.isAlignmentWarning($0) }
                alignMultiArchSame()
                if errors.isEmpty { resolveDependencies() }
            }
        }
        if errors.isEmpty { resolveRemovals() }
        if errors.isEmpty { resolveConflicts() }
        if errors.isEmpty { verify() }
        return buildPlan()
    }

    /// Applies the queue to the installed state.
    private func seed(from queue: PackageQueue) {
        for entry in installed.present {
            target.insert(entry.record)
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
                guard stage(record, action: action) else { continue }
            }
        }
    }

    /// Adds an explicitly requested record, refusing the cases that are never what
    /// the user meant.
    private func stage(_ record: PackageRecord, action: PackageAction) -> Bool {
        if case .forbid = policy.packagePolicy.pin(for: record.name) {
            errors.append(.protectedPackage(
                name: record.name,
                reason: "it is marked forbidden in Aurora's preferences"
            ))
            return false
        }
        if let pinned = policy.packagePolicy.requiredVersion(for: record.name), pinned != record.version.raw {
            errors.append(.versionConflict(
                package: record.name,
                wanted: record.version.raw,
                available: "only \(pinned) is allowed by Aurora's preferences"
            ))
            return false
        }

        if let existing = installed.package(named: record.name, architecture: record.architecture) {
            // A version regression is refused whatever asked for it: an "upgrade"
            // action that resolves to an older version is still a downgrade, and
            // silently performing one is how a device ends up with a package its
            // dependencies cannot use.
            if DebianVersion.compare(record.version, existing.version) < 0, !policy.allowDowngrades {
                errors.append(.downgradeRefused(
                    package: record.name,
                    from: existing.version.raw,
                    to: record.version.raw
                ))
                return false
            }
        }

        explicitNames.insert(record.name)
        inTransaction.insert(record.name)
        replaceConflictingArchitectures(before: record)
        target.insert(record)
        return true
    }

    /// Installing a build for a different architecture replaces the installed one
    /// unless both sides are `Multi-Arch: same` (the only case where two
    /// architectures of one package coexist).
    private func replaceConflictingArchitectures(before record: PackageRecord) {
        for existing in target.instances(of: record.name) where existing.instanceKey != record.instanceKey {
            guard !(existing.isMultiArchSame && record.isMultiArchSame) else { continue }
            guard !existing.isArchitectureIndependent else { continue }
            target.remove(key: existing.instanceKey)
            if let entry = installed.package(named: existing.name, architecture: existing.architecture) {
                forcedRemovals[entry.instanceKey] = (false, "it is replaced by the \(record.architecture) build")
                replacedArchitectures[existing.instanceKey] = record.architecture
            }
        }
    }

    // MARK: - Dependencies

    private func resolveDependencies() {
        // Safe to run more than once: the walk is idempotent, but the *reports* it
        // produces are not, so the per-walk bookkeeping starts clean.
        warnings.removeAll { warning in
            if case .packageProvides = warning { return true }
            if case .recommendsNotInstalled = warning { return true }
            return false
        }
        var pending = target.all.filter { record in
            explicitNames.contains(record.name) || installed.package(named: record.name) != nil
        }
        var processed: Set<String> = []

        while let record = pending.popLast() {
            guard processed.insert(record.instanceKey).inserted else { continue }
            // A dependency of an `arm` package is resolved against `arm`, not
            // against the device's own architecture.
            let requested = record.architecture

            let clauses = record.relations.preDepends.clauses + record.relations.depends.clauses
            for clause in clauses {
                if let provider = satisfier(for: clause, requestedArchitecture: requested, excludingName: nil) {
                    if let first = clause.alternatives.first?.name, first != provider.name {
                        warnings.append(.packageProvides(virtual: first, providedBy: provider.name))
                    }
                    continue
                }
                guard let added = satisfy(clause: clause, because: record.name, requestedArchitecture: requested) else {
                    continue
                }
                if explicitNames.contains(added.name) || installed.package(named: added.name) != nil {
                    // Already present at another version: this is an upgrade of an
                    // existing install, not a new dependency.
                    inTransaction.insert(added.name)
                } else {
                    pulledInNames.insert(added.name)
                    inTransaction.insert(added.name)
                    // Alignment happens once, at the end, for packages the
                    // transaction actually touches: doing it here would move every
                    // co-installable instance of a dependency that merely happens
                    // to be installed.
                    pending.append(added)
                }
            }

            if policy.installRecommends {
                for clause in record.relations.recommends.clauses
                where satisfier(for: clause, requestedArchitecture: requested, excludingName: nil) == nil {
                    guard let added = satisfy(clause: clause, because: record.name, requestedArchitecture: requested) else { continue }
                    pulledInNames.insert(added.name)
                    inTransaction.insert(added.name)
                    pending.append(added)
                }
            } else {
                let missing = record.relations.recommends.clauses
                    .filter { satisfier(for: $0, requestedArchitecture: requested, excludingName: nil) == nil }
                    .map { $0.alternatives.map(\.name).joined(separator: " | ") }
                if !missing.isEmpty {
                    warnings.append(.recommendsNotInstalled(package: record.name, missing: missing))
                }
            }
        }
    }

    /// The best package in the target set that satisfies a clause.
    private func satisfier(
        for clause: DependencyClause,
        requestedArchitecture: String,
        excludingName: String?
    ) -> PackageRecord? {
        policy.satisfier.satisfier(
            of: clause,
            in: target.all,
            requestedArchitecture: requestedArchitecture,
            excluding: excludingName,
            policy: policy.packagePolicy
        )
    }

    /// The first alternative that can be satisfied wins, which is the documented
    /// meaning of `a | b`: the order is the packager's preference.
    private func satisfy(
        clause: DependencyClause,
        because: String,
        requestedArchitecture: String
    ) -> PackageRecord? {
        for term in clause.alternatives {
            let matches = available.rankedMatches(
                for: term,
                architecture: policy.architecture,
                requestedArchitecture: requestedArchitecture,
                allowedArchitectures: policy.allowedArchitectures,
                policy: policy.packagePolicy
            )
            guard let candidate = matches.first else { continue }

            // Already the right instance at the right version: nothing to add, and
            // *not* an error.
            if let chosen = target.record(forKey: candidate.instanceKey),
               DebianVersion.compare(chosen.version, candidate.version) == 0 {
                return nil
            }
            replaceConflictingArchitectures(before: candidate)
            target.insert(candidate)
            return candidate
        }

        errors.append(.unsatisfiedDependency(package: because, clause: clause.description))
        // Report the individual names when nothing at all matched, so the UI can
        // say exactly which package is missing.
        for term in clause.alternatives where available.rankedMatches(
            for: DependencyTerm(name: term.name),
            architecture: policy.architecture,
            requestedArchitecture: requestedArchitecture,
            allowedArchitectures: policy.allowedArchitectures,
            policy: policy.packagePolicy
        ).isEmpty {
            errors.append(.packageNotFound(term: term.name, requestedBy: because))
        }
        return nil
    }

    // MARK: - Multi-Arch: same

    /// Moves every installed instance of a `Multi-Arch: same` package to one
    /// version.
    ///
    /// dpkg refuses to configure a mismatched set, so upgrading just the arm64
    /// half of a library would fail halfway through. The aligned version is the
    /// highest one available for *every* architecture involved; if that would mean
    /// going backwards, the set is left alone and reported instead.
    private func alignMultiArchSame() {
        let names = Set(target.all.filter(\.isMultiArchSame).map(\.name))
        for name in names {
            let instances = target.instances(of: name).filter(\.isMultiArchSame)
            guard instances.count > 1 else { continue }

            var common: Set<String>?
            for instance in instances {
                let versions = Set(
                    available.candidates(named: name)
                        .filter { $0.architecture == instance.architecture || $0.architecture == "all" }
                        .map(\.version.raw)
                        .filter { version in
                            policy.packagePolicy.requiredVersion(for: name).map { $0 == version } ?? true
                        }
                )
                common = common.map { $0.intersection(versions) } ?? versions
            }
            guard let shared = common, !shared.isEmpty else {
                warnings.append(.multiArchCannotAlign(
                    name: name,
                    reason: "no version is available for every architecture it is installed for"
                ))
                continue
            }

            let installedVersions = instances.map(\.version)
            let candidates = shared.map { DebianVersion($0) }.sorted(by: >)
            guard let aligned = candidates.first(where: { version in
                installedVersions.allSatisfy { DebianVersion.compare($0, version) <= 0 }
            }) else {
                warnings.append(.multiArchCannotAlign(
                    name: name,
                    reason: "the only shared version is older than an installed instance"
                ))
                continue
            }

            var moved: [String] = []
            for instance in instances where DebianVersion.compare(instance.version, aligned) != 0 {
                guard let replacement = available.candidates(named: name).first(where: {
                    $0.version.raw == aligned.raw
                        && ($0.architecture == instance.architecture || $0.architecture == "all")
                }) else { continue }
                target.insert(replacement)
                moved.append(instance.architecture)
            }
            if !moved.isEmpty {
                inTransaction.insert(name)
                warnings.append(.multiArchAligned(name: name, version: aligned.raw, architectures: moved.sorted()))
            }
        }
    }

    // MARK: - Removals, conflicts, orphans

    private func resolveRemovals() {
        for (name, purge) in requestedRemovals {
            guard let entry = installed.package(named: name) else { continue }
            if policy.protectEssential, entry.record.isProtected {
                errors.append(.protectedPackage(name: name, reason: "it is an essential package"))
                continue
            }
            for instance in target.instances(of: name) {
                target.remove(key: instance.instanceKey)
                if let installedEntry = installed.package(named: name, architecture: instance.architecture) {
                    forcedRemovals[installedEntry.instanceKey] = (purge, "you asked to remove it")
                }
            }
            removeDependents(of: name, depth: 0)
        }

        if policy.removeOrphanedDependencies, errors.isEmpty {
            removeOrphans()
        }
    }

    /// Every installed package whose dependency is gone must go too, or refuse.
    private func removeDependents(of name: String, depth: Int) {
        guard depth < 64 else { return } // a cycle must not loop forever
        var dependents: [InstalledPackage] = []
        for entry in installed.present where entry.name != name && target.contains(name: entry.name) {
            let clauses = entry.record.relations.preDepends.clauses + entry.record.relations.depends.clauses
            let stillSatisfied = clauses.allSatisfy {
                satisfier(for: $0, requestedArchitecture: entry.architecture, excludingName: nil) != nil
            }
            if !stillSatisfied, !dependents.contains(where: { $0.instanceKey == entry.instanceKey }) {
                dependents.append(entry)
            }
        }
        guard !dependents.isEmpty else { return }

        if !policy.removeDependentsWithPackage {
            for dependent in dependents {
                errors.append(.protectedPackage(
                    name: dependent.name,
                    reason: "it depends on \(name), which you are removing"
                ))
            }
            return
        }

        warnings.append(.removingDependents(package: name, dependents: dependents.map(\.name)))
        for dependent in dependents {
            if policy.protectEssential, dependent.record.isProtected {
                errors.append(.protectedPackage(name: dependent.name, reason: "it is an essential package"))
                continue
            }
            target.remove(key: dependent.instanceKey)
            forcedRemovals[dependent.instanceKey] = (false, "it depends on \(name)")
            removeDependents(of: dependent.name, depth: depth + 1)
        }
    }

    /// Drops dependencies that are installed, were only pulled in as
    /// dependencies, and are no longer needed by anything left.
    private func removeOrphans() {
        var changed = true
        while changed {
            changed = false
            for entry in installed.present where target.record(forKey: entry.instanceKey) != nil {
                let record = entry.record
                let isExplicit = explicitNames.contains(record.name)
                let isProtected = record.isProtected
                guard !isExplicit, !isProtected else { continue }
                let needed = target.filter { $0.instanceKey != record.instanceKey }.contains { other in
                    let clauses = other.relations.preDepends.clauses + other.relations.depends.clauses
                    return clauses.contains { clause in
                        clause.alternatives.contains { $0.name == record.name }
                    }
                }
                if !needed {
                    target.remove(key: record.instanceKey)
                    forcedRemovals[entry.instanceKey] = (false, "nothing needs it any more")
                    changed = true
                }
            }
        }
    }

    /// Removes whatever the incoming packages conflict with, then re-checks the
    /// packages that depended on the losers.
    private func resolveConflicts() {
        for record in target.all {
            let clauses = record.relations.conflicts.clauses + record.relations.breaks.clauses
            for clause in clauses {
                guard let loser = satisfier(
                    for: clause,
                    requestedArchitecture: record.architecture,
                    excludingName: record.name
                ) else { continue }
                if policy.protectEssential, loser.isProtected {
                    errors.append(.protectedPackage(
                        name: loser.name,
                        reason: "\(record.name) conflicts with it"
                    ))
                    continue
                }
                guard let entry = installed.package(named: loser.name, architecture: loser.architecture) else {
                    // Not installed: just keep it out of the target set.
                    target.remove(key: loser.instanceKey)
                    continue
                }
                target.remove(key: loser.instanceKey)
                forcedRemovals[entry.instanceKey] = (false, "it conflicts with \(record.name)")
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
    /// something new.
    private func verify() {
        for record in target.all where inTransaction.contains(record.name) {
            let clauses = record.relations.preDepends.clauses + record.relations.depends.clauses
            for clause in clauses where satisfier(
                for: clause,
                requestedArchitecture: record.architecture,
                excludingName: nil
            ) == nil {
                errors.append(.unsatisfiedDependency(package: record.name, clause: clause.description))
            }
        }
    }

    // MARK: - Emitting the plan

    private func buildPlan() -> TransactionPlan {
        let removals = forcedRemovals
            .sorted { $0.key < $1.key }
            .compactMap { key, info -> (package: InstalledPackage, purge: Bool)? in
                guard let entry = installed.package(instanceKey: key) else { return nil }
                return (entry, info.purge)
            }

        let removedKeys = Set(removals.map { $0.package.instanceKey })

        var toInstall: [PackageRecord] = []
        var toUpgrade: [PackageRecord] = []
        var toDowngrade: [PackageRecord] = []
        var toReinstall: [PackageRecord] = []

        for record in target.all {
            guard !removedKeys.contains(record.instanceKey) else { continue }
            guard let existing = installed.package(named: record.name, architecture: record.architecture) else {
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
            } else if explicitNames.contains(record.name) {
                // Same version, but the user asked for it explicitly: a reinstall.
                toReinstall.append(record)
            }
        }

        let toUnpack = (toInstall + toUpgrade + toDowngrade + toReinstall).sorted { $0.instanceKey < $1.instanceKey }
        let (ordered, cycles) = topologicalOrder(toUnpack)
        if !cycles.isEmpty {
            warnings.append(.dependencyCycle(packages: cycles.flatMap { $0 }))
        }

        // dpkg needs a conflicting package gone before the newcomer unpacks.
        var steps: [TransactionPlan.Step] = []
        for removal in removals {
            steps.append(.remove(removal.package, purge: removal.purge))
        }
        let instanceCounts = Dictionary(grouping: ordered, by: \.name).mapValues(\.count)
        for record in ordered {
            steps.append(.unpack(record))
        }
        for record in ordered {
            // Plain name unless the plan really does touch two architectures of
            // it, so a single-architecture transaction reads the way it always did.
            let label = (instanceCounts[record.name] ?? 1) > 1 ? record.instanceKey : record.name
            steps.append(.configure(label))
        }

        let touched = removals.map { $0.package.name } + toUnpack.map(\.name)
        let essential = Array(Set(touched.filter { name in
            let record = target.instances(of: name).first
                ?? installed.package(named: name)?.record
            return record?.isProtected ?? false
        })).sorted()
        if !essential.isEmpty {
            warnings.append(.essentialTouched(packages: essential))
        }

        let downloadSize = toUnpack.reduce(0) { $0 + ($1.downloadSize ?? 0) }
        // An upgrade *replaces* the installed copy, so its size must be
        // subtracted; counting only additions would overstate the space needed.
        let replacedSize = (toUpgrade + toDowngrade + toReinstall).reduce(Int64(0)) { total, record in
            total + Int64((installed.package(named: record.name, architecture: record.architecture)?.record.installedSize ?? 0) * 1024)
        }
        let installedSize = toUnpack.reduce(Int64(0)) { $0 + Int64(($1.installedSize ?? 0) * 1024) }
            - replacedSize
            - removals.reduce(Int64(0)) { $0 + Int64(($1.package.record.installedSize ?? 0) * 1024) }

        let dependencies = toUnpack.filter { pulledInNames.contains($0.name) }

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
        let byKey = Dictionary(uniqueKeysWithValues: records.map { ($0.instanceKey, $0) })
        // Virtual name → real instance keys that provide it, built once instead of
        // rescanning the set at every edge.
        var providers: [String: [String]] = [:]
        for record in records {
            for provided in record.relations.provides {
                providers[provided.name, default: []].append(record.instanceKey)
            }
        }
        // A dependency on a name resolves to whichever instance provides it.
        var byName: [String: [String]] = [:]
        for record in records {
            byName[record.name, default: []].append(record.instanceKey)
        }

        /// Which instances of a dependency could be unpacked for this dependent.
        func compatibleKeys(for term: DependencyTerm, dependentArchitecture: String) -> [String] {
            var keys = byName[term.name] ?? []
            keys.append(contentsOf: providers[term.name] ?? [])
            return keys.filter { key in
                guard let record = byKey[key] else { return false }
                if record.architecture == "all" || record.architecture == dependentArchitecture { return true }
                if term.architectureQualifier?.lowercased() == "any" { return true }
                return record.isMultiArchForeign
            }
        }

        var ordered: [PackageRecord] = []
        var cycleProducts: [[String]] = []
        var state: [String: Int] = [:] // 0 = unvisited, 1 = in progress, 2 = done
        var stack: [String] = []

        func visit(_ key: String) {
            switch state[key] ?? 0 {
            case 1:
                if let start = stack.firstIndex(of: key) {
                    cycleProducts.append(Array(stack[start...]))
                }
                return
            case 2:
                return
            default:
                break
            }
            state[key] = 1
            stack.append(key)
            if let record = byKey[key] {
                let clauses = record.relations.preDepends.clauses + record.relations.depends.clauses
                for clause in clauses {
                    for term in clause.alternatives {
                        for candidateKey in compatibleKeys(for: term, dependentArchitecture: record.architecture)
                        where candidateKey != key {
                            visit(candidateKey)
                        }
                    }
                }
            }
            stack.removeLast()
            state[key] = 2
            if let record = byKey[key] { ordered.append(record) }
        }

        for record in records.sorted(by: { $0.instanceKey < $1.instanceKey }) {
            visit(record.instanceKey)
        }
        return (ordered, cycleProducts)
    }
}
