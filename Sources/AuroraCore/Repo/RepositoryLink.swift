import Foundation

/// Canonicalizes repository links from the forms users commonly paste into
/// Sileo/Zebra and turns them into Aurora's repository root + layout metadata.
///
/// Ordinary URLs are treated as flat repositories. Direct links to Packages/
/// Release files are folded back to their repository root, and distribution
/// dists paths are decoded when enough information is present.
public struct RepositoryLink: Sendable, Equatable {
    public let url: String
    public let suite: String?
    public let components: [String]
    public let architectures: [String]

    public init(url: String, suite: String? = nil, components: [String] = [], architectures: [String] = []) {
        self.url = url
        self.suite = suite
        self.components = components
        self.architectures = architectures
    }

    public static func parse(_ raw: String) -> RepositoryLink? {
        var input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        if (input.hasPrefix("<") && input.hasSuffix(">")) || (input.hasPrefix("\"") && input.hasSuffix("\"")) {
            input = String(input.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var explicitSuite: String?
        var explicitComponents: [String] = []
        var explicitArchitectures: [String] = []

        for prefix in ["sileo://source/", "sileo://url/"] where input.lowercased().hasPrefix(prefix) {
            input = String(input.dropFirst(prefix.count))
            input = input.removingPercentEncoding ?? input
            break
        }

        let zebraPrefix = "zbra://sources/add/"
        if input.lowercased().hasPrefix(zebraPrefix) {
            input = String(input.dropFirst(zebraPrefix.count))
            input = input.removingPercentEncoding ?? input
        }

        if let embedded = embeddedRepositoryURL(in: input) {
            input = embedded
        }

        if !input.contains("://") {
            let hostCandidate = input.split(separator: "/", maxSplits: 1).first.map(String.init) ?? input
            guard hostCandidate == "localhost" || hostCandidate.contains(".") else { return nil }
            input = "https://" + input
        }

        guard var components = URLComponents(string: input),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else {
            return nil
        }

        if let queryItems = components.queryItems {
            for item in queryItems {
                switch item.name.lowercased() {
                case "suite", "suites":
                    if let value = item.value {
                        explicitSuite = splitValues(value).first ?? explicitSuite
                    }
                case "component", "components":
                    if let value = item.value { explicitComponents = splitValues(value) }
                case "architecture", "architectures", "arch":
                    if let value = item.value { explicitArchitectures = splitValues(value) }
                default:
                    break
                }
            }
        }

        components.query = nil
        components.fragment = nil

        var pathParts = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).removingPercentEncoding ?? String($0) }

        var inferredSuite: String?
        var inferredComponents: [String] = []
        var inferredArchitectures: [String] = []

        if let last = pathParts.last, metadataFileNames.contains(last.lowercased()) {
            pathParts.removeLast()
        }

        if let distsIndex = pathParts.firstIndex(where: { $0.caseInsensitiveCompare("dists") == .orderedSame }) {
            if let binaryIndex = pathParts[distsIndex...].firstIndex(where: { $0.lowercased().hasPrefix("binary-") }),
               binaryIndex > distsIndex + 1 {
                let componentIndex = binaryIndex - 1
                let suiteParts = Array(pathParts[(distsIndex + 1)..<componentIndex])
                if !suiteParts.isEmpty {
                    inferredSuite = suiteParts.joined(separator: "/")
                    inferredComponents = [pathParts[componentIndex]]
                }
                let arch = String(pathParts[binaryIndex].dropFirst("binary-".count))
                if !arch.isEmpty { inferredArchitectures = [arch] }
            } else if pathParts.count > distsIndex + 1 {
                inferredSuite = Array(pathParts[(distsIndex + 1)...]).joined(separator: "/")
            }
            pathParts = Array(pathParts[..<distsIndex])
        }

        components.percentEncodedPath = pathParts.isEmpty
            ? ""
            : "/" + pathParts.map(percentEncodePathComponent).joined(separator: "/")

        guard let finalURL = components.url else { return nil }
        var canonical = finalURL.absoluteString
        while canonical.hasSuffix("/") { canonical.removeLast() }

        let suite = explicitSuite ?? inferredSuite
        let sourceComponents = explicitComponents.isEmpty ? inferredComponents : explicitComponents
        let architectures = explicitArchitectures.isEmpty ? inferredArchitectures : explicitArchitectures
        return canonicalizeKnownRepository(RepositoryLink(
            url: canonical,
            suite: suite,
            components: sourceComponents,
            architectures: architectures
        ))
    }

    /// Sileo and Zebra special-case a small set of historical distribution
    /// repositories instead of treating their host URL as a flat source. Keep
    /// that mapping here so manual adds, edits and bulk imports all agree.
    private static func canonicalizeKnownRepository(_ link: RepositoryLink) -> RepositoryLink {
        guard let host = URL(string: link.url)?.host?.lowercased() else { return link }

        if ["apt.bigboss.org", "apt.thebigboss.org", "thebigboss.org", "bigboss.org"].contains(host) {
            return RepositoryLink(
                url: "http://apt.thebigboss.org/repofiles/cydia",
                suite: "stable",
                components: ["main"],
                architectures: link.architectures
            )
        }

        if host == "apt.procurs.us" {
            return RepositoryLink(
                url: "https://apt.procurs.us",
                suite: link.suite ?? "iphoneos-arm64/1800",
                components: link.components.isEmpty ? ["main"] : link.components,
                architectures: link.architectures
            )
        }

        return link
    }

    private static let metadataFileNames: Set<String> = [
        "packages", "packages.gz", "packages.xz", "packages.zst", "packages.bz2", "packages.lzma",
        "release", "inrelease", "release.gpg", "release.asc"
    ]

    private static func splitValues(_ raw: String) -> [String] {
        raw.split { $0.isWhitespace || $0 == "," }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func embeddedRepositoryURL(in raw: String) -> String? {
        guard let parsed = URLComponents(string: raw) else { return nil }

        for item in parsed.queryItems ?? [] {
            if ["source", "repo", "url"].contains(item.name.lowercased()),
               let value = item.value, !value.isEmpty {
                return value.removingPercentEncoding ?? value
            }
        }

        if let fragment = parsed.fragment,
           let fragmentComponents = URLComponents(string: "https://aurora.invalid/?" + fragment.trimmingCharacters(in: CharacterSet(charactersIn: "?"))) {
            for item in fragmentComponents.queryItems ?? [] {
                if ["source", "repo", "url"].contains(item.name.lowercased()),
                   let value = item.value, !value.isEmpty {
                    return value.removingPercentEncoding ?? value
                }
            }
        }
        return nil
    }

    private static func percentEncodePathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
