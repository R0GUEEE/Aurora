import Foundation

/// The pool of every package Aurora can install, merged from all enabled
/// repositories.
///
/// Lookups are index-based: a full jailbreak repo easily carries tens of
/// thousands of records, and the resolver asks for candidates hundreds of times
/// per transaction, so name lookups must not be a scan.
public struct PackageIndex: Sendable {

    public private(set) var records: [PackageRecord] = []
    private var byName: [String: [Int]] = [:]
    private var byProvidedName: [String: [Int]] = [:]

    public init() {}

    public init(records: [PackageRecord]) {
        for record in records { append(record) }
    }

    public var isEmpty: Bool { records.isEmpty }
    public var count: Int { records.count }

    public mutating func append(_ record: PackageRecord) {
        let index = records.count
        records.append(record)
        byName[record.name, default: []].append(index)
        for provided in record.relations.provides {
            byProvidedName[provided.name, default: []].append(index)
        }
    }

    public mutating func merge(_ other: PackageIndex) {
        for record in other.records { append(record) }
    }

    /// Drops everything that came from one repository, so a refresh can replace
    /// just that repository's records instead of reloading the world.
    public mutating func removeAll(from origin: RepositoryID) {
        let kept = records.filter { $0.origin != origin }
        self = PackageIndex(records: kept)
    }

    // MARK: - Lookup

    /// Every record with that exact package name, newest version first.
    public func candidates(named name: String) -> [PackageRecord] {
        (byName[name] ?? []).map { records[$0] }.sorted(by: Self.isPreferred)
    }

    /// Records that *provide* a virtual name, newest version first.
    public func providers(of name: String) -> [PackageRecord] {
        (byProvidedName[name] ?? []).map { records[$0] }.sorted(by: Self.isPreferred)
    }

    public func allVersions(of name: String) -> [DebianVersion] {
        candidates(named: name).map(\.version)
    }

