import Foundation

/// What a health check found.
///
/// A package manager that breaks a device is worse than one that does less, so
/// Aurora can describe exactly what is wrong — including the states dpkg itself
/// reports (`half-configured`, `triggers-pending`, `config-files`) rather than a
/// vaguer "something went wrong".
public struct DiagnosticsReport: Sendable {

    public struct MissingDependency: Sendable, Hashable {
        public let package: String
        public let architecture: String
        public let clause: String
        /// Whether any enabled repository could supply it. A missing dependency
        /// that is available is a one-tap fix; one that is not is a dead package.
        public let satisfiableFromRepositories: Bool

        public var description: String {
            "\(package) [\(architecture)] needs \(clause)"
                + (satisfiableFromRepositories ? "" : " — not offered by any repository")
        }
    }

    public let layout: String
    public let jailbroken: Bool
    public let dpkgPath: String?
    public let statusFilePath: String
    public let statusFilePresent: Bool
    public let installedCount: Int
    public let presentCount: Int
    /// Present but in a state dpkg considers broken.
    public let broken: [InstalledPackage]
    /// Unpacked but never configured — the classic half-finished transaction.
    public let pendingConfiguration: [InstalledPackage]
    /// Removed with `dpkg --remove` rather than purged: configuration files remain.
    public let obsoleteConfiguration: [InstalledPackage]
    public let missingDependencies: [MissingDependency]
    public let packageCacheBytes: Int64
    public let indexCacheBytes: Int64
    public let statusBackupPresent: Bool
    public let freeSpace: Int64?
    public let notes: [String]

    /// The two states that mean "dpkg is stuck". Missing dependencies are reported
    /// separately: jailbreaks accumulate those and they are usually not the
    /// device's current problem.
    public var isHealthy: Bool {
        broken.isEmpty && pendingConfiguration.isEmpty
    }

    public var fixableMissingDependencies: [MissingDependency] {
        missingDependencies.filter(\.satisfiableFromRepositories)
    }

    public var summary: String {
        if !jailbroken { return "No jailbreak detected" }
        if dpkgPath == nil { return "No dpkg found" }
        if isHealthy && missingDependencies.isEmpty { return "No problems found" }
        var parts: [String] = []
        if !broken.isEmpty { parts.append("\(broken.count) broken") }
        if !pendingConfiguration.isEmpty { parts.append("\(pendingConfiguration.count) waiting to be configured") }
        if !missingDependencies.isEmpty { parts.append("\(missingDependencies.count) unsatisfied dependencies") }
        return parts.joined(separator: ", ")
    }
}

/// Inspects the device without changing it, and can turn what it finds into a
/// repair transaction.
public struct Diagnostics: Sendable {

    public let environment: JailbreakEnvironment
    public let dpkg: DpkgClient

    public init(environment: JailbreakEnvironment, dpkg: DpkgClient? = nil) {
        self.environment = environment
        self.dpkg = dpkg ?? DpkgClient(environment: environment)
    }

    public func run(
        available: PackageIndex = PackageIndex(),
        policy: DependencyResolver.Policy? = nil
    ) -> DiagnosticsReport {
        let resolved = policy ?? DependencyResolver.Policy(
            architecture: environment.architecture,
            allowedArchitectures: Set(environment.compatibleArchitectures)
        )

        var notes: [String] = []
        let statusPresent = FileManager.default.fileExists(atPath: environment.statusFilePath)

        var database = InstalledPackageDatabase()
        if statusPresent {
            do {
                database = try InstalledPackageDatabase(contentsOf: environment.statusFilePath)
            } catch {
                notes.append("the package database could not be read: \(error)")
            }
        } else if environment.layout.isJailbroken {
            notes.append("the dpkg database is missing at \(environment.statusFilePath)")
        }

        let broken = database.present.filter { $0.status.isBroken }
        let pending = database.present.filter { $0.status.needsConfigure }
        let obsolete = database.all.filter { $0.status.isRemoved }

        var missing: [DiagnosticsReport.MissingDependency] = []
        let installedRecords = database.present.map(\.record)
        for entry in database.present {
            let clauses = entry.record.relations.preDepends.clauses + entry.record.relations.depends.clauses
            for clause in clauses {
                let satisfiedLocally = resolved.satisfier.satisfier(
                    of: clause,
                    in: installedRecords,
                    requestedArchitecture: entry.architecture,
                    excluding: nil
                ) != nil
                guard !satisfiedLocally else { continue }
                let fixable = !available.isEmpty && clause.alternatives.contains { term in
                    !available.rankedMatches(
                        for: term,
                        architecture: resolved.architecture,
                        requestedArchitecture: entry.architecture,
                        allowedArchitectures: resolved.allowedArchitectures,
                        policy: resolved.packagePolicy
                    ).isEmpty
                }
                missing.append(DiagnosticsReport.MissingDependency(
                    package: entry.name,
                    architecture: entry.architecture,
                    clause: clause.description,
                    satisfiableFromRepositories: fixable
                ))
            }
        }

        let backup = environment.statusFilePath + ".aurora-backup"
        if FileManager.default.fileExists(atPath: backup) {
            notes.append("a backup of the package database exists at \(backup) — a previous transaction did not finish")
        }
        if !environment.layout.isJailbroken {
            notes.append("this device does not look jailbroken, so nothing can be installed")
        }

        return DiagnosticsReport(
            layout: environment.layout.rawValue,
            jailbroken: environment.layout.isJailbroken,
            dpkgPath: environment.dpkgPath,
            statusFilePath: environment.statusFilePath,
            statusFilePresent: statusPresent,
            installedCount: database.count,
            presentCount: database.present.count,
            broken: broken,
            pendingConfiguration: pending,
            obsoleteConfiguration: obsolete,
            missingDependencies: missing,
            packageCacheBytes: PackageCache(environment: environment).totalBytes(),
            indexCacheBytes: Self.directorySize(at: environment.cacheDirectory + "/indexes"),
            statusBackupPresent: FileManager.default.fileExists(atPath: backup),
            freeSpace: environment.freeSpace(),
            notes: notes
        )
    }

    /// A plan that fixes what `run()` found.
    ///
    /// Only the two states Aurora can repair without guessing are included:
    /// configuring what is unpacked, and (on request) purging configuration files
    /// that belong to nothing. Missing dependencies are deliberately *not* invented
    /// here — the user decides whether to install something.
    public func repairPlan(
        for report: DiagnosticsReport,
        purgeObsoleteConfiguration: Bool = false
    ) -> TransactionPlan {
        var steps: [TransactionPlan.Step] = []
        var removed: [(package: InstalledPackage, purge: Bool)] = []

        if purgeObsoleteConfiguration {
            for entry in report.obsoleteConfiguration {
                steps.append(.remove(entry, purge: true))
                removed.append((package: entry, purge: true))
            }
        }
        for entry in report.pendingConfiguration {
            steps.append(.configure(entry.instanceKey))
        }

        return TransactionPlan(
            steps: steps,
            installed: [],
            upgraded: [],
            downgraded: [],
            reinstalled: [],
            removed: removed,
            dependencies: [],
            warnings: [],
            downloadSize: 0,
            // Purging configuration files reclaims a little; configuring changes
            // nothing on disk.
            installedSize: -removed.reduce(Int64(0)) { $0 + Int64(($1.package.record.installedSize ?? 0) * 1024) }
        )
    }

    /// Recursive size of a directory, used for the index cache.
    public static func directorySize(at path: String) -> Int64 {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        for case let name as String in enumerator {
            let full = (path as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: full, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            total += ((try? manager.attributesOfItem(atPath: full))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        return total
    }
}
