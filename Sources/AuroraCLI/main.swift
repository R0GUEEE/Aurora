import Foundation
import AuroraCore

/// `aurora` — the command-line front end.
///
/// It exists for two reasons: it is the fastest way to check what the engine
/// actually does on a device (`aurora plan <package>` prints the transaction
/// without touching anything), and it is what CI runs end to end, because a
/// library with no executable path is a library nobody has ever run.

let auroraVersion = "1.0.0"

// MARK: - Small helpers

func write(_ text: String, to stream: FileHandle = .standardOutput) {
    guard let data = text.data(using: .utf8) else { return }
    stream.write(data)
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    write("aurora: \(message)\n", to: .standardError)
    exit(code)
}

func usage() -> String {
    """
    aurora \(auroraVersion) — package manager for jailbroken iOS

    USAGE
      aurora <command> [options]

    COMMANDS
      env                      Show the detected jailbreak layout and tools
      status                   Show the installed package database
      sources list             List configured repositories
      sources add <url> [--name N] [--suite S] [--component C]
      sources remove <url>
      sources enable|disable <url>
      refresh [--only <url>]   Fetch and cache repository indexes
      search <query>           Search every available package
      show <package>           Details, versions and dependencies
      plan install|remove <pkg>...
      plan upgrade
      apply install|remove <pkg>... [--purge] [--dry-run]
      deb <path.deb>           Inspect a package archive
      version | help

    OPTIONS
      --architecture <arch>    Override the dpkg architecture
      --allow-downgrade        Permit a version regression
      --recommends             Install recommended packages too
      --json                   Machine-readable output
    """
}

/// Bridges an async engine call into this synchronous program.
///
/// The engine is deliberately async (the UI needs it), and top-level code in a
/// command-line tool is much easier to keep synchronous, so the two meet here.
final class UncheckedBox<T>: @unchecked Sendable {
    var value: T?
    var failure: Error?
}

func sync<T>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let box = UncheckedBox<T>()
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.value = try await work() } catch { box.failure = error }
        semaphore.signal()
    }
    semaphore.wait()
    if let failure = box.failure { throw failure }
    guard let value = box.value else { throw CLIError.noResult }
    return value
}

enum CLIError: Error, CustomStringConvertible {
    case noResult
    case missingArgument(String)
    case notFound(String)

    var description: String {
        switch self {
        case .noResult: return "the operation produced no result"
        case .missingArgument(let name): return "missing argument: \(name)"
        case .notFound(let what): return "not found: \(what)"
        }
    }
}

func formatBytes(_ bytes: Int64) -> String {
    let units = ["B", "kB", "MB", "GB"]
    var value = Double(bytes)
    var index = 0
    while value >= 1024, index < units.count - 1 {
        value /= 1024
        index += 1
    }
    return index == 0 ? "\(Int(value)) B" : String(format: "%.1f %@", value, units[index])
}

// MARK: - Options

struct Options {
    var flags: Set<String> = []
    var values: [String: String] = [:]
    var positional: [String] = []

    init(_ arguments: [String], valueFlags: Set<String>) {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument.hasPrefix("--") {
                let name = String(argument.dropFirst(2))
                if valueFlags.contains(name), index + 1 < arguments.count {
                    values[name] = arguments[index + 1]
                    index += 2
                    continue
                }
                flags.insert(name)
            } else if argument.hasPrefix("-"), argument.count == 2 {
                flags.insert(String(argument.dropFirst()))
            } else {
                positional.append(argument)
            }
            index += 1
        }
    }

    func has(_ flag: String) -> Bool { flags.contains(flag) }
}

// MARK: - Shared context

let environment = JailbreakEnvironment.detect()
let store = SourceStore()

func architecture(_ options: Options) -> String {
    options.values["architecture"] ?? environment.architecture
}

func resolverPolicy(_ options: Options) -> DependencyResolver.Policy {
    DependencyResolver.Policy(
        architecture: architecture(options),
        installRecommends: options.has("recommends"),
        allowDowngrades: options.has("allow-downgrade")
    )
}

