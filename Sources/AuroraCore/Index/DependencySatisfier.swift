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
    }

    // MARK: - Architecture

    /// Whether this record's architecture is one Aurora may install at all.
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

    /// Every record in `candidates` that satisfies the clause, best first.
    ///
    /// Ordering is: most direct architecture, then repository priority, then
    /// newest version, then a stable tie-break.
    public func rankedSatisfiers(
        of clause: DependencyClause,
        in candidates: [PackageRecord],
        requestedArchitecture: String
    ) -> [Ranked] {
        var ranked: [Ranked] = []
        for term in clause.alternatives {
            for candidate in candidates {
                guard let rank = architectureRank(
                    term,
                    candidate: candidate,
                    requestedArchitecture: requestedArchitecture
                ) else { continue }
                guard matches(term, candidate: candidate, requestedArchitecture: requestedArchitecture) else {
                    continue
                }
                ranked.append(Ranked(record: candidate, architectureRank: rank))
            }
            // A satisfier for this alternative exists: alternatives are a
            // preference order, so the later ones are not candidates at all.
            if !ranked.isEmpty { break }
        }
        return ranked.sorted { Self.isBetter($0, $1, policy: policy) }
    }

    /// The single best satisfier in a set of records, or nil.
    public func satisfier(
        of clause: DependencyClause,
        in candidates: [PackageRecord],
        requestedArchitecture: String,
        excluding excludedName: String? = nil
    ) -> PackageRecord? {
        let filtered = excludedName.map { name in candidates.filter { $0.name != name } } ?? candidates
        return rankedSatisfiers(of: clause, in: filtered, requestedArchitecture: requestedArchitecture).first?.record
    }

    /// The ordering rule, in one place so the index and the resolver cannot drift.
    static func isBetter(_ lhs: Ranked, _ rhs: Ranked, policy: PackagePolicy) -> Bool {
        if lhs.architectureRank != rhs.architectureRank {
            return lhs.architectureRank < rhs.architectureRank
        }
        let lhsPriority = policy.priority(of: lhs.record)
        let rhsPriority = policy.priority(of: rhs.record)
        if lhsPriority != rhsPriority { return lhsPriority > rhsPriority }

        let order = DebianVersion.compare(lhs.record.version, rhs.record.version)
        if order != 0 { return order > 0 }
        if lhs.record.name != rhs.record.name { return lhs.record.name < rhs.record.name }
        return (lhs.record.origin?.description ?? "") < (rhs.record.origin?.description ?? "")
    }
}
