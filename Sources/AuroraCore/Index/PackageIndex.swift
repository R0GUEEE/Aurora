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

    /// The best record satisfying `term`, or nil.
    ///
    /// Ordering matters and is deliberate:
    /// 1. a real package beats a package that merely provides the name;
    /// 2. the newest version that satisfies the constraint wins;
    /// 3. among equals, the order inside the record's own index (repository
    ///    priority) decides, which is why ties fall back to the stored order.
    public func bestMatch(
        for term: DependencyTerm,
        architecture: String,
        allowedArchitectures: Set<String> = []
    ) -> PackageRecord? {
        var matches: [PackageRecord] = []
        let architectures = allowedArchitectures.isEmpty ? [architecture, "all"] : allowedArchitectures.union(["all", architecture])

        for record in candidates(named: term.name) where architectures.contains(record.architecture) {
            if let constraint = term.constraint {
                guard constraint.isSatisfied(by: record.version) else { continue }
            }
            matches.append(record)
        }
        if !matches.isEmpty { return matches.first }

        // Only a *versioned* Provides may satisfy a versioned dependency:
        // an unversioned `Provides: foo` says "I am foo" without saying which foo.
        for record in providers(of: term.name) where architectures.contains(record.architecture) {
            guard let provided = record.relations.provides.first(where: { $0.name == term.name }) else { continue }
            if let constraint = term.constraint {
                guard let providedVersion = provided.version, constraint.isSatisfied(by: providedVersion) else { continue }
            }
            matches.append(record)
        }
        return matches.first
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
        return counts.map { (name: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
    }
}
