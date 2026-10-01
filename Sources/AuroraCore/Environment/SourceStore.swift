import Foundation

/// Persists repositories using the same APT source directory Sileo reads.
///
/// On a rootless jailbreak Aurora reads every `.list` and `.sources` file in
/// `/var/jb/etc/apt/sources.list.d`. On rootful jailbreaks the equivalent path
/// is `/etc/apt/sources.list.d`. Aurora-managed entries are written only to
/// `sileo.sources`; source files owned by Procursus, Zebra, Cydia, or another
/// package manager are never overwritten.
public struct SourceStore: Sendable {
    /// Aurora's managed source file. The containing directory is also scanned for
    /// sibling .list/.sources files when loading.
    public let path: String

    public init(path: String? = nil) {
        self.path = path ?? SourceStore.defaultPath()
    }

    public static func defaultPath() -> String {
        #if os(macOS)
        return (applicationDataDirectory() as NSString).appendingPathComponent("sileo.sources")
        #else
        let environment = JailbreakEnvironment.detect()
        if let directory = environment.aptSourcesListDirectory {
            return (directory as NSString).appendingPathComponent("sileo.sources")
        }
        // Non-jailbroken preview builds still need somewhere writable.
        return (applicationDataDirectory() as NSString).appendingPathComponent("sileo.sources")
        #endif
    }

