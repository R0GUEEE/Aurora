import Foundation

/// A repository the user added, in the form Aurora persists it.
///
/// Both layouts that real jailbreak repositories use are supported:
///
/// * **dists** — `https://repo.example.com/dists/<suite>/<component>/binary-<arch>/Packages`
/// * **flat** — `https://repo.example.com/<path>/Packages`, declared by the
///   non-standard suite `./`. Most jailbreak repos are flat.
public struct RepositorySource: Hashable, Sendable, Codable, Identifiable {

    public var id: UUID
    public var name: String
    /// Repository root, without a trailing slash and without `dists/`.
    public var url: String
    /// `stable`, `./` (flat) or a path fragment for flat repositories.
    public var suite: String
    public var components: [String]
    /// dpkg architecture names to fetch, e.g. `iphoneos-arm64`.
    public var architectures: [String]
    /// APT Deb822/classic modifiers relative to the configured/default list.
    /// Optional for backward-compatible decoding of older persisted sources.
    public var architectureAdditions: [String]?
    public var architectureRemovals: [String]?
    /// Armored OpenPGP keys the user trusts *in addition to* the system keyring.
    public var trustedKeys: [String]
    public var isEnabled: Bool
    public var isBuiltIn: Bool
    public var lastRefreshed: Date?
    public var lastError: String?
    /// Consecutive refresh failures. Reset to zero after a successful refresh.
    /// Optional so source files written by older Aurora builds decode unchanged.
    public var consecutiveFailures: Int?
    /// Source-list file this entry came from. Aurora writes only entries owned by
    /// its managed `sileo.sources` file and leaves other APT source files intact.
    public var sourceFile: String?

    public init(
        id: UUID = UUID(),
        name: String,
        url: String,
        suite: String = "./",
        components: [String] = ["main"],
        architectures: [String] = [],
        architectureAdditions: [String] = [],
        architectureRemovals: [String] = [],
        trustedKeys: [String] = [],
        isEnabled: Bool = true,
        isBuiltIn: Bool = false,
        lastRefreshed: Date? = nil,
        lastError: String? = nil,
        consecutiveFailures: Int? = nil,
        sourceFile: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.suite = suite
        self.components = components
        self.architectures = architectures
        self.architectureAdditions = architectureAdditions
        self.architectureRemovals = architectureRemovals
        self.trustedKeys = trustedKeys
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
        self.lastRefreshed = lastRefreshed
        self.lastError = lastError
        self.consecutiveFailures = consecutiveFailures
        self.sourceFile = sourceFile
    }

    /// Normalised so `https://a.com/` and `https://a.com` cannot coexist as two
    /// sources, which would show every package twice.
    public var normalizedURL: String {
        var value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// Sileo-compatible flat detection. Besides the conventional "./" suite,
    /// legacy source lines frequently use a path-like suite (for example
    /// "stable/" or "repo/") or simply omit components entirely.
    public func effectiveArchitectures(defaults: [String]) -> [String] {
        var result = architectures.isEmpty ? defaults : architectures
        result.append(contentsOf: architectureAdditions ?? [])
        let removed = Set(architectureRemovals ?? [])
        var seen = Set<String>()
        return result.filter { !removed.contains($0) && seen.insert($0).inserted }
    }

    public var isFlat: Bool {
        suite.isEmpty
            || suite == "./"
            || suite.hasPrefix("./")
            || suite.hasSuffix("/")
            || components.isEmpty
    }

    public var flatPathPrefix: String {
        guard isFlat else { return "" }
        var value = suite.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == "./" || value.isEmpty { return "" }
        if value.hasPrefix("./") { value = String(value.dropFirst(2)) }
        while value.hasPrefix("/") { value.removeFirst() }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// Release metadata location. Traditional dists repositories publish it under
    /// dists/<suite>/Release; flat jailbreak repositories commonly publish a
    /// Release file beside Packages (Sileo/Zebra both probe that root metadata).
    ///
    /// Package index paths are built by RepositoryClient, which owns format order.
    public var releasePath: String? {
        if isFlat {
            let prefix = flatPathPrefix
            return prefix.isEmpty ? "Release" : "\(prefix)/Release"
        }
        return "dists/\(suite)/Release"
    }

    public var isValid: Bool {
        guard let parsed = URL(string: normalizedURL),
              let scheme = parsed.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = parsed.host,
              !host.isEmpty else { return false }
        return true
    }
}

/// The set of repositories a user has configured.
public struct RepositoryList: Sendable, Codable {
    public var sources: [RepositorySource]

    public init(sources: [RepositorySource] = []) {
        self.sources = sources
    }

    public var enabled: [RepositorySource] { sources.filter(\.isEnabled) }

    /// Rejects a duplicate before it produces a doubled package list.
    public mutating func add(_ source: RepositorySource) throws {
        let candidate = source.normalizedURL.lowercased()
        if sources.contains(where: { $0.normalizedURL.lowercased() == candidate && $0.suite == source.suite }) {
            throw RepositoryError.duplicateSource(source.normalizedURL)
        }
        sources.append(source)
    }

    public mutating func remove(id: UUID) {
        sources.removeAll { $0.id == id }
    }

    public func source(id: UUID) -> RepositorySource? { sources.first { $0.id == id } }
}
