import Foundation

/// Decides whether a package can satisfy a dependency, and how good a fit it is.
///
/// This is the only place in Aurora that knows the Multi-Arch rules, because
/// getting them wrong in one place and right in another is how a package manager
/// installs something the device cannot run. The rules, from Debian policy §7.1:
///
/// * a dependency of a package built for `A` is satisfied by an `A` package, by
///   an `all` package, or by a package marked `Multi-Arch: foreign` **of any
///   architecture** (that is what `foreign` means: "my interface does not depend
///   on my architecture, so any instance of me will do");
/// * `foo:any` is satisfied by any architecture the client can install;
/// * `foo:arch` is a hard requirement for that architecture;
/// * a package that merely *provides* a name follows the same architecture rules
///   as a real package of that name.
///
/// Version rules are separate and equally load-bearing: only a **versioned**
/// `Provides` may satisfy a versioned dependency.
public struct DependencySatisfier: Sendable {

    /// The device's own dpkg architecture.
    public let nativeArchitecture: String
    /// Architectures the client actually fetched (a rootless device may have both
    /// `iphoneos-arm64` and `iphoneos-arm` available).
    public let allowedArchitectures: Set<String>
    public let policy: PackagePolicy

    public init(
        nativeArchitecture: String,
        allowedArchitectures: Set<String> = [],
        policy: PackagePolicy = .default
    ) {
        self.nativeArchitecture = nativeArchitecture
        self.allowedArchitectures = allowedArchitectures
        self.policy = policy
    }

    /// A record paired with how directly it matches what was asked for.
    public struct Ranked: Sendable {
        public let record: PackageRecord
        /// 0 = exactly the architecture asked for (or architecture-independent),
        /// 1 = acceptable but indirect (foreign instance, or `:any`).
        public let architectureRank: Int
        /// 0 = the real package, 1 = satisfies the name through `Provides`.
        public let providedRank: Int

        public init(record: PackageRecord, architectureRank: Int, providedRank: Int = 0) {
            self.record = record
            self.architectureRank = architectureRank
            self.providedRank = providedRank
        }
    }

    // MARK: - Architecture

    /// Whether this record's architecture is one Aurora may install at all.
    ///
    /// Stricter than "not the device architecture": a record is only installable
    /// if the client actually has that architecture, either as its own or as an
    /// explicitly allowed foreign one. Letting anything through here is how a
    /// package built for another platform gets installed.
    public func isInstallableArchitecture(_ architecture: String) -> Bool {
        if architecture == "all" { return true }
        if architecture == nativeArchitecture { return true }
        if allowedArchitectures.contains(architecture) { return true }
        return false
    }

    /// `nil` when the architecture makes the candidate unusable for this term.
    public func architectureRank(
        _ term: DependencyTerm,
        candidate: PackageRecord,
        requestedArchitecture: String
    ) -> Int? {
        let architecture = candidate.architecture
        guard isInstallableArchitecture(architecture) else { return nil }

        let qualifier = term.architectureQualifier?.lowercased()

        // An explicit qualifier is a requirement, not a preference. `:any` and
        // `:native` are the two that are not architecture names.
        if let qualifier, qualifier != "any", qualifier != "native" {
            if architecture == qualifier { return 0 }
            if architecture == "all" { return 0 }
            return nil
        }
        if qualifier == "native" {
            if architecture == nativeArchitecture || architecture == "all" { return 0 }
            return nil
        }

        if architecture == "all" { return 0 }
        if architecture == requestedArchitecture { return 0 }
        if qualifier == "any" { return 1 }

        // `Multi-Arch: foreign` is what makes a foreign instance usable.
        if candidate.isMultiArchForeign { return 1 }

        // An architecture-independent dependent may be satisfied by any
        // architecture the client has.
        if requestedArchitecture == "all" { return 1 }

        return nil
    }

    // MARK: - Satisfaction

    /// Whether `candidate` satisfies `term` when the dependency was declared by a
    /// package of `requestedArchitecture`.
    public func matches(
        _ term: DependencyTerm,
        candidate: PackageRecord,
        requestedArchitecture: String
    ) -> Bool {
        guard policy.allows(candidate.name) else { return false }
        guard architectureRank(term, candidate: candidate, requestedArchitecture: requestedArchitecture) != nil else {
            return false
        }

        if candidate.name == term.name {
            if let constraint = term.constraint, !constraint.isSatisfied(by: candidate.version) {
                return false
            }
            return true
        }

        // Otherwise the name must be provided. A versioned dependency needs a
        // versioned Provides: `Provides: foo` alone says "I am foo" without
        // saying which foo, and cannot satisfy `foo (>= 2)`.
        guard let provided = candidate.relations.provides.first(where: { $0.name == term.name }) else {
            return false
        }
        if let constraint = term.constraint {
            guard let providedVersion = provided.version, constraint.isSatisfied(by: providedVersion) else {
                return false
            }
        }
        return true
    }