/// Refreshes every enabled source and merges the result into one pool.
@discardableResult
func loadIndex(
    only sourceURL: String? = nil,
    quiet: Bool = false,
    report: ((String) -> Void)? = nil
) throws -> (index: PackageIndex, refreshes: [RepositoryRefresh], warnings: [String]) {
    let list = store.load().list
    let sources = list.enabled.filter { source in
        guard let sourceURL else { return true }
        return source.normalizedURL == sourceURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            || source.normalizedURL.contains(sourceURL)
    }
    guard !sources.isEmpty else { throw CLIError.notFound("no enabled repository") }

    let client = RepositoryClient(environment: environment)
    var index = PackageIndex()
    var refreshes: [RepositoryRefresh] = []
    var warnings: [String] = []

    for source in sources {
        do {
            let refresh = try sync { try await client.refresh(source) }
            refreshes.append(refresh)
            index.merge(refresh.index)
            warnings.append(contentsOf: refresh.warnings.map { "\(source.name): \($0)" })
            if !quiet {
                let line = "\(source.name): \(refresh.records.count) packages, \(refresh.signature.shortDescription), \(refresh.release == nil ? "no Release" : "Release ok")"
                if let report { report(line) } else { write(line + "\n") }
            }
        } catch {
            let line = "\(source.name): \(error)"
            warnings.append(line)
            if !quiet { if let report { report(line) } else { write(line + "\n", to: .standardError) } }
        }
    }
    guard !index.isEmpty else { throw CLIError.notFound("no repository could be read") }
    return (index, refreshes, warnings)
}

func installedDatabase() -> InstalledPackageDatabase {
    (try? InstalledPackageDatabase(contentsOf: environment.statusFilePath)) ?? InstalledPackageDatabase()
}

/// Parses `install foo bar` / `remove baz` into a queue.
func queue(from arguments: [String], options: Options) throws -> PackageQueue {
    guard let verb = arguments.first else { throw CLIError.missingArgument("install|remove") }
    let names = Array(arguments.dropFirst())
    guard !names.isEmpty else { throw CLIError.missingArgument("package name") }

    var queue = PackageQueue()
    switch verb {
    case "install", "reinstall", "upgrade":
        let (index, _, _) = try loadIndex(quiet: true)
        for name in names {
            guard let record = index.bestMatch(for: DependencyTerm(name: name), architecture: architecture(options)) else {
                throw CLIError.notFound(name)
            }
            switch verb {
            case "reinstall": queue.stage(.reinstall(record))
            case "upgrade": queue.stage(.upgrade(record))
            default: queue.stage(.install(record))
            }
        }
    case "remove", "purge":
        for name in names {
            queue.stage(.remove(name: name, purge: verb == "purge" || options.has("purge")))
        }
    default:
        throw CLIError.notFound("unknown verb \(verb)")
    }
    return queue
}

// MARK: - Commands

func commandEnvironment(_ options: Options) {
    if options.has("json") {
        let payload: [String: Any] = [
            "layout": environment.layout.rawValue,
            "root": environment.root,
            "architecture": environment.architecture,
            "dpkg": environment.dpkgPath ?? "",
            "status_file": environment.statusFilePath,
            "usable": environment.isUsable,
            "free_space": environment.freeSpace() ?? 0,
        ]
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
        write(String(decoding: data ?? Data(), as: UTF8.self) + "\n")
        return
    }
    write("layout:       \(environment.layout.rawValue)\n")
    write("root:         \(environment.root)\n")
    write("architecture: \(environment.architecture)\n")
    write("dpkg:         \(environment.dpkgPath ?? "not found")\n")
    write("status file:  \(environment.statusFilePath)\n")
    if let free = environment.freeSpace() { write("free space:   \(formatBytes(free))\n") }
    write("sources file: \(store.path)\n")
}

