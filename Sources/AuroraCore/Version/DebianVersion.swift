import Foundation

/// A Debian package version string: `[epoch:]upstream_version[-debian_revision]`.
///
/// Parsing and ordering mirror `dpkg`'s own implementation
/// (`lib/dpkg/parsehelp.c`, `dpkg_vercmp`) rather than a casual reading of the
/// policy document, because the policy text is famously not sufficient to derive
/// the ordering. In particular:
///
/// * `~` sorts *before* everything, including the empty string, so
///   `1.0~rc1 < 1.0`;
/// * digit runs are compared numerically, everything else byte by byte with
///   letters ordering above punctuation, and end-of-string ordering below `~`;
/// * the epoch is compared numerically and only then are upstream and revision
///   considered — a higher epoch wins regardless of the rest.
///
/// The type is deliberately *lenient*: a package manager has to compare whatever
/// a repository serves, including versions that a Debian builder would reject.
/// Use ``isWellFormed`` to check policy conformance when that matters (building a
/// control file, for instance).
public struct DebianVersion: Hashable, Sendable, Comparable, CustomStringConvertible {

    /// Major version, before the first `:` when one is present.
    public let epoch: UInt32
    /// The part that identifies the upstream release.
    public let upstream: String
    /// The part after the last `-`, empty when the version carries none.
    public let revision: String
    /// Whether the input actually had an explicit `<epoch>:`.
    public let hasEpoch: Bool
    /// Whether the input actually had an explicit `-<revision>`.
    public let hasRevision: Bool
    /// The version exactly as it was given, for round-tripping into indexes.
    public let raw: String

    // Comparison works on UTF-8 bytes so that non-ASCII input behaves the way it
    // does in C (dpkg compares bytes, not grapheme clusters).
    private let upstreamBytes: [UInt8]
    private let revisionBytes: [UInt8]

    // MARK: - Parsing

    public init(_ raw: String) {
        self.raw = raw

        var epoch: UInt32 = 0
        var hasEpoch = false
        var body = raw[...]

        if let colon = body.firstIndex(of: ":") {
            let head = body[body.startIndex..<colon]
            // A leading colon, or anything but digits in front of it, means the
            // colon is part of the upstream version and not an epoch separator.
            if !head.isEmpty, head.allSatisfy({ $0.isASCII && $0.isNumber }) {
                epoch = UInt32(head) ?? 0
                hasEpoch = true
                body = body[body.index(after: colon)...]
            }
        }

        var revision = ""
        var hasRevision = false
        if let dash = body.lastIndex(of: "-") {
            revision = String(body[body.index(after: dash)...])
            hasRevision = true
            body = body[..<dash]
        }

        self.epoch = epoch
        self.upstream = String(body)
        self.revision = revision
        self.hasEpoch = hasEpoch
        self.hasRevision = hasRevision
        self.upstreamBytes = Array(self.upstream.utf8)
        self.revisionBytes = Array(revision.utf8)
    }

    /// Whether the version satisfies the grammar in Debian Policy §5.6.12:
    /// an upstream part that starts with a digit, and a revision built from
    /// `[0-9A-Za-z.+~]` only.
    public var isWellFormed: Bool {
        guard !upstream.isEmpty else { return false }
        guard let first = upstream.utf8.first, Self.isDigit(first) else { return false }
        let upstreamAllowed = Set("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-+~:")
        guard upstream.allSatisfy({ upstreamAllowed.contains($0) }) else { return false }
        guard !upstream.contains(":") else { return false } // only the epoch may carry one
        let revisionAllowed = Set("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.+~")
        return hasRevision ? revision.allSatisfy({ revisionAllowed.contains($0) }) : true
    }

    // MARK: - Ordering

    public static func < (lhs: DebianVersion, rhs: DebianVersion) -> Bool {
        compare(lhs, rhs) < 0
    }

