import Foundation

/// Persists the repository list.
///
/// Both the app and the CLI use this, against the same file, so a repository
/// added from the command line shows up in the UI and vice versa. Writes go
/// through a temporary file and a rename; a corrupt or half-written list is
/// treated as an empty one and reported, never as a crash.
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
        return (base as NSString).appendingPathComponent("sources.json")
    }

    public struct LoadResult: Sendable {
        public let list: RepositoryList
        /// Set when the file existed but could not be read; the list is then empty
        /// and the caller decides what to tell the user.
        public let failure: String?
    }

    public func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: path) else {
            return LoadResult(list: RepositoryList(sources: SourceStore.builtInSources), failure: nil)
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            if data.isEmpty {
                return LoadResult(list: RepositoryList(sources: SourceStore.builtInSources), failure: nil)
            }
            let list = try JSONDecoder().decode(RepositoryList.self, from: data)
            return LoadResult(list: list, failure: nil)
        } catch {
            return LoadResult(
                list: RepositoryList(sources: SourceStore.builtInSources),
                failure: "\(path) could not be read (\(error)); showing the built-in sources instead"
            )
        }
    }

    public func save(_ list: RepositoryList) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(list)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// The repositories a fresh install starts with.
    ///
    /// Held to a minimum and all of them well known: a package manager that
    /// ships someone's private repository as a default is a security problem, not
    /// a feature.
    public static var builtInSources: [RepositorySource] {
        [
            RepositorySource(
                name: "Procursus",
                url: "https://apt.procurs.us",
                suite: "iphoneos-arm64/1800",
                components: ["main"],
                isBuiltIn: true
            ),
            RepositorySource(
                name: "Chariz",
                url: "https://repo.chariz.com",
                suite: "./",
                isBuiltIn: true
            ),
            RepositorySource(
                name: "Havoc",
                url: "https://havoc.app",
                suite: "./",
                isBuiltIn: true
            ),
        ]
    }
}
