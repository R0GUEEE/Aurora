import Foundation

/// One entry of the dpkg database (`/var/lib/dpkg/status`).
public struct InstalledPackage: Hashable, Sendable {

    /// dpkg's three status columns: desired action, error flag, current state.
    public struct Status: Hashable, Sendable {
        public var want: String
        public var flag: String
        public var state: String

        public init(want: String = "install", flag: String = "ok", state: String = "installed") {
            self.want = want
            self.flag = flag
            self.state = state
        }

        public init(parsing text: String) {
            let parts = text.split(separator: " ").map(String.init)
            self.want = parts.count > 0 ? parts[0] : "install"
            self.flag = parts.count > 1 ? parts[1] : "ok"
            self.state = parts.count > 2 ? parts[2] : "installed"
        }

        public var serialized: String { "\(want) \(flag) \(state)" }

        public var isInstalled: Bool { state == "installed" }
        /// `config-files` is what dpkg leaves after a remove without purge.
        public var isRemoved: Bool { want == "deinstall" || state == "config-files" || state == "not-installed" }
        public var isBroken: Bool { flag != "ok" || ["half-installed", "half-configured", "unpacked", "triggers-awaited", "triggers-pending"].contains(state) }
        public var needsConfigure: Bool { state == "unpacked" || state == "half-configured" }
    }

    public var stanza: ControlStanza
    public let key: String

    public init(stanza: ControlStanza) {
        self.stanza = stanza
        self.key = Self.key(for: stanza)
    }

    /// dpkg distinguishes a native architecture instance from a foreign one, so
    /// a multi-arch package can be installed twice under different keys.
    public static func key(for stanza: ControlStanza) -> String {
        let name = stanza.string("Package") ?? ""
        let architecture = stanza.string("Architecture") ?? "all"
        if architecture == "all" || architecture.isEmpty { return name }
        return "\(name):\(architecture)"
    }

    public var name: String { stanza.string("Package") ?? "" }
    public var architecture: String { stanza.string("Architecture") ?? "all" }

    /// Matches ``PackageRecord/instanceKey``, so an installed package and its
    /// candidate can be lined up without guessing about architecture.
    public var instanceKey: String {
        architecture == "all" ? name : "\(name):\(architecture)"
    }
    public var version: DebianVersion { DebianVersion(stanza.string("Version") ?? "0") }
    public var status: Status { Status(parsing: stanza.string("Status") ?? "install ok installed") }

    /// A repository-shaped view, so the resolver can treat installed packages and
    /// candidates uniformly.
    public var record: PackageRecord { PackageRecord(stanza: stanza) }

    public var description: String { "\(name) \(version.raw) [\(status.serialized)]" }
}

/// The installed-package database, parsed from the dpkg status file.
///
/// Aurora reads it, hands it to the resolver, and writes it back after a
/// transaction. Unknown fields are preserved (see ``ControlStanza``) because
/// dpkg and maintainer scripts depend on them.
public struct InstalledPackageDatabase: Sendable {

    public private(set) var packages: [String: InstalledPackage]

    public init(packages: [String: InstalledPackage] = [:]) {
        self.packages = packages
    }

    public init(parsing text: String) {
        var packages: [String: InstalledPackage] = [:]
        for stanza in ControlParser.parse(text) where !stanza.isEmpty {
            let entry = InstalledPackage(stanza: stanza)
            guard !entry.name.isEmpty else { continue }
            packages[entry.key] = entry
        }
        self.packages = packages
    }

    public init(contentsOf path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        self.init(parsing: String(decoding: data, as: UTF8.self))
    }

    public var count: Int { packages.count }

    public var all: [InstalledPackage] {
        packages.values.sorted { $0.name < $1.name }
    }

    public func package(named name: String, architecture: String? = nil) -> InstalledPackage? {
        if let architecture, architecture != "all" {
            if let exact = packages["\(name):\(architecture)"] { return exact }
        }
        return packages[name] ?? packages.first(where: { $0.value.name == name })?.value
    }

    /// The installed instance with that exact instance key (`name:arch`).
    public func package(instanceKey: String) -> InstalledPackage? {
        packages[instanceKey] ?? packages.values.first { $0.instanceKey == instanceKey }
    }

    /// True when *any* instance of that name is installed and configured.
    public func isInstalled(_ name: String) -> Bool {
        package(named: name)?.status.isInstalled ?? false
    }

    /// Packages dpkg considers present, including half-installed ones — the
    /// resolver must reason about those, not only about the clean ones.
    public var present: [InstalledPackage] {
        packages.values.filter { !$0.status.isRemoved }
    }

    public var brokenPackages: [InstalledPackage] {
        present.filter { $0.status.isBroken }
    }

    // MARK: - Mutation

    public mutating func set(_ stanza: ControlStanza) {
        let entry = InstalledPackage(stanza: stanza)
        packages[entry.key] = entry
    }

    /// Marks a package as removed in the way dpkg does: `remove` keeps the
    /// conffiles and leaves a `config-files` entry, `purge` deletes the entry.
    public mutating func markRemoved(name: String, purge: Bool, architecture: String? = nil) {
        guard let entry = package(named: name, architecture: architecture) else { return }
        if purge {
            // Remove every instance of that name, not just the first.
            packages = packages.filter { $0.value.name != name }
        } else {
            var stanza = entry.stanza
            stanza["Status"] = "deinstall ok config-files"
            set(stanza)
        }
    }

    public func serialized() -> String {
        // dpkg keeps the file sorted by package name; matching that makes diffs
        // of the file readable and keeps external tools happy.
        all.map { $0.stanza.serialized }.joined()
    }
}