    private func matchesIgnoringPolicy(
        _ term: DependencyTerm,
        candidate: PackageRecord,
        requestedArchitecture: String
    ) -> Bool {
        guard architectureRank(term, candidate: candidate, requestedArchitecture: requestedArchitecture) != nil else { return false }
        if candidate.name == term.name {
            return term.constraint?.isSatisfied(by: candidate.version) ?? true
        }
        guard let provided = candidate.relations.provides.first(where: { $0.name == term.name }) else { return false }
        if let constraint = term.constraint {
            guard let version = provided.version else { return false }
            return constraint.isSatisfied(by: version)
        }
        return true
    }

    /// Every record in `candidates` that satisfies the clause, best first.
    ///
    /// Ordering is: most direct architecture, then repository priority, then
    /// newest version, then a stable tie-break.
    public func rankedSatisfiers(
        of clause: DependencyClause,
        in candidates: [PackageRecord],
        requestedArchitecture: String,
        policy: PackagePolicy? = nil
    ) -> [Ranked] {
        let effectivePolicy = policy ?? self.policy
        var ranked: [Ranked] = []
        for term in clause.alternatives {
            for candidate in candidates {
                guard let rank = architectureRank(
                    term,
                    candidate: candidate,
                    requestedArchitecture: requestedArchitecture
                ) else { continue }
                guard effectivePolicy.allows(candidate.name) else { continue }
                guard matchesIgnoringPolicy(term, candidate: candidate, requestedArchitecture: requestedArchitecture) else {
                    continue
                }
                if let required = effectivePolicy.requiredVersion(for: candidate.name),
                   required != candidate.version.raw {
                    continue
                }
                ranked.append(Ranked(
                    record: candidate,
                    architectureRank: rank,
                    providedRank: candidate.name == term.name ? 0 : 1
                ))
            }
            // A satisfier for this alternative exists: alternatives are a
            // preference order, so the later ones are not candidates at all.
            if !ranked.isEmpty { break }
        }
        return ranked.sorted { Self.isBetter($0, $1, policy: effectivePolicy) }
    }

    /// Finds only the best satisfier without allocating and sorting the full
    /// ranked result set. Dependency resolution overwhelmingly needs one winner,
    /// so this avoids O(n log n) work for every dependency clause.
    public func bestSatisfier(
        of clause: DependencyClause,
        in candidates: [PackageRecord],
        requestedArchitecture: String,
        excluding excludedName: String? = nil,
        policy: PackagePolicy? = nil,
        requiredTermVersion: String? = nil
    ) -> PackageRecord? {
        let effectivePolicy = policy ?? self.policy

        for term in clause.alternatives {
            var best: Ranked?
            for candidate in candidates {
                if candidate.name == excludedName { continue }
                guard let rank = architectureRank(
                    term,
                    candidate: candidate,
                    requestedArchitecture: requestedArchitecture
                ) else { continue }
                guard effectivePolicy.allows(candidate.name) else { continue }
                guard matchesIgnoringPolicy(
                    term,
                    candidate: candidate,
                    requestedArchitecture: requestedArchitecture
                ) else { continue }
                if let required = effectivePolicy.requiredVersion(for: candidate.name),
                   required != candidate.version.raw {
                    continue
                }
                if let requiredTermVersion, candidate.version.raw != requiredTermVersion {
                    continue
                }

                let ranked = Ranked(
                    record: candidate,
                    architectureRank: rank,
                    providedRank: candidate.name == term.name ? 0 : 1
                )
                if let current = best {
                    if Self.isBetter(ranked, current, policy: effectivePolicy) {
                        best = ranked
                    }
                } else {
                    best = ranked
                }
            }
            // Alternatives are preference ordered. As soon as this alternative
            // has a satisfier, later alternatives are intentionally ignored.
            if let best { return best.record }
        }
        return nil
    }

    /// The single best satisfier in a set of records, or nil.
    public func satisfier(
        of clause: DependencyClause,
        in candidates: [PackageRecord],
        requestedArchitecture: String,
        excluding excludedName: String? = nil,
        policy: PackagePolicy? = nil
    ) -> PackageRecord? {
        bestSatisfier(
            of: clause,
            in: candidates,
            requestedArchitecture: requestedArchitecture,
            excluding: excludedName,
            policy: policy
        )
    }

    /// The ordering rule, in one place so the index and the resolver cannot drift.
    static func isBetter(_ lhs: Ranked, _ rhs: Ranked, policy: PackagePolicy) -> Bool {
        if lhs.architectureRank != rhs.architectureRank {
            return lhs.architectureRank < rhs.architectureRank
        }
        // A real package of that name beats one that merely provides it: a virtual
        // package is a stand-in, and installing the stand-in when the real thing is
        // available is never what was meant.
        if lhs.providedRank != rhs.providedRank { return lhs.providedRank < rhs.providedRank }
        // Repository priority is a tie-break between equivalent versions; it
        // must never make an older package beat a newer one.
        let order = DebianVersion.compare(lhs.record.version, rhs.record.version)
        if order != 0 { return order > 0 }

        let lhsPriority = policy.priority(of: lhs.record)
        let rhsPriority = policy.priority(of: rhs.record)
        if lhsPriority != rhsPriority { return lhsPriority > rhsPriority }
        if lhs.record.name != rhs.record.name { return lhs.record.name < rhs.record.name }
        return (lhs.record.origin?.description ?? "") < (rhs.record.origin?.description ?? "")
    }
}