    public static func applicationDataDirectory() -> String {
        #if os(macOS)
        return (NSHomeDirectory() as NSString).appendingPathComponent("Library/Application Support/Aurora")
        #else
        let candidates = [
            "/var/mobile/Library/Application Support/Aurora",
            "/var/mobile/Library/Preferences/Aurora",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
        #endif
    }

    public var directory: String {
        (path as NSString).deletingLastPathComponent
    }

    private var statePath: String {
        // Keep Aurora-only metadata out of the real APT source directory. Custom
        // stores (tests/tools) retain the historical sibling-sidecar behavior.
        if isAPTSourceDirectory {
            let base = SourceStore.applicationDataDirectory()
            return (base as NSString).appendingPathComponent("sources.state.json")
        }
        return ((path as NSString).deletingPathExtension as NSString)
            .appendingPathExtension("state.json")!
    }

    private var isAPTSourceDirectory: Bool {
        let normalized = URL(fileURLWithPath: directory).standardizedFileURL.path
        return normalized.hasSuffix("/etc/apt/sources.list.d")
    }

    private var isDefaultStore: Bool {
        URL(fileURLWithPath: path).standardizedFileURL.path
            == URL(fileURLWithPath: SourceStore.defaultPath()).standardizedFileURL.path
    }

    private var legacyJSONPath: String {
        (SourceStore.applicationDataDirectory() as NSString).appendingPathComponent("sources.json")
    }

    private var legacyPrivateSourcePath: String {
        (SourceStore.applicationDataDirectory() as NSString).appendingPathComponent("sileo.sources")
    }

    public struct LoadResult: Sendable {
        public let list: RepositoryList
        public let failure: String?
    }

    private struct PersistedState: Codable {
        var id: UUID
        var name: String
        var trustedKeys: [String]
        var isEnabled: Bool
        var isBuiltIn: Bool
        var lastRefreshed: Date?
        var lastError: String?
        var consecutiveFailures: Int?
    }

    public func load() -> LoadResult {
        let manager = FileManager.default

        // Sileo scans the whole directory, not just sileo.sources. Do the same so
        // Aurora immediately sees repositories installed by bootstrap packages or
        // edited by another package manager.
        if manager.fileExists(atPath: directory) {
            do {
                let names = try manager.contentsOfDirectory(atPath: directory)
                    .filter {
                        let ext = ($0 as NSString).pathExtension.lowercased()
                        return ext == "list" || ext == "sources"
                    }
                    .sorted()

                if !names.isEmpty {
                    var collected: [RepositorySource] = []
                    var seen = Set<String>()
                    var failures: [String] = []

                    for name in names {
                        let file = (directory as NSString).appendingPathComponent(name)
                        do {
                            let text = try String(contentsOfFile: file, encoding: .utf8)
                            for parsed in parseDeb822(text) {
                                var source = parsed
                                source.sourceFile = file
                                let key = sourceIdentity(source)
                                if seen.insert(key).inserted {
                                    collected.append(source)
                                }
                            }
                        } catch {
                            // Match Sileo's best-effort directory scan: one broken
                            // source file must not hide every other repository.
                            failures.append("\(name): \(error)")
                        }
                    }

                    // Existing rootless installs normally already have
                    // procursus.sources. If Aurora used its old private
                    // sileo.sources, migrate those entries even though the APT
                    // directory is not empty.
                    let managedExists = manager.fileExists(atPath: path)
                    if isDefaultStore,
                       !managedExists,
                       legacyPrivateSourcePath != path,
                       manager.fileExists(atPath: legacyPrivateSourcePath) {
                        do {
                            let legacyText = try String(
                                contentsOfFile: legacyPrivateSourcePath,
                                encoding: .utf8
                            )
                            for parsed in parseDeb822(legacyText) {
                                var source = parsed
                                source.sourceFile = nil
                                let key = sourceIdentity(source)
                                if seen.insert(key).inserted {
                                    collected.append(source)
                                }
                            }
                            let migrated = RepositoryList(sources: applyState(to: collected))
                            try save(migrated)
                            return LoadResult(
                                list: migrated,
                                failure: failures.isEmpty ? nil : failures.joined(separator: "; ")
                            )
                        } catch {
                            failures.append("legacy sileo.sources migration: \(error)")
                        }
                    }

                    return LoadResult(
                        list: RepositoryList(sources: applyState(to: collected)),
                        failure: failures.isEmpty ? nil : failures.joined(separator: "; ")
                    )
                }
            } catch {
                return LoadResult(
                    list: RepositoryList(sources: SourceStore.builtInSources),
                    failure: "\(directory) could not be read (\(error)); showing the built-in sources instead"
                )
            }
        }

        // One-time migration from Aurora's previous private sileo.sources.
        if isDefaultStore,
           legacyPrivateSourcePath != path,
           manager.fileExists(atPath: legacyPrivateSourcePath) {
            do {
                let text = try String(contentsOfFile: legacyPrivateSourcePath, encoding: .utf8)
                var sources = parseDeb822(text)
                // Nil marks these as Aurora-managed so save() moves them into the
                // real APT source directory.
                for index in sources.indices { sources[index].sourceFile = nil }
                let list = RepositoryList(sources: applyState(to: sources))
                try save(list)
                return LoadResult(list: list, failure: nil)
            } catch {
                return LoadResult(
                    list: RepositoryList(sources: SourceStore.builtInSources),
                    failure: "Legacy sileo.sources could not be migrated (\(error)); showing the built-in sources instead"
                )
            }
        }

        // Older Aurora builds used JSON before switching to Deb822.
        if isDefaultStore, manager.fileExists(atPath: legacyJSONPath) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: legacyJSONPath))
                var legacy = try JSONDecoder().decode(RepositoryList.self, from: data)
                for index in legacy.sources.indices { legacy.sources[index].sourceFile = nil }
                try save(legacy)
                return LoadResult(list: legacy, failure: nil)
            } catch {
                return LoadResult(
                    list: RepositoryList(sources: SourceStore.builtInSources),
                    failure: "Legacy sources.json could not be migrated (\(error)); showing the built-in sources instead"
                )
            }
        }

        return LoadResult(list: RepositoryList(sources: SourceStore.builtInSources), failure: nil)
    }

    public func save(_ list: RepositoryList) throws {
        let manager = FileManager.default
        try manager.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let managedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let managedSources = list.sources.filter { source in
            guard let sourceFile = source.sourceFile else { return true }
            return URL(fileURLWithPath: sourceFile).standardizedFileURL.path == managedPath
        }

        let body = managedSources.map(Self.renderSource).joined(separator: "\n\n")
            + (managedSources.isEmpty ? "" : "\n")
        try Data(body.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)

        try manager.createDirectory(
            atPath: (statePath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )

        var states: [String: PersistedState] = [:]
        for source in list.sources {
            states[stateKey(source)] = PersistedState(
                id: source.id,
                name: source.name,
                trustedKeys: source.trustedKeys,
                isEnabled: source.isEnabled,
                isBuiltIn: source.isBuiltIn,
                lastRefreshed: source.lastRefreshed,
                lastError: source.lastError,
                consecutiveFailures: source.consecutiveFailures
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(states).write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }

    private static func renderSource(_ source: RepositorySource) -> String {
        let components = source.components.joined(separator: " ")
        let architectures = source.architectures.isEmpty
            ? ""
            : "\nArchitectures: \(source.architectures.joined(separator: " "))"
        let architectureAdditions = (source.architectureAdditions ?? []).isEmpty
            ? ""
            : "\nArchitectures-Add: \((source.architectureAdditions ?? []).joined(separator: " "))"
        let architectureRemovals = (source.architectureRemovals ?? []).isEmpty
            ? ""
            : "\nArchitectures-Remove: \((source.architectureRemovals ?? []).joined(separator: " "))"
        let enabled = source.isEnabled ? "" : "\nEnabled: no"
        return """
        Types: deb
        URIs: \(source.normalizedURL)/
        Suites: \(source.suite.isEmpty ? "./" : source.suite)
        Components: \(components)\(architectures)\(architectureAdditions)\(architectureRemovals)\(enabled)
        """
    }

    private func parseDeb822(_ text: String) -> [RepositorySource] {
        SourceInterchange.parse(text)
    }

    private func applyState(to sources: [RepositorySource]) -> [RepositorySource] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
              let states = try? JSONDecoder().decode([String: PersistedState].self, from: data) else {
            return sources
        }
        return sources.map { source in
            guard let state = states[stateKey(source)] else { return source }
            var source = source
            source.id = state.id
            source.name = state.name
            source.trustedKeys = state.trustedKeys
            source.isEnabled = state.isEnabled
            source.isBuiltIn = state.isBuiltIn
            source.lastRefreshed = state.lastRefreshed
            source.lastError = state.lastError
            source.consecutiveFailures = state.consecutiveFailures
            return source
        }
    }

    private func sourceIdentity(_ source: RepositorySource) -> String {
        "\(source.normalizedURL.lowercased())|\(source.suite)|\(source.components.joined(separator: ","))"
    }

    private func stateKey(_ source: RepositorySource) -> String {
        sourceIdentity(source)
    }

    public static var builtInSources: [RepositorySource] {
        [
            RepositorySource(
                name: "Procursus",
                url: "https://apt.procurs.us",
                suite: "iphoneos-arm64/1800",
                components: ["main"],
                isBuiltIn: true
            ),
            RepositorySource(name: "Chariz", url: "https://repo.chariz.com", suite: "./", components: [], isBuiltIn: true),
            RepositorySource(name: "Havoc", url: "https://havoc.app", suite: "./", components: [], isBuiltIn: true),
        ]
    }
}
