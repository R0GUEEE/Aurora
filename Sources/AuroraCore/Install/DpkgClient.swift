import Foundation

public enum DpkgError: Error, CustomStringConvertible {
    case notAvailable
    case missingStatusFile(String)
    case commandFailed(command: String, status: Int32, output: String)
    case writeFailed(String, underlying: Error)

    public var description: String {
        switch self {
        case .notAvailable:
            return "dpkg was not found on this device — Aurora needs a jailbreak with dpkg installed"
        case .missingStatusFile(let path):
            return "the dpkg database is missing at \(path)"
        case .commandFailed(let command, let status, let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(command) failed (exit \(status)): \(trimmed.isEmpty ? "no output" : trimmed)"
        case .writeFailed(let path, let underlying):
            return "could not write \(path): \(underlying)"
        }
    }
}

/// Options that decide how `dpkg` is invoked.
public struct DpkgOptions: Sendable {
    /// Pass `--force-confold`: keep the installed configuration file and write the
    /// package's version as `.dpkg-new`. This is what apt does by default and it is
    /// the only safe choice for a non-interactive client.
    public var keepExistingConffiles: Bool
    /// Pass `--force-depends`. Off by default: Aurora resolves dependencies itself,
    /// and forcing dpkg hides resolver bugs behind a broken system.
    public var forceDepends: Bool
    /// Configure packages as they are unpacked instead of in a second pass.
    public var unpackAndConfigureTogether: Bool

    public init(
        keepExistingConffiles: Bool = true,
        forceDepends: Bool = false,
        unpackAndConfigureTogether: Bool = false
    ) {
        self.keepExistingConffiles = keepExistingConffiles
        self.forceDepends = forceDepends
        self.unpackAndConfigureTogether = unpackAndConfigureTogether
    }

    public static let `default` = DpkgOptions()
}

/// The only place Aurora invokes `dpkg`.
///
/// Everything privileged goes through here so that the environment a maintainer
/// script sees is decided in one place. That matters: a postinst that cannot find
/// `sh`, or that inherits the app's sandbox paths, behaves differently from the
/// same script run by apt.
public struct DpkgClient: Sendable {

    public let environment: JailbreakEnvironment
    public let options: DpkgOptions

    public init(environment: JailbreakEnvironment, options: DpkgOptions = .default) {
        self.environment = environment
        self.options = options
    }

    public var executable: String? {
        environment.dpkgPath ?? ProcessRunner.which("dpkg", searchPaths: environment.executableSearchPaths)
    }

    /// The environment handed to `dpkg` and, through it, to maintainer scripts.
    public var childEnvironment: [String: String] {
        var values: [String: String] = [:]
        values["PATH"] = environment.executableSearchPaths.joined(separator: ":") + ":/usr/sbin:/sbin"
        values["HOME"] = "/var/mobile"
        values["TMPDIR"] = NSTemporaryDirectory()
        values["LC_ALL"] = "C"
        values["LANG"] = "C"
        values["DEBIAN_FRONTEND"] = "noninteractive"
        values["TERM"] = "dumb"
        return values
    }

    @discardableResult
    public func run(
        arguments: [String],
        onOutput: ((Data) -> Void)? = nil
    ) throws -> ProcessResult {
        guard let executable else { throw DpkgError.notAvailable }
        return try ProcessRunner.run(
            executable: executable,
            arguments: arguments,
            environment: childEnvironment,
            onOutput: onOutput
        )
    }

    // MARK: - Querying

    /// Fetches output and fails loudly on a non-zero exit.
    private func runChecked(_ arguments: [String], onOutput: ((Data) -> Void)? = nil) throws -> ProcessResult {
        let result = try run(arguments: arguments, onOutput: onOutput)
        guard result.succeeded else {
            throw DpkgError.commandFailed(
                command: "dpkg \(arguments.joined(separator: " "))",
                status: result.status,
                output: result.combinedOutput
            )
        }
        return result
    }

    public func printArchitecture() -> String? {
        guard let result = try? run(arguments: ["--print-architecture"]), result.succeeded else { return nil }
        let value = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    public func loadDatabase() throws -> InstalledPackageDatabase {
        let path = environment.statusFilePath
        guard FileManager.default.fileExists(atPath: path) else {
            throw DpkgError.missingStatusFile(path)
        }
        return try InstalledPackageDatabase(contentsOf: path)
    }

    // MARK: - Mutating

    /// `dpkg --unpack`: writes files and runs the preinst, but does not configure.
    @discardableResult
    public func unpack(debAt path: String, onOutput: ((Data) -> Void)? = nil) throws -> ProcessResult {
        var arguments = options.unpackAndConfigureTogether ? ["--install"] : ["--unpack"]
        if options.forceDepends { arguments.append("--force-depends") }
        if options.keepExistingConffiles { arguments.append("--force-confold") }
        arguments.append(path)
        return try runChecked(arguments, onOutput: onOutput)
    }

    /// `dpkg --install`: unpack and configure in one go.
    @discardableResult
    public func install(debAt path: String, onOutput: ((Data) -> Void)? = nil) throws -> ProcessResult {
        var arguments = ["--install"]
        if options.forceDepends { arguments.append("--force-depends") }
        if options.keepExistingConffiles { arguments.append("--force-confold") }
        arguments.append(path)
        return try runChecked(arguments, onOutput: onOutput)
    }

    /// Configures everything left unpacked. Run after a batch of unpacks so that
    /// packages that depend on each other are configured in dependency order.
    @discardableResult
    public func configurePending(onOutput: ((Data) -> Void)? = nil) throws -> ProcessResult {
        try runChecked(["--configure", "-a"], onOutput: onOutput)
    }

    @discardableResult
    public func configure(package: String, onOutput: ((Data) -> Void)? = nil) throws -> ProcessResult {
        try runChecked(["configure", package], onOutput: onOutput)
    }

    @discardableResult
    public func remove(package: String, purge: Bool = false, onOutput: ((Data) -> Void)? = nil) throws -> ProcessResult {
        var arguments = [purge ? "--purge" : "--remove"]
        if options.forceDepends { arguments.append("--force-depends") }
        arguments.append(package)
        return try runChecked(arguments, onOutput: onOutput)
    }

    // MARK: - Writing the database

    /// Writes the status file atomically.
    ///
    /// Never truncate the real file in place: an interrupted write there leaves a
    /// device that cannot install anything. Write beside it, then rename.
    public func writeDatabase(_ database: InstalledPackageDatabase, keepingBackup: Bool = true) throws {
        let path = environment.statusFilePath
        do {
            if keepingBackup, FileManager.default.fileExists(atPath: path) {
                let backup = path + ".aurora-backup"
                try? FileManager.default.removeItem(atPath: backup)
                try? FileManager.default.copyItem(atPath: path, toPath: backup)
            }
            let temporary = path + ".aurora-new"
            try Data(database.serialized().utf8).write(to: URL(fileURLWithPath: temporary), options: .atomic)
            try? FileManager.default.removeItem(atPath: path)
            try FileManager.default.moveItem(atPath: temporary, toPath: path)
        } catch {
            throw DpkgError.writeFailed(path, underlying: error)
        }
    }
}