    /// Every record that could satisfy `term`, best first.
    ///
    /// The ordering rules live in ``DependencySatisfier``, so that the index and
    /// the resolver cannot disagree about which package is the right one:
    ///
    /// 1. the architecture the dependency asked for wins over a `foreign`
    ///    instance of another architecture;
    /// 2. a higher repository priority (see ``PackagePolicy``) wins;
    /// 3. the newest satisfying version wins;
    /// 4. a real package wins over one that merely provides the name.
    ///
    /// A package pinned to a version is filtered down to that version, and a
    /// forbidden package is not a candidate at all.
    public func rankedMatches(
        for term: DependencyTerm,
        architecture: String,
        requestedArchitecture: String? = nil,
        allowedArchitectures: Set<String> = [],
        policy: PackagePolicy = .default
    ) -> [PackageRecord] {
        guard policy.allows(term.name) else { return [] }
        let requested = requestedArchitecture ?? architecture

        var pool = candidates(named: term.name)
        pool.append(contentsOf: providers(of: term.name))
        // A name can appear in both lists if a package provides its own name.
        var seen = Set<String>()
        pool = pool.filter {
            // Equal name/version/architecture records from different repositories
            // are distinct candidates because repository policy must be able to
            // choose between them.
            let key = "\($0.id)|\($0.origin?.description ?? "")"
            return seen.insert(key).inserted
        }

        let satisfier = DependencySatisfier(
            nativeArchitecture: architecture,
            allowedArchitectures: allowedArchitectures,
            policy: policy
        )
        let ranked = satisfier.rankedSatisfiers(
            of: DependencyClause(alternatives: [term]),
            in: pool,
            requestedArchitecture: requested,
            policy: policy
        )

        var records = ranked.map(\.record)

        // A direct lookup may explicitly allow a foreign architecture even when
        // that package is not Multi-Arch: foreign. Dependency resolution always
        // supplies requestedArchitecture and therefore keeps Debian's stricter
        // cross-architecture dependency rules.
        if requestedArchitecture == nil {
            let directForeign = pool.filter { candidate in
                guard allowedArchitectures.contains(candidate.architecture) else { return false }
                guard policy.allows(candidate.name) else { return false }
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
            records.append(contentsOf: directForeign)
            records = Array(Dictionary(grouping: records, by: {
                "\($0.id)|\($0.origin?.description ?? "")"
            }).values.compactMap(\.first))
            records.sort { lhs, rhs in
                let order = DebianVersion.compare(lhs.version, rhs.version)
                if order != 0 { return order > 0 }
                let lp = policy.priority(of: lhs), rp = policy.priority(of: rhs)
                if lp != rp { return lp > rp }
                return (lhs.origin?.description ?? "") < (rhs.origin?.description ?? "")
            }
        }
        if let pinned = policy.requiredVersion(for: term.name) {
            records = records.filter { $0.version.raw == pinned }
        }
        return records
    }

    /// The best record satisfying `term`, or nil.
    public func bestMatch(
        for term: DependencyTerm,
        architecture: String,
        requestedArchitecture: String? = nil,
        allowedArchitectures: Set<String> = [],
        policy: PackagePolicy = .default
    ) -> PackageRecord? {
        rankedMatches(
            for: term,
            architecture: architecture,
            requestedArchitecture: requestedArchitecture,
            allowedArchitectures: allowedArchitectures,
            policy: policy
        ).first
    }

    /// Versions of a package offered for one architecture, newest first. Used by
    /// the downgrade picker, which must not offer a record it cannot install.
    public func versions(of name: String, architecture: String) -> [PackageRecord] {
        candidates(named: name)
            .filter { $0.architecture == architecture || $0.architecture == "all" }
            .sorted { Self.isPreferred($0, $1) }
    }

    /// Newest-first by version, then by name, then by repository.
    ///
    /// The repository tie-break is not decorative: `sorted(by:)` is not guaranteed
    /// to be stable, so without a total order the same package could be picked
    /// from a different repository between runs, which would make resolution — and
    /// therefore the whole transaction — non-deterministic.
    static func isPreferred(_ lhs: PackageRecord, _ rhs: PackageRecord) -> Bool {
        let order = DebianVersion.compare(lhs.version, rhs.version)
        if order != 0 { return order > 0 }
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        return (lhs.origin?.description ?? "") < (rhs.origin?.description ?? "")
    }

    // MARK: - Search and browsing

    /// Substring search over the fields a user actually recognises.
    public func search(_ query: String, section: String? = nil, limit: Int = 200) -> [PackageRecord] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        var results: [PackageRecord] = []
        for record in records {
            if let section, !section.isEmpty, record.section != section { continue }
            if needle.isEmpty {
                results.append(record)
            } else if record.name.lowercased().contains(needle)
                || record.displayName.lowercased().contains(needle)
                || record.synopsis.lowercased().contains(needle) {
                results.append(record)
            }
            if results.count >= limit * 4 { break }
        }
        // Collapse to one row per name, best version first.
        var best: [String: PackageRecord] = [:]
        for record in results {
            if let existing = best[record.name] {
                if Self.isPreferred(record, existing) { best[record.name] = record }
            } else {
                best[record.name] = record
            }
        }
        return best.values.sorted {
            if $0.name.lowercased() == needle && $1.name.lowercased() != needle { return true }
            if $1.name.lowercased() == needle && $0.name.lowercased() != needle { return false }
            return Self.isPreferred($0, $1)
        }.prefix(limit).map { $0 }
    }

    /// Section name → number of packages, most populated first.
    public func sections() -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        var seen: Set<String> = []
        for record in records {
            guard seen.insert(record.name).inserted else { continue }
            counts[record.section.isEmpty ? "Uncategorised" : record.section, default: 0] += 1
        }
        // Most populated first, then alphabetically, so the list is stable and
        // readable when many sections have the same number of packages.
        return counts.map { (name: $0.key, count: $0.value) }
            .sorted { left, right in
                if left.count != right.count { return left.count > right.count }
                return left.name < right.name
            }
    }
}
