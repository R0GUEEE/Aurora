import Foundation

/// The user's standing decisions about what may be installed and from where.
///
/// Lives in the index layer because it governs *candidate selection*: both the
/// index lookup and the resolver must agree about which record is the right one,
/// and two copies of that rule would eventually disagree.
///
/// Two things live here that apt splits across `preferences` and `dpkg --set-selections`:
///
/// * **Repository priority** — which source wins when two of them carry the same
///   package. This is what makes "this repository's builds are the ones I want"
///   expressible without removing other repositories.
/// * **Pins** — per-package decisions: never install it, never let it be upgraded
///   on its own, or hold it at exactly one version.
///
/// The default value changes nothing: every source has the same priority and no
/// package is pinned, so candidate selection falls back to "newest version wins",
/// which is what a user with one repository expects.
public struct PackagePolicy: Sendable, Hashable, Codable {

    /// Per-package decision.
    public enum Pin: Sendable, Hashable, Codable {
        /// Installable and upgradable, but never upgraded *automatically*.
        case hold
        /// Never selected, not even for an explicit install.
        case forbid
        /// Only this exact version may be chosen.
        case version(String)

        public var label: String {
            switch self {
            case .hold: return "held"
            case .forbid: return "forbidden"
            case .version(let value): return "pinned to \(value)"
            }
        }
    }

    /// apt's default: everything is equally preferred.
    public static let defaultPriority = 500

    /// Repository root URL → priority. Higher wins. A priority below
    /// ``defaultPriority`` still works as a candidate, it simply loses ties.
    public var sourcePriorities: [String: Int]
    /// Package name → pin.
    public var pins: [String: Pin]

    public init(sourcePriorities: [String: Int] = [:], pins: [String: Pin] = [:]) {
        self.sourcePriorities = sourcePriorities
        self.pins = pins
    }

    public static let `default` = PackagePolicy()

    public var isEmpty: Bool { sourcePriorities.isEmpty && pins.isEmpty }

    // MARK: - Sources

    public func priority(forSource url: String) -> Int {
        var key = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while key.hasSuffix("/") { key.removeLast() }
        return sourcePriorities[key] ?? Self.defaultPriority
    }

    public mutating func setPriority(_ priority: Int, forSource url: String) {
        var key = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while key.hasSuffix("/") { key.removeLast() }
        if priority == Self.defaultPriority {
            sourcePriorities.removeValue(forKey: key)
        } else {
            sourcePriorities[key] = priority
        }
    }

    /// Priority of the repository a record came from. Records with no origin
    /// (tests, local files) get the default.
    public func priority(of record: PackageRecord) -> Int {
        guard let url = record.origin?.url else { return Self.defaultPriority }
        return priority(forSource: url)
    }

    // MARK: - Pins

    public func pin(for name: String) -> Pin? { pins[name] }

    /// Whether a name may be selected at all: everything is allowed unless a pin
    /// forbids it. An unmentioned package is allowed, not "pinned to allow".
    public func allows(_ name: String) -> Bool {
        if case .forbid? = pins[name] { return false }
        return true
    }

    /// Whether this name has any pin at all.
    public func hasPin(_ name: String) -> Bool { pins[name] != nil }

    /// The only version that may be selected for this name, when pinned.
    public func requiredVersion(for name: String) -> String? {
        if case .version(let value) = pins[name] { return value }
        return nil
    }

    /// Held packages are installable; they are just never upgraded on their own.
    public func isHeld(_ name: String) -> Bool {
        if case .hold = pins[name] { return true }
        return false
    }

    public mutating func pin(_ pin: Pin?, for name: String) {
        if let pin {
            pins[name] = pin
        } else {
            pins.removeValue(forKey: name)
        }
    }

    // MARK: - Persistence

    public struct Store: Sendable {
        public let path: String

        public init(path: String? = nil) {
            self.path = path ?? Self.defaultPath()
        }

        public static func defaultPath() -> String {
            #if os(macOS)
            let base = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Aurora")
            #else
            let candidates = [
                "/var/mobile/Library/Application Support/Aurora",
                "/var/mobile/Library/Preferences/Aurora",
            ]
            let base = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
            #endif
            return (base as NSString).appendingPathComponent("policy.json")
        }

        /// A corrupt policy file must not stop the package manager from working:
        /// it reads as the default and reports why.
        public func load() -> (policy: PackagePolicy, failure: String?) {
            guard FileManager.default.fileExists(atPath: path) else {
                return (.default, nil)
            }
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                if data.isEmpty { return (.default, nil) }
                return (try JSONDecoder().decode(PackagePolicy.self, from: data), nil)
            } catch {
                return (.default, "\(path) could not be read (\(error)); using default preferences")
            }
        }

        public func save(_ policy: PackagePolicy) throws {
            let directory = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(policy).write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