    /// Returns a negative number when `lhs` sorts before `rhs`, zero when the two
    /// versions are equal (which is *not* the same as `lhs.raw == rhs.raw`:
    /// `1.0` and `1:1.0` compare equal under dpkg), and a positive number otherwise.
    public static func compare(_ lhs: DebianVersion, _ rhs: DebianVersion) -> Int {
        if lhs.epoch != rhs.epoch {
            return lhs.epoch < rhs.epoch ? -1 : 1
        }
        let upstreamResult = versionCompare(lhs.upstreamBytes, rhs.upstreamBytes)
        if upstreamResult != 0 { return upstreamResult }
        return versionCompare(lhs.revisionBytes, rhs.revisionBytes)
    }

    /// `dpkg`'s `order()`: digit runs are handled separately, `~` is special-cased
    /// to sort before everything, and end-of-string collapses to zero (which is
    /// below `~` and below every other character).
    @inline(__always)
    private static func order(_ byte: UInt8?) -> Int {
        guard let byte else { return 0 }
        if isDigit(byte) { return 0 }
        if isAlpha(byte) { return Int(byte) }
        if byte == UInt8(ascii: "~") { return -1 }
        return Int(byte) + 256
    }

    @inline(__always)
    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    @inline(__always)
    private static func isAlpha(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
            || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
    }

    /// `dpkg`'s `verrevcmp()`: alternate between "everything that is not a digit"
    /// and "a run of digits", comparing the former byte-wise and the latter
    /// numerically (leading zeros ignored, but the first differing digit decides
    /// when the two runs are the same length).
    static func versionCompare(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var i = 0
        var j = 0

        while i < a.count || j < b.count {
            var firstDigitDifference = 0

            while (i < a.count && !isDigit(a[i])) || (j < b.count && !isDigit(b[j])) {
                let left = order(i < a.count ? a[i] : nil)
                let right = order(j < b.count ? b[j] : nil)
                if left != right { return left < right ? -1 : 1 }
                i += 1
                j += 1
            }

            while i < a.count && a[i] == UInt8(ascii: "0") { i += 1 }
            while j < b.count && b[j] == UInt8(ascii: "0") { j += 1 }

            while i < a.count, j < b.count, isDigit(a[i]), isDigit(b[j]) {
                if firstDigitDifference == 0 {
                    firstDigitDifference = Int(a[i]) - Int(b[j])
                }
                i += 1
                j += 1
            }

            if i < a.count && isDigit(a[i]) { return 1 }
            if j < b.count && isDigit(b[j]) { return -1 }
            if firstDigitDifference != 0 { return firstDigitDifference < 0 ? -1 : 1 }
        }

        return 0
    }

    // MARK: - Display

    public var description: String { raw }
}

/// A version with a relation, as it appears in `Depends` and friends:
/// `(>= 1.2-3)`, `(= 4.0)`, `(<< 2.0)`.
public struct DebianVersionConstraint: Hashable, Sendable, CustomStringConvertible {

    public enum Relation: String, Hashable, Sendable, CaseIterable {
        case equal = "="
        case strictlyEarlier = "<<"
        case earlierOrEqual = "<="
        case laterOrEqual = ">="
        case strictlyLater = ">>"

        /// `dpkg` accepts the single-character forms in dependency fields and
        /// treats them as the strict/Tilm forms used here.
        init?(rawOperator: String) {
            switch rawOperator {
            case "=": self = .equal
            case "<<", "<": self = .strictlyEarlier
            case "<=": self = .earlierOrEqual
            case ">=": self = .laterOrEqual
            case ">>", ">": self = .strictlyLater
            default: return nil
            }
        }
    }

    public let relation: Relation
    public let version: DebianVersion

    public init(relation: Relation, version: DebianVersion) {
        self.relation = relation
        self.version = version
    }

    public func isSatisfied(by candidate: DebianVersion) -> Bool {
        let order = DebianVersion.compare(candidate, version)
        switch relation {
        case .equal: return order == 0
        case .strictlyEarlier: return order < 0
        case .earlierOrEqual: return order <= 0
        case .laterOrEqual: return order >= 0
        case .strictlyLater: return order > 0
        }
    }

    public var description: String { "(\(relation.rawValue) \(version))" }
}
