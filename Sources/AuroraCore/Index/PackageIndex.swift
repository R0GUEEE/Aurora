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
    private var normalizedSearchText: [String] = []

    public init() {}

    public init(records: [PackageRecord]) {
        self.records = records
        rebuildLookupTables()
    }

    public var isEmpty: Bool { records.isEmpty }
    public var count: Int { records.count }

    /// Preallocates the two arrays that grow once per package during a bulk merge.
    /// Dictionary buckets are reserved conservatively because one package name can
    /// have several versions/architectures.
    public mutating func reserveCapacity(_ minimumCapacity: Int) {
        guard minimumCapacity > 0 else { return }
        records.reserveCapacity(minimumCapacity)
        normalizedSearchText.reserveCapacity(minimumCapacity)
        byName.reserveCapacity(minimumCapacity)
        byProvidedName.reserveCapacity(max(16, minimumCapacity / 4))
    }

    public mutating func append(_ record: PackageRecord) {
        let index = records.count
        records.append(record)
        normalizedSearchText.append(Self.searchText(for: record))
        byName[record.name, default: []].append(index)
        byName[record.name]?.sort { Self.isPreferred(records[$0], records[$1]) }
        for provided in record.relations.provides {
            byProvidedName[provided.name, default: []].append(index)
            byProvidedName[provided.name]?.sort { Self.isPreferred(records[$0], records[$1]) }
        }
    }

    public mutating func merge(_ other: PackageIndex) {
        guard !other.records.isEmpty else { return }
        let offset = records.count
        records.append(contentsOf: other.records)
        normalizedSearchText.append(contentsOf: other.normalizedSearchText)
        for (name, indexes) in other.byName {
            byName[name] = mergePreferredIndexes(
                byName[name] ?? [],
                indexes,
                rightOffset: offset
            )
        }
        for (name, indexes) in other.byProvidedName {
            byProvidedName[name] = mergePreferredIndexes(
                byProvidedName[name] ?? [],
                indexes,
                rightOffset: offset
            )
        }
    }

    private mutating func rebuildLookupTables() {
        byName.removeAll(keepingCapacity: true)
        byProvidedName.removeAll(keepingCapacity: true)
        normalizedSearchText = records.map(Self.searchText(for:))
        byName.reserveCapacity(records.count)
        byProvidedName.reserveCapacity(max(16, records.count / 4))
        for (index, record) in records.enumerated() {
            byName[record.name, default: []].append(index)
            for provided in record.relations.provides {
                byProvidedName[provided.name, default: []].append(index)
            }
        }
        for name in Array(byName.keys) {
            byName[name]?.sort { Self.isPreferred(records[$0], records[$1]) }
        }
        for name in Array(byProvidedName.keys) {
            byProvidedName[name]?.sort { Self.isPreferred(records[$0], records[$1]) }
        }
    }

    private func mergePreferredIndexes(
        _ left: [Int],
        _ right: [Int],
        rightOffset: Int
    ) -> [Int] {
        guard !left.isEmpty else { return right.map { $0 + rightOffset } }
        guard !right.isEmpty else { return left }

        var result: [Int] = []
        result.reserveCapacity(left.count + right.count)
        var l = 0
        var r = 0

        while l < left.count && r < right.count {
            let leftIndex = left[l]
            let rightIndex = right[r] + rightOffset
            let leftPreferred = Self.isPreferred(records[leftIndex], records[rightIndex])
            let rightPreferred = Self.isPreferred(records[rightIndex], records[leftIndex])
            // Keep the existing (left/source) order when the comparator considers
            // two records equivalent.
            if leftPreferred || !rightPreferred {
                result.append(leftIndex)
                l += 1
            } else {
                result.append(rightIndex)
                r += 1
            }
        }
        if l < left.count { result.append(contentsOf: left[l...]) }
        if r < right.count {
            for index in right[r...] { result.append(index + rightOffset) }
        }
        return result
    }

    /// Drops everything that came from one repository, so a refresh can replace
    /// just that repository's records instead of reloading the world.
    public mutating func removeAll(from origin: RepositoryID) {
        records.removeAll { $0.origin == origin }
        rebuildLookupTables()
    }

    // MARK: - Lookup

    /// Every record with that exact package name, newest version first.
    public func candidates(named name: String) -> [PackageRecord] {
        (byName[name] ?? []).map { records[$0] }
    }

    /// Fast path for the common UI/resolver operation that only needs the best
    /// candidate. Lookup tables are maintained in preferred order.
    public func bestCandidate(named name: String) -> PackageRecord? {
        guard let index = byName[name]?.first else { return nil }
        return records[index]
    }

    /// Records that *provide* a virtual name, newest version first.
    public func providers(of name: String) -> [PackageRecord] {
        (byProvidedName[name] ?? []).map { records[$0] }
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
                // This escape hatch is only for explicitly selecting the real
                // package from an allowed foreign architecture. Providers still
                // follow normal Multi-Arch ranking, including the rule that a
                // real package beats a virtual provider.
                guard candidate.name == term.name else { return false }
                guard allowedArchitectures.contains(candidate.architecture) else { return false }
                guard policy.allows(candidate.name) else { return false }
                return term.constraint?.isSatisfied(by: candidate.version) ?? true
            }
            records.append(contentsOf: directForeign)
            records = Array(Dictionary(grouping: records, by: {
                "\($0.id)|\($0.origin?.description ?? "")"
            }).values.compactMap(\.first))
            records.sort { lhs, rhs in
                // Preserve the dependency rule even in the explicit foreign-
                // architecture escape hatch: a real package beats a provider.
                let lDirect = lhs.name == term.name
                let rDirect = rhs.name == term.name
                if lDirect != rDirect { return lDirect }
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
        // Explicit package browsing has a deliberate foreign-architecture escape
        // hatch implemented by rankedMatches(). Dependency/upgrade planning always
        // supplies requestedArchitecture, so it can use the much cheaper one-pass
        // selector below.
        guard let requestedArchitecture else {
            return rankedMatches(
                for: term,
                architecture: architecture,
                requestedArchitecture: nil,
                allowedArchitectures: allowedArchitectures,
                policy: policy
            ).first
        }
        guard policy.allows(term.name) else { return nil }

        var pool = candidates(named: term.name)
        pool.append(contentsOf: providers(of: term.name))
        if pool.count > 1 {
            var seen = Set<String>()
            seen.reserveCapacity(pool.count)
            pool = pool.filter {
                let key = "\($0.id)|\($0.origin?.description ?? "")"
                return seen.insert(key).inserted
            }
        }

        let satisfier = DependencySatisfier(
            nativeArchitecture: architecture,
            allowedArchitectures: allowedArchitectures,
            policy: policy
        )
        return satisfier.bestSatisfier(
            of: DependencyClause(alternatives: [term]),
            in: pool,
            requestedArchitecture: requestedArchitecture,
            policy: policy,
            requiredTermVersion: policy.requiredVersion(for: term.name)
        )
    }

    /// Versions of a package offered for one architecture, newest first. Used by
    /// the downgrade picker, which must not offer a record it cannot install.
    public func versions(of name: String, architecture: String) -> [PackageRecord] {
        // Filtering preserves the candidate bucket's preferred ordering.
        candidates(named: name)
            .filter { $0.architecture == architecture || $0.architecture == "all" }
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
    public func search(
        _ query: String,
        section: String? = nil,
        limit: Int = 200,
        matching predicate: (PackageRecord) -> Bool = { _ in true }
    ) -> [PackageRecord] {
        guard limit > 0 else { return [] }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        // Collapse to one row per name while scanning. Avoiding an intermediate
        // array of every matching version materially reduces allocations on large
        // repositories and keeps search responsive while the user is typing.
        var best: [String: PackageRecord] = [:]
        best.reserveCapacity(min(limit * 2, records.count))
        for (index, record) in records.enumerated() {
            if let section, !section.isEmpty, record.section != section { continue }
            guard needle.isEmpty || normalizedSearchText[index].contains(needle) else { continue }
            guard predicate(record) else { continue }
            if let existing = best[record.name] {
                if Self.isPreferred(record, existing) { best[record.name] = record }
            } else {
                best[record.name] = record
            }
        }
        let decorated = best.values.map {
            (record: $0, id: $0.name.lowercased(), displayName: $0.displayName.lowercased())
        }
        return decorated.sorted { lhs, rhs in
            if lhs.id == needle && rhs.id != needle { return true }
            if rhs.id == needle && lhs.id != needle { return false }
            if lhs.displayName == needle && rhs.displayName != needle { return true }
            if rhs.displayName == needle && lhs.displayName != needle { return false }
            let lIDPrefix = lhs.id.hasPrefix(needle), rIDPrefix = rhs.id.hasPrefix(needle)
            if lIDPrefix != rIDPrefix { return lIDPrefix }
            let lNamePrefix = lhs.displayName.hasPrefix(needle), rNamePrefix = rhs.displayName.hasPrefix(needle)
            if lNamePrefix != rNamePrefix { return lNamePrefix }
            return Self.isPreferred(lhs.record, rhs.record)
        }.prefix(limit).map { $0.record }
    }

    private static func searchText(for record: PackageRecord) -> String {
        [
            record.name,
            record.displayName,
            record.synopsis,
            record.section,
            record.author ?? "",
            record.maintainer
        ].joined(separator: "\u{1F}").lowercased()
    }

    /// Section name → number of packages, most populated first.
    public func sections() -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        counts.reserveCapacity(32)
        for indexes in byName.values {
            guard let index = indexes.first else { continue }
            let record = records[index]
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
