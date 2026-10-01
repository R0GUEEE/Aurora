import Foundation

/// Persists repository definitions in the same deb822 source format Sileo uses.
///
/// Repository definitions live in `sileo.sources`. Aurora-only state (stable UUID,
/// enablement, refresh health and trusted keys) is stored in a sidecar so the
/// source file itself remains interoperable with Sileo/APT.
public struct SourceStore: Sendable {
    public let path: String

    public init(path: String? = nil) {
        self.path = path ?? SourceStore.defaultPath()
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
        return (base as NSString).appendingPathComponent("sileo.sources")
    }

    private var statePath: String {
        ((path as NSString).deletingPathExtension as NSString).appendingPathExtension("state.json")!
    }

    private var legacyJSONPath: String {
        ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent("sources.json")
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
        if FileManager.default.fileExists(atPath: path) {
            do {
                let text = try String(contentsOfFile: path, encoding: .utf8)
                let sources = parseDeb822(text)
                return LoadResult(list: RepositoryList(sources: applyState(to: sources)), failure: nil)
            } catch {
                return LoadResult(
                    list: RepositoryList(sources: SourceStore.builtInSources),
                    failure: "\(path) could not be read (\(error)); showing the built-in sources instead"
                )
            }
        }

        // One-time transparent migration from Aurora's original JSON format.
        if FileManager.default.fileExists(atPath: legacyJSONPath) {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: legacyJSONPath))
                let legacy = try JSONDecoder().decode(RepositoryList.self, from: data)
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
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let body = list.sources.map { source -> String in
            let components = source.components.joined(separator: " ")
            return """
            Types: deb
            URIs: \(source.normalizedURL)/
            Suites: \(source.suite.isEmpty ? "./" : source.suite)
            Components: \(components)
            """
        }.joined(separator: "\n\n") + (list.sources.isEmpty ? "" : "\n")

        try Data(body.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)

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

    private func parseDeb822(_ text: String) -> [RepositorySource] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .compactMap { stanza in
                var fields: [String: String] = [:]
                for rawLine in stanza.components(separatedBy: "\n") {
                    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty, !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { continue }
                    let key = String(line[..<colon]).lowercased()
                    fields[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                }
                let types = fields["types"]?.split(whereSeparator: \.isWhitespace).map(String.init) ?? []
                guard types.contains("deb"), let uris = fields["uris"], !uris.isEmpty else { return nil }
                let url = uris.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? uris
                let suite = fields["suites"]?.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "./"
                let components = fields["components"]?.split(whereSeparator: \.isWhitespace).map(String.init) ?? []
                let architectures = fields["architectures"]?.split(whereSeparator: \.isWhitespace).map(String.init) ?? []
                let host = URL(string: url)?.host ?? url
                return RepositorySource(
                    name: host,
                    url: url,
                    suite: suite.isEmpty ? "./" : suite,
                    components: components,
                    architectures: architectures
                )
            }
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

    private func stateKey(_ source: RepositorySource) -> String {
        "\(source.normalizedURL.lowercased())|\(source.suite)|\(source.components.joined(separator: ","))"
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