func commandStatus(_ options: Options) throws {
    let database = installedDatabase()
    write("\(database.count) packages recorded, \(database.present.count) present\n")
    if !database.brokenPackages.isEmpty {
        write("\nbroken:\n")
        for entry in database.brokenPackages {
            write("  \(entry.name) \(entry.version.raw) [\(entry.status.serialized)]\n")
        }
    }
    if options.has("list") {
        write("\n")
        for entry in database.all {
            write("  \(entry.name.padding(toLength: 28, withPad: " ", startingAt: 0)) \(entry.version.raw)\n")
        }
    }
}

func commandSources(_ arguments: [String]) throws {
    let list = store.load().list
    guard let verb = arguments.first, verb != "list" else {
        for source in list.sources {
            let markers = [source.isEnabled ? "enabled" : "disabled", source.isFlat ? "flat" : "dists"]
            write("\(source.name)\n")
            write("  url:   \(source.normalizedURL)\n")
            write("  suite: \(source.suite)  (\(markers.joined(separator: ", ")))\n")
            if let date = source.lastRefreshed { write("  seen:  \(date)\n") }
        }
        return
    }

    var working = list
    switch verb {
    case "add":
        let options = Options(Array(arguments.dropFirst()), valueFlags: ["name", "suite", "component"])
        guard let url = options.positional.first else { throw CLIError.missingArgument("url") }
        let source = RepositorySource(
            name: options.values["name"] ?? URL(string: url)?.host ?? url,
            url: url,
            suite: options.values["suite"] ?? (options.has("dists") ? "stable" : "./"),
            components: options.values["component"].map { [$0] } ?? ["main"]
        )
        guard source.isValid else { throw RepositoryError.invalidURL(url) }
        try working.add(source)
        write("added \(source.name) (\(source.normalizedURL))\n")
    case "remove":
        guard let url = arguments.dropFirst().first else { throw CLIError.missingArgument("url") }
        let before = working.sources.count
        working.sources.removeAll { $0.normalizedURL.contains(url) }
        guard working.sources.count < before else { throw CLIError.notFound(url) }
        write("removed \(before - working.sources.count) source(s)\n")
    case "enable", "disable":
        guard let url = arguments.dropFirst().first else { throw CLIError.missingArgument("url") }
        var changed = 0
        for index in working.sources.indices where working.sources[index].normalizedURL.contains(url) {
            working.sources[index].isEnabled = (verb == "enable")
            changed += 1
        }
        guard changed > 0 else { throw CLIError.notFound(url) }
        write("\(verb)d \(changed) source(s)\n")
    default:
        throw CLIError.notFound("unknown sources verb \(verb)")
    }
    try store.save(working)
}

func commandRefresh(_ options: Options) throws {
    let only = options.values["only"]
    let result = try loadIndex(only: only)
    var total = 0
    for refresh in result.refreshes { total += refresh.records.count }
    write("\(result.refreshes.count) source(s), \(total) package records\n")
    for warning in result.warnings { write("warning: \(warning)\n", to: .standardError) }
}

func commandSearch(_ arguments: [String], options: Options) throws {
    guard let query = arguments.first else { throw CLIError.missingArgument("query") }
    let (index, _, _) = try loadIndex(quiet: true)
    let results = index.search(query, limit: 40)
    guard !results.isEmpty else {
        write("no package matches \(query)\n")
        return
    }
    for record in results {
        write("\(record.name.padding(toLength: 26, withPad: " ", startingAt: 0)) \(record.version.raw.padding(toLength: 14, withPad: " ", startingAt: 0)) \(record.section)\n")
        if !record.synopsis.isEmpty { write("    \(record.synopsis)\n") }
    }
    write("\n\(results.count) result(s)\n")
}

