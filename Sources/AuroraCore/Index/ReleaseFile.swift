import Foundation

/// A `Release` file: the signed manifest that says which `Packages` files exist
/// and what they must hash to.
public struct ReleaseFile: Hashable, Sendable {

    public struct Checksum: Hashable, Sendable {
        public let algorithm: HashAlgorithm
        public let hex: String
        public let size: Int
        /// Repository-relative path, e.g. `main/binary-iphoneos-arm64/Packages`.
        public let path: String
    }

    public let stanza: ControlStanza
    public let origin: String?
    public let label: String?
    public let suite: String?
    public let codename: String?
    public let version: String?
    public let date: Date?
    public let validUntil: Date?
    public let architectures: [String]
    public let components: [String]
    public let checksums: [Checksum]

    public init(stanza: ControlStanza) {
        self.stanza = stanza
        self.origin = stanza.string("Origin")
        self.label = stanza.string("Label")
        self.suite = stanza.string("Suite")
        self.codename = stanza.string("Codename")
        self.version = stanza.string("Version")
        self.date = Self.parseDate(stanza.string("Date"))
        self.validUntil = Self.parseDate(stanza.string("Valid-Until"))
        self.architectures = (stanza.string("Architectures") ?? "").split(separator: " ").map(String.init)
        self.components = (stanza.string("Components") ?? "").split(separator: " ").map(String.init)
        self.checksums = Self.parseChecksums(stanza)
    }

    /// Each hash section is a block of `hash size path` lines:
    ///
    ///     SHA256:
    ///      9f2f… 1234567 main/binary-iphoneos-arm64/Packages.xz
    private static func parseChecksums(_ stanza: ControlStanza) -> [Checksum] {
        var checksums: [Checksum] = []
        for algorithm in HashAlgorithm.allCases {
            guard let block = stanza.string(algorithm.fieldName) else { continue }
            for line in block.split(separator: "\n") {
                let columns = line.split(separator: " ", omittingEmptySubsequences: true)
                guard columns.count >= 3 else { continue }
                let hex = String(columns[0])
                guard hex.count >= 32, hex.allSatisfy({ $0.isHexDigit }) else { continue }
                guard let size = Int(columns[1]) else { continue }
                let path = columns[2...].joined(separator: " ")
                checksums.append(Checksum(algorithm: algorithm, hex: hex, size: size, path: path))
            }
        }
        return checksums
    }

    static func parseDate(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        // `Date` in a Release file is RFC 1123-ish, but the zone token is "UTC"
        // rather than "GMT", so accept both.
        for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEE, dd MMM yyyy HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ss'Z'"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// The strongest checksum recorded for a repository-relative path.
    public func checksum(forPath path: String) -> Checksum? {
        for algorithm in HashAlgorithm.byStrength {
            if let match = checksums.first(where: { $0.algorithm == algorithm && $0.path == path }) {
                return match
            }
        }
        // Some repositories record an absolute path with a leading slash.
        let stripped = path.hasPrefix("/") ? String(path.dropFirst()) : "/" + path
        for algorithm in HashAlgorithm.byStrength {
            if let match = checksums.first(where: { $0.algorithm == algorithm && $0.path == stripped }) {
                return match
            }
        }
        return nil
    }

    public var isExpired: Bool {
        guard let validUntil else { return false }
        return validUntil < Date()
    }

    public var isStale: Bool {
        guard let date else { return false }
        // A week-old index usually means the repo is dead; the UI warns rather
        // than refuses, because plenty of jailbreak repos are updated rarely.
        return Date().timeIntervalSince(date) > 7 * 24 * 3600
    }
}
