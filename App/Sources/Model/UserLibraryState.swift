import Foundation
import AuroraCore

struct PackageActivity: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case install, reinstall, upgrade, downgrade, remove, purge }
    let id: UUID
    let package: String
    let version: String?
    let kind: Kind
    let date: Date

    init(package: String, version: String?, kind: Kind, date: Date = Date()) {
        self.id = UUID()
        self.package = package
        self.version = version
        self.kind = kind
        self.date = date
    }
}

struct UserLibraryState: Codable {
    var bookmarks: Set<String> = []
    var hiddenPackages: Set<String> = []
    /// package|version|origin -> first time Aurora observed it.
    var firstSeen: [String: Date] = [:]
    var history: [PackageActivity] = []

    init(
        bookmarks: Set<String> = [],
        hiddenPackages: Set<String> = [],
        firstSeen: [String: Date] = [:],
        history: [PackageActivity] = []
    ) {
        self.bookmarks = bookmarks
        self.hiddenPackages = hiddenPackages
        self.firstSeen = firstSeen
        self.history = history
    }

    private enum CodingKeys: String, CodingKey {
        case bookmarks, hiddenPackages, firstSeen, history
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bookmarks = (try? c.decode(Set<String>.self, forKey: .bookmarks)) ?? []
        hiddenPackages = (try? c.decode(Set<String>.self, forKey: .hiddenPackages)) ?? []
        firstSeen = (try? c.decode([String: Date].self, forKey: .firstSeen)) ?? [:]
        history = (try? c.decode([PackageActivity].self, forKey: .history)) ?? []
    }

    static func load() -> UserLibraryState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(UserLibraryState.self, from: data) else { return .init() }
        return state
    }

    func save() throws {
        let directory = Self.url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url, options: .atomic)
    }

    private static var url: URL {
        let directory = (SourceStore.defaultPath() as NSString).deletingLastPathComponent
        return URL(fileURLWithPath: directory).appendingPathComponent("library.json")
    }
}