func commandShow(_ arguments: [String], options: Options) throws {
    guard let name = arguments.first else { throw CLIError.missingArgument("package") }
    let (index, _, _) = try loadIndex(quiet: true)
    let candidates = index.candidates(named: name)
    guard !candidates.isEmpty else { throw CLIError.notFound(name) }

    for record in candidates {
        write("\(record.name) \(record.version.raw) [\(record.architecture)]\n")
        write("  section:   \(record.section)\n")
        write("  priority:  \(record.priority)\n")
        if !record.maintainer.isEmpty { write("  maintainer:\(record.maintainer)\n") }
        if let size = record.downloadSize { write("  download:  \(formatBytes(Int64(size)))\n") }
        if let size = record.installedSize { write("  installed: \(formatBytes(Int64(size) * 1024))\n") }
        if let origin = record.origin { write("  source:    \(origin)\n") }
        if !record.relations.depends.isEmpty { write("  depends:   \(record.relations.depends)\n") }
        if !record.relations.conflicts.isEmpty { write("  conflicts: \(record.relations.conflicts)\n") }
        if !record.relations.provides.isEmpty {
            write("  provides:  \(record.relations.provides.map(\.description).joined(separator: ", "))\n")
        }
        if !record.synopsis.isEmpty { write("  \(record.synopsis)\n") }
        if let body = record.extendedDescription { write(body.split(separator: "\n").map { "  \($0)" }.joined(separator: "\n") + "\n") }
        write("\n")
    }
}

func printPlan(_ plan: TransactionPlan, options: Options) {
    if options.has("json") {
        let payload: [String: Any] = [
            "summary": plan.summary,
            "download_size": plan.downloadSize,
            "installed_size_delta": plan.installedSize,
            "steps": plan.steps.map { step -> String in
                switch step {
                case .remove(let package, let purge): return "remove \(package.name)\(purge ? " --purge" : "")"
                case .unpack(let record): return "unpack \(record.name) \(record.version.raw)"
                case .configure(let name): return "configure \(name)"
                }
            },
            "warnings": plan.warnings.map(\.message),
        ]
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .prettyPrinted])
        write(String(decoding: data ?? Data(), as: UTF8.self) + "\n")
        return
    }
    write("\(plan.summary)\n")
    for record in plan.installed { write("  install    \(record.name) \(record.version.raw)\n") }
    for record in plan.upgraded { write("  upgrade    \(record.name) \(record.version.raw)\n") }
    for record in plan.downgraded { write("  downgrade  \(record.name) \(record.version.raw)\n") }
    for record in plan.reinstalled { write("  reinstall  \(record.name) \(record.version.raw)\n") }
    for removal in plan.removed { write("  remove     \(removal.package.name)\(removal.purge ? " (purge)" : "")\n") }
    if !plan.dependencies.isEmpty {
        write("  pulled in as dependencies: \(plan.dependencies.map(\.name).joined(separator: ", "))\n")
    }
    write("  download \(formatBytes(Int64(plan.downloadSize))), disk \(plan.installedSize >= 0 ? "+" : "-")\(formatBytes(abs(plan.installedSize)))\n")
    for warning in plan.warnings { write("  warning: \(warning.message)\n") }
    write("\n  \(plan.steps.count) dpkg step(s):\n")
    for step in plan.steps {
        switch step {
        case .remove(let package, let purge): write("    dpkg --\(purge ? "purge" : "remove") \(package.name)\n")
        case .unpack(let record): write("    dpkg --unpack \(record.name)_\(record.version.raw).deb\n")
        case .configure(let name): write("    dpkg --configure \(name)\n")
        }
    }
}

func commandPlan(_ arguments: [String], options: Options) throws {
    if arguments.first == "upgrade" {
        let (index, _, _) = try loadIndex(quiet: true)
        let database = installedDatabase()
        var queue = PackageQueue()
        for entry in database.present {
            guard let candidate = index.bestMatch(for: DependencyTerm(name: entry.name), architecture: architecture(options)) else { continue }
            if DebianVersion.compare(candidate.version, entry.version) > 0 {
                queue.stage(.upgrade(candidate))
            }
        }
        guard !queue.isEmpty else {
            write("everything is up to date\n")
            return
        }
        let resolver = DependencyResolver(available: index, installed: database, policy: resolverPolicy(options))
        printPlan(try resolver.resolve(queue), options: options)
        return
    }

    let queue = try queue(from: arguments, options: options)
    let (index, _, _) = try loadIndex(quiet: true)
    let resolver = DependencyResolver(available: index, installed: installedDatabase(), policy: resolverPolicy(options))
    printPlan(try resolver.resolve(queue), options: options)
}

