import Foundation

/// One thing that happened during a transaction. The UI renders these directly.
public enum TransactionEvent: Sendable {
    case stage(String)
    case downloading(package: String, received: Int64, total: Int64)
    case verifying(package: String)
    case removing(package: String)
    case unpacking(package: String)
    case configuring(package: String)
    /// Parsed dpkg output when a package/phase can be identified.
    case dpkgProgress(package: String?, status: String, percent: Double?)
    /// Raw output from dpkg, forwarded so a user can always see the truth.
    case output(String)
    case finished(TransactionReport)
    case failed(package: String?, message: String)
}

public struct TransactionReport: Sendable {
    public var installed: [String] = []
    public var upgraded: [String] = []
    public var downgraded: [String] = []
    public var reinstalled: [String] = []
    public var removed: [String] = []
    public var failures: [String: String] = [:]
    public var log: String = ""
    public var duration: TimeInterval = 0
    public var succeeded: Bool { failures.isEmpty }

    public var summary: String {
        if !succeeded {
            return "Failed: \(failures.count) step\(failures.count == 1 ? "" : "s") did not complete"
        }
        var parts: [String] = []
        if !installed.isEmpty { parts.append("installed \(installed.count)") }
        if !upgraded.isEmpty { parts.append("upgraded \(upgraded.count)") }
        if !downgraded.isEmpty { parts.append("downgraded \(downgraded.count)") }
        if !reinstalled.isEmpty { parts.append("reinstalled \(reinstalled.count)") }
        if !removed.isEmpty { parts.append("removed \(removed.count)") }
        return parts.isEmpty ? "Nothing to do" : parts.joined(separator: ", ").capitalizedFirst
    }
}

private extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}

/// Executes a plan.
///
/// Three rules shape this code:
///
/// 1. **Everything is verified before anything is installed.** Every archive is
///    downloaded and its control file compared against the record the index
///    advertised, so a repository cannot hand the device a different package from
///    the one the plan was calculated for.
/// 2. **dpkg is never lied to.** No `--force-*` beyond the conservative
///    `--force-confold`, because the resolver above is what is supposed to make
///    the transaction consistent.
/// 3. **Failure stops the transaction and says where.** Half a transaction is
///    recoverable (`dpkg --configure -a` finishes it) but continuing blindly after
///    a failed preinst is not.
private func parsedDpkgEvent(_ text: String) -> TransactionEvent? {
    for rawLine in text.split(whereSeparator: \.isNewline) {
        let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("Setting up ") {
            let package = line.dropFirst("Setting up ".count).split(separator: " ").first.map(String.init)
            return .dpkgProgress(package: package, status: "configuring", percent: nil)
        }
        if line.hasPrefix("Unpacking ") {
            let package = line.dropFirst("Unpacking ".count).split(separator: " ").first.map(String.init)
            return .dpkgProgress(package: package, status: "unpacking", percent: nil)
        }
        if line.hasPrefix("Removing ") || line.hasPrefix("Purging ") {
            let verb = line.hasPrefix("Removing ") ? "Removing " : "Purging "
            let package = line.dropFirst(verb.count).split(separator: " ").first.map(String.init)
            return .dpkgProgress(package: package, status: verb.trimmingCharacters(in: .whitespaces), percent: nil)
        }
        if line.hasPrefix("Processing triggers for ") {
            return .dpkgProgress(package: nil, status: line, percent: nil)
        }
    }
    return nil
}

