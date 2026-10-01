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
    private var keysByName: [String: [String]]
    private var presentKeys: Set<String>
    private var brokenKeys: Set<String>

    public init(packages: [String: InstalledPackage] = [:]) {
        self.packages = packages
        self.keysByName = Self.makeNameIndex(packages)
        let status = Self.makeStatusIndexes(packages)
        self.presentKeys = status.present
        self.brokenKeys = status.broken
    }

    public init(parsing text: String) {
        var packages: [String: InstalledPackage] = [:]
        packages.reserveCapacity(512)
        ControlParser.forEachStanza(in: text) { stanza in
            guard !stanza.isEmpty else { return }
            let entry = InstalledPackage(stanza: stanza)
            guard !entry.name.isEmpty else { return }
            packages[entry.key] = entry
        }
        self.packages = packages
        self.keysByName = Self.makeNameIndex(packages)
        let status = Self.makeStatusIndexes(packages)
        self.presentKeys = status.present
        self.brokenKeys = status.broken
    }

    public init(contentsOf path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        self.init(parsing: String(decoding: data, as: UTF8.self))
    }

    private static func makeNameIndex(_ packages: [String: InstalledPackage]) -> [String: [String]] {
        var result: [String: [String]] = [:]
        result.reserveCapacity(packages.count)
        for (key, package) in packages {
            result[package.name, default: []].append(key)
        }
        return result
    }

    private static func makeStatusIndexes(
        _ packages: [String: InstalledPackage]
    ) -> (present: Set<String>, broken: Set<String>) {
        var present = Set<String>()
        var broken = Set<String>()
        present.reserveCapacity(packages.count)
        broken.reserveCapacity(max(8, packages.count / 16))
        for (key, package) in packages {
            let status = package.status
            guard !status.isRemoved else { continue }
            present.insert(key)
            if status.isBroken { broken.insert(key) }
        }
        return (present, broken)
    }

    private mutating func rebuildIndexes() {
        keysByName = Self.makeNameIndex(packages)
        let status = Self.makeStatusIndexes(packages)
        presentKeys = status.present
        brokenKeys = status.broken
    }


    public var count: Int { packages.count }

    public var all: [InstalledPackage] {
        packages.values.sorted { $0.name < $1.name }
    }

    /// The installed instance for a name and architecture.
    ///
    /// The key is ``InstalledPackage/instanceKey`` — a bare name for an
    /// architecture-independent package, `name:architecture` otherwise — so this
    /// has to try both spellings before falling back to "any instance of that
    /// name", which is what an `all` package needs.
    public func package(named name: String, architecture: String? = nil) -> InstalledPackage? {
        if let architecture, architecture != "all",
           let exact = packages["\(name):\(architecture)"] {
            return exact
        }
        if let plain = packages[name] { return plain }
        guard let keys = keysByName[name] else { return nil }

        if let architecture {
            for key in keys {
                guard let candidate = packages[key] else { continue }
                if candidate.architecture == architecture || candidate.architecture == "all" {
                    return candidate
                }
            }
        }
        for key in keys {
            if let candidate = packages[key] { return candidate }
        }
        return nil
    }

    /// The installed instance with that exact instance key (`name:arch`).
    public func package(instanceKey: String) -> InstalledPackage? {
        packages[instanceKey]
    }

    /// True when *any* instance of that name is installed and configured.
    public func isInstalled(_ name: String) -> Bool {
        package(named: name)?.status.isInstalled ?? false
    }

    /// Packages dpkg considers present, including half-installed ones — the
    /// resolver must reason about those, not only about the clean ones.
    public var present: [InstalledPackage] {
        presentKeys.compactMap { packages[$0] }
    }

    public var brokenPackages: [InstalledPackage] {
        brokenKeys.compactMap { packages[$0] }
    }

    // MARK: - Mutation

    public mutating func set(_ stanza: ControlStanza) {
        let entry = InstalledPackage(stanza: stanza)
        let isNew = packages[entry.key] == nil
        packages[entry.key] = entry
        if isNew {
            keysByName[entry.name, default: []].append(entry.key)
        }

        presentKeys.remove(entry.key)
        brokenKeys.remove(entry.key)
        let status = entry.status
        if !status.isRemoved {
            presentKeys.insert(entry.key)
            if status.isBroken { brokenKeys.insert(entry.key) }
        }
    }

    /// Marks a package as removed in the way dpkg does: `remove` keeps the
    /// conffiles and leaves a `config-files` entry, `purge` deletes the entry.
    public mutating func markRemoved(name: String, purge: Bool, architecture: String? = nil) {
        guard let entry = package(named: name, architecture: architecture) else { return }
        if purge {
            if let architecture {
                // A qualified purge removes only that concrete instance. Purging
                // every architecture of a Multi-Arch package corrupts the model.
                packages = packages.filter {
                    !($0.value.name == name && $0.value.architecture == architecture)
                }
            } else {
                packages = packages.filter { $0.value.name != name }
            }
            rebuildIndexes()
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
