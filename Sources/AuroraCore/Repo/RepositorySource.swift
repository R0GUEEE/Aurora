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
    /// Armored OpenPGP keys the user trusts *in addition to* the system keyring.
    public var trustedKeys: [String]
    public var isEnabled: Bool
    public var isBuiltIn: Bool
    public var lastRefreshed: Date?
    public var lastError: String?

    public init(
        id: UUID = UUID(),
        name: String,
        url: String,
        suite: String = "./",
        components: [String] = ["main"],
        architectures: [String] = [],
        trustedKeys: [String] = [],
        isEnabled: Bool = true,
        isBuiltIn: Bool = false,
        lastRefreshed: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.suite = suite
        self.components = components
        self.architectures = architectures
        self.trustedKeys = trustedKeys
        self.isEnabled = isEnabled
        self.isBuiltIn = isBuiltIn
        self.lastRefreshed = lastRefreshed
        self.lastError = lastError
    }

    /// Normalised so `https://a.com/` and `https://a.com` cannot coexist as two
    /// sources, which would show every package twice.
    public var normalizedURL: String {
        var value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    public var isFlat: Bool { suite == "./" || suite.hasPrefix("./") || suite.isEmpty }

    public var flatPathPrefix: String {
        suite.hasPrefix("./") ? String(suite.dropFirst(2)) : ""
    }

    /// The `Release` file for the whole suite (dists layout only). A flat
    /// repository has no release metadata at all.
    ///
    /// Package index paths are built by ``RepositoryClient``, which is the only
    /// place that knows the format preference order.
    public var releasePath: String? {
        isFlat ? nil : "dists/\(suite)/Release"
    }

    public var isValid: Bool {
        guard let parsed = URL(string: normalizedURL) else { return false }
        return parsed.scheme != nil && parsed.host != nil
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