public actor InstallEngine {

    private let environment: JailbreakEnvironment
    private let dpkg: DpkgClient
    private let repositoryClient: RepositoryClient

    public init(
        environment: JailbreakEnvironment,
        dpkg: DpkgClient? = nil,
        repositoryClient: RepositoryClient? = nil
    ) {
        self.environment = environment
        self.dpkg = dpkg ?? DpkgClient(environment: environment)
        self.repositoryClient = repositoryClient ?? RepositoryClient(environment: environment)
    }

    private func source(for record: PackageRecord, in sources: [RepositorySource]) -> RepositorySource? {
        guard let origin = record.origin else { return nil }
        return sources.first {
            $0.normalizedURL.caseInsensitiveCompare(origin.url) == .orderedSame
                && $0.suite == origin.suite
                && ($0.components.contains(origin.component) || $0.isFlat)
        }
    }

    /// Stable key for a concrete package instance. Package name alone is unsafe:
    /// Multi-Arch transactions may contain the same name for multiple architectures.
    public static func archiveKey(for record: PackageRecord) -> String {
        "\(record.name):\(record.architecture)=\(record.version.raw)"
    }

    /// Downloads and verifies every package in the plan, returning local paths.
    ///
    /// Split out from ``execute`` because the UI wants to show a queue that is
    /// ready to install before the user commits, and because a download that fails
    /// should cost nothing but a retry.
    public func prepare(
        _ plan: TransactionPlan,
        sources: [RepositorySource],
        progress: (@Sendable (TransactionEvent) -> Void)? = nil
    ) async throws -> [String: String] {
        var localPaths: [String: String] = [:]
        for record in plan.unpackSteps {
            if LocalPackageLoader.isLocalRecord(record) { continue }
            guard let source = source(for: record, in: sources) else {
                throw InstallError.noDownloadSource(record.name)
            }
            progress?(.stage("Downloading \(record.name) \(record.version.raw)"))
            let path = try await repositoryClient.fetchPackage(record, from: source) { received, total in
                progress?(.downloading(package: record.name, received: received, total: total))
            }
            progress?(.verifying(package: record.name))
            try verify(record: record, at: path)
            localPaths[Self.archiveKey(for: record)] = path
        }
        return localPaths
    }

    /// Checks that the archive on disk really is the package the plan asked for.
    ///
    /// The index is remote data; the archive is the thing that will actually run
    /// maintainer scripts as root. If `Package` or `Version` disagree, the plan was
    /// built on a lie and the transaction must not start.
    public func verify(record: PackageRecord, at path: String) throws {
        let archive = try DebArchive(path: path)
        let stanza = try archive.controlStanza()
        let name = stanza.string("Package") ?? ""
        let version = DebianVersion(stanza.string("Version") ?? "")
        guard name == record.name else {
            throw InstallError.archiveMismatch(path: path, expected: record.name, found: name)
        }
        guard DebianVersion.compare(version, record.version) == 0 else {
            throw InstallError.archiveVersionMismatch(
                package: record.name,
                expected: record.version.raw,
                found: version.raw
            )
        }
        // `all` is compatible with any architecture; anything else must match the
        // record the plan was computed for.
        if let architecture = stanza.string("Architecture"),
           architecture != "all",
           architecture != record.architecture {
            throw InstallError.archiveMismatch(
                path: path,
                expected: record.architecture,
                found: architecture
            )
        }
    }

    /// Runs the plan.
    ///
    /// `sources` supplies the repositories to download from; `localPaths` may be
    /// pre-populated by ``prepare`` to skip a download.
    @discardableResult
    public func execute(
        _ plan: TransactionPlan,
        sources: [RepositorySource],
        localPaths: [String: String] = [:],
        progress: (@Sendable (TransactionEvent) -> Void)? = nil
    ) async throws -> TransactionReport {
        guard environment.isUsable else {
            throw InstallError.noPackageManager(environment.layout.rawValue)
        }

        let start = Date()
        var report = TransactionReport()
        var log = ""

        func record(_ line: String) {
            log += line.hasSuffix("\n") ? line : line + "\n"
            progress?(.output(line))
        }

        // Pre-flight: refuse an impossible transaction before touching anything.
        if let free = environment.freeSpace() {
            let needed = Int64(plan.downloadSize) + plan.installedSize + (32 << 20)
            if free < needed {
                throw InstallError.notEnoughSpace(required: needed, available: free)
            }
        }

        record("Aurora transaction: \(plan.summary)")
        for warning in plan.warnings { record("warning: \(warning.message)") }

        // 1. Make sure every archive is present and is what we think it is.
        try Task.checkCancellation()
        var paths = localPaths
        for step in plan.steps {
            try Task.checkCancellation()
            guard case .unpack(let record_) = step else { continue }
            if paths[Self.archiveKey(for: record_)] == nil {
                if LocalPackageLoader.isLocalRecord(record_) {
                    // A local package is a file the caller already has; there is
                    // nothing to download, so being without it is a caller bug.
                    throw InstallError.localArchiveMissing(record_.name)
                }
                guard let source = source(for: record_, in: sources) else {
                    throw InstallError.noDownloadSource(record_.name)
                }
                progress?(.stage("Downloading \(record_.name)"))
                let path = try await repositoryClient.fetchPackage(record_, from: source) { received, total in
                    progress?(.downloading(package: record_.name, received: received, total: total))
                }
                paths[Self.archiveKey(for: record_)] = path
            }
            if let path = paths[Self.archiveKey(for: record_)] {
                progress?(.verifying(package: record_.name))
                try verify(record: record_, at: path)
                record("verified \(record_.name) \(record_.version.raw) (\((try? DebArchive(path: path).members.count) ?? 0) archive members)")
            }
        }

        // 2. Removals first: a conflicting package must be gone before its
        //    replacement unpacks. Cancellation is honored only between dpkg
        //    invocations; an active dpkg process is deliberately never killed
        //    halfway through a filesystem mutation.
        try Task.checkCancellation()
        for step in plan.steps {
            try Task.checkCancellation()
            guard case .remove(let package, let purge) = step else { continue }
            progress?(.removing(package: package.name))
            do {
                _ = try await runBlocking {
                    try self.dpkg.remove(package: package.qualifiedName, purge: purge) { chunk in
                        let text = String(decoding: chunk, as: UTF8.self)
                        progress?(.output(text))
                        if let event = parsedDpkgEvent(text) { progress?(event) }
                    }
                }
                report.removed.append(package.name)
                record("removed \(package.name)\(purge ? " (purged)" : "")")
            } catch {
                report.failures[package.name] = "\(error)"
                progress?(.failed(package: package.name, message: "\(error)"))
                report.log = log
                report.duration = Date().timeIntervalSince(start)
                return report
            }
        }

        // 3. Unpack every archive, then configure once. dpkg's own dependency
        //    ordering handles the configure pass, which is why the plan's order
        //    only has to be right for unpacking.
        try Task.checkCancellation()
        for step in plan.steps {
            try Task.checkCancellation()
            guard case .unpack(let record_) = step, let path = paths[Self.archiveKey(for: record_)] else { continue }
            progress?(.unpacking(package: record_.name))
            do {
                _ = try await runBlocking {
                    try self.dpkg.unpack(debAt: path) { chunk in
                        let text = String(decoding: chunk, as: UTF8.self)
                        progress?(.output(text))
                        if let event = parsedDpkgEvent(text) { progress?(event) }
                    }
                }
                switch true {
                case plan.upgraded.contains(where: { $0.instanceKey == record_.instanceKey }): report.upgraded.append(record_.qualifiedName)
                case plan.downgraded.contains(where: { $0.instanceKey == record_.instanceKey }): report.downgraded.append(record_.qualifiedName)
                case plan.reinstalled.contains(where: { $0.instanceKey == record_.instanceKey }): report.reinstalled.append(record_.qualifiedName)
                default: report.installed.append(record_.name)
                }
                record("unpacked \(record_.name) \(record_.version.raw)")
            } catch {
                report.failures[record_.name] = "\(error)"
                progress?(.failed(package: record_.name, message: "\(error)"))
                // Try to leave the device consistent before giving up.
                _ = try? await runBlocking { try self.dpkg.configurePending() }
                report.log = log
                report.duration = Date().timeIntervalSince(start)
                return report
            }
        }

        // 4. Configure. A failure here is recoverable and reported as such.
        //    Repair transactions consist of nothing but configure steps, so this
        //    cannot be gated on having unpacked something.
        let hasConfigureSteps = plan.steps.contains { step in
            if case .configure = step { return true }
            return false
        }
        try Task.checkCancellation()
        if hasConfigureSteps || !plan.unpackSteps.isEmpty {
            for record_ in plan.unpackSteps { progress?(.configuring(package: record_.name)) }
            do {
                _ = try await runBlocking {
                    try self.dpkg.configurePending { chunk in
                        let text = String(decoding: chunk, as: UTF8.self)
                        progress?(.output(text))
                        if let event = parsedDpkgEvent(text) { progress?(event) }
                    }
                }
                record("configured \(plan.unpackSteps.count) package(s)")
            } catch {
                for record_ in plan.unpackSteps { report.failures[record_.name] = "configure failed" }
                progress?(.failed(package: nil, message: "\(error)"))
                record("configuration failed; run 'dpkg --configure -a' to finish")
            }
        }

        report.log = log
        report.duration = Date().timeIntervalSince(start)
        progress?(.finished(report))
        return report
    }

    /// Runs blocking work (dpkg can take minutes) off the cooperative pool.
    private func runBlocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

public enum InstallError: Error, CustomStringConvertible {
    case noPackageManager(String)
    case noDownloadSource(String)
    case localArchiveMissing(String)
    case notEnoughSpace(required: Int64, available: Int64)
    case archiveMismatch(path: String, expected: String, found: String)
    case archiveVersionMismatch(package: String, expected: String, found: String)

    public var description: String {
        switch self {
        case .noPackageManager(let layout):
            return "Aurora cannot install anything: no dpkg was found (system detected as \(layout))"
        case .noDownloadSource(let name):
            return "\(name) has no repository to download from and no local archive was supplied"
        case .localArchiveMissing(let name):
            return "\(name) is a local package but its archive path was not provided"
        case .notEnoughSpace(let required, let available):
            return "not enough space: \(required / (1 << 20)) MB needed, \(available / (1 << 20)) MB free"
        case .archiveMismatch(let path, let expected, let found):
            return "\(path) is not the expected package: wanted \(expected), found \(found)"
        case .archiveVersionMismatch(let package, let expected, let found):
            return "\(package) on disk is \(found), the plan asked for \(expected)"
        }
    }
}