func commandApply(_ arguments: [String], options: Options) throws {
    let queue = try queue(from: arguments, options: options)
    let list = store.load().list
    let (index, _, _) = try loadIndex(quiet: true)
    let resolver = DependencyResolver(available: index, installed: installedDatabase(), policy: resolverPolicy(options))
    let plan = try resolver.resolve(queue)
    printPlan(plan, options: options)

    if options.has("dry-run") {
        write("\ndry run: nothing was changed\n")
        return
    }
    guard environment.isUsable else {
        fail("this device has no usable dpkg (\(environment.layout.rawValue) layout)")
    }

    let engine = InstallEngine(environment: environment)
    let report = try sync {
        try await engine.execute(plan, sources: list.sources) { event in
            switch event {
            case .stage(let message): write("  · \(message)\n")
            case .downloading(let package, let received, let total):
                if total > 0, received == total { write("  · downloaded \(package) (\(formatBytes(total)))\n") }
            case .verifying(let package): write("  · verified \(package)\n")
            case .removing(let package): write("  · removing \(package)\n")
            case .unpacking(let package): write("  · unpacking \(package)\n")
            case .configuring(let package): write("  · configuring \(package)\n")
            case .output(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { write("      \(trimmed)\n") }
            case .finished, .failed: break
            }
        }
    }
    write("\n\(report.summary)\n")
    if !report.succeeded {
        for (package, reason) in report.failures.sorted(by: { $0.key < $1.key }) {
            write("  failed: \(package): \(reason)\n", to: .standardError)
        }
        exit(1)
    }
}

func commandDeb(_ arguments: [String]) throws {
    guard let path = arguments.first else { throw CLIError.missingArgument("path.deb") }
    guard FileManager.default.fileExists(atPath: path) else { throw CLIError.notFound(path) }
    let archive = try DebArchive(path: path)
    write("archive version: \(archive.binaryVersion ?? "?")\n")
    write("members:\n")
    for member in archive.members {
        write("  \(member.name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(formatBytes(member.size))\n")
    }
    let stanza = try archive.controlStanza()
    write("\ncontrol:\n")
    for field in stanza.fields {
        write("  \(field.name): \(field.value.split(separator: "\n").joined(separator: " / "))\n")
    }
    let scripts = try archive.maintainerScripts()
    if !scripts.isEmpty {
        write("\nmaintainer scripts: \(scripts.keys.sorted().joined(separator: ", "))\n")
    }
    let summary = try archive.payloadSummary()
    write("\npayload: \(summary.files) file(s), \(formatBytes(summary.bytes)) uncompressed\n")
}

// MARK: - Entry point

let rawArguments = Array(CommandLine.arguments.dropFirst())
let command = rawArguments.first
let rest = Array(rawArguments.dropFirst())

do {
    switch command {
    case nil, "help", "--help", "-h":
        write(usage() + "\n")
    case "version", "--version":
        write("aurora \(auroraVersion)\n")
    case "env":
        commandEnvironment(Options(rest, valueFlags: []))
    case "status":
        try commandStatus(Options(rest, valueFlags: []))
    case "sources":
        try commandSources(rest)
    case "refresh":
        try commandRefresh(Options(rest, valueFlags: ["only", "architecture"]))
    case "search":
        try commandSearch(rest, options: Options(rest, valueFlags: ["architecture"]))
    case "show":
        try commandShow(rest, options: Options(rest, valueFlags: ["architecture"]))
    case "plan":
        try commandPlan(rest, options: Options(rest, valueFlags: ["architecture"]))
    case "apply":
        try commandApply(rest, options: Options(rest, valueFlags: ["architecture"]))
    case "deb":
        try commandDeb(rest)
    default:
        fail("unknown command '\(command ?? "")'. Run 'aurora help'.")
    }
} catch let error as ResolutionFailure {
    write("cannot resolve this transaction:\n", to: .standardError)
    for problem in error.errors { write("  \(problem)\n", to: .standardError) }
    exit(3)
} catch {
    fail("\(error)")
}
