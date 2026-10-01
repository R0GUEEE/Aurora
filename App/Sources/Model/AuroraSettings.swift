import Foundation
import AuroraCore

/// How a package's detail page should be rendered.
///
/// Jailbreak repositories publish two depiction fields: the classic `Depiction`
/// (a web page) and the newer `SileoDepiction`/`ModernDepiction` (a JSON
/// description a client renders natively). Which one a user gets is a
/// preference, hence this type.
enum DepictionPreference: String, CaseIterable, Codable, Identifiable {
    case native
    case classic
    case fallback

    var id: String { rawValue }

    var label: String {
        switch self {
        case .native: return "Sileo depiction"
        case .classic: return "Classic depiction"
        case .fallback: return "Render in Aurora"
        }
    }

    var explanation: String {
        switch self {
        case .native: return "Use the SileoDepiction/ModernDepiction field when the repository provides one."
        case .classic: return "Always open the classic Depiction web page."
        case .fallback: return "Never load a web page; show the package metadata Aurora already has."
        }
    }
}



enum AppTab: String, CaseIterable, Codable, Identifiable {
    case browse
    case newPackages
    case installed
    case library
    case sources
    case search
    case queue
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .browse: return "Browse"
        case .newPackages: return "New"
        case .installed: return "Installed"
        case .library: return "Library"
        case .sources: return "Sources"
        case .search: return "Search"
        case .queue: return "Queue"
        case .settings: return "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .browse: return "square.grid.2x2"
        case .newPackages: return "sparkles"
        case .installed: return "shippingbox"
        case .library: return "bookmark"
        case .sources: return "square.stack.3d.up"
        case .search: return "magnifyingglass"
        case .queue: return "arrow.down.circle"
        case .settings: return "gearshape"
        }
    }

    static let defaultTabs: [AppTab] = [.browse, .newPackages, .installed, .sources, .queue]
}

/// Everything the Settings screen can change.
///
/// Decoding is deliberately tolerant: a settings file written by an older build
/// — or a truncated one — must not stop Aurora from launching, so every key falls
/// back to its default.
struct AuroraSettings: Codable, Equatable {
    /// Refresh every enabled repository when the app launches.
    var autoRefreshOnLaunch: Bool
    /// Treat an unsigned or unverifiable repository as acceptable. On by default:
    /// most jailbreak repositories are unsigned, and refusing them would leave
    /// the store empty. `AuroraCore` still reports the state of every source.
    var ignoreSignatureFailures: Bool
    /// Hide packages that cannot work in a rootless layout.
    var showOnlyRootlessCompatible: Bool
    /// Offer an explicit best-effort conversion action for legacy rootful packages.
    var allowRootfulConversion: Bool
    var depictionPreference: DepictionPreference
    var tabs: [AppTab]

    init(
        autoRefreshOnLaunch: Bool = true,
        ignoreSignatureFailures: Bool = true,
        showOnlyRootlessCompatible: Bool = true,
        allowRootfulConversion: Bool = false,
        depictionPreference: DepictionPreference = .native,
        tabs: [AppTab] = AppTab.defaultTabs
    ) {
        self.autoRefreshOnLaunch = autoRefreshOnLaunch
        self.ignoreSignatureFailures = ignoreSignatureFailures
        self.showOnlyRootlessCompatible = showOnlyRootlessCompatible
        self.allowRootfulConversion = allowRootfulConversion
        self.depictionPreference = depictionPreference
        self.tabs = Self.sanitizedTabs(tabs)
    }

    private enum CodingKeys: String, CodingKey {
        case autoRefreshOnLaunch
        case ignoreSignatureFailures
        case showOnlyRootlessCompatible
        case allowRootfulConversion
        case depictionPreference
        case tabs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.autoRefreshOnLaunch =
            (try? container.decode(Bool.self, forKey: .autoRefreshOnLaunch)) ?? true
        self.ignoreSignatureFailures =
            (try? container.decode(Bool.self, forKey: .ignoreSignatureFailures)) ?? true
        self.showOnlyRootlessCompatible =
            (try? container.decode(Bool.self, forKey: .showOnlyRootlessCompatible)) ?? true
        self.allowRootfulConversion =
            (try? container.decode(Bool.self, forKey: .allowRootfulConversion)) ?? false
        self.depictionPreference =
            (try? container.decode(DepictionPreference.self, forKey: .depictionPreference)) ?? .native
        self.tabs = Self.sanitizedTabs((try? container.decode([AppTab].self, forKey: .tabs)) ?? AppTab.defaultTabs)
    }

    static func sanitizedTabs(_ tabs: [AppTab]) -> [AppTab] {
        var seen = Set<AppTab>()
        let unique = tabs.filter { seen.insert($0).inserted }
        return unique.isEmpty ? AppTab.defaultTabs : Array(unique.prefix(5))
    }
}

/// Persists `AuroraSettings` next to the repository list.
///
/// Lives in the same directory as `AuroraCore.SourceStore`'s file, derived from
/// it so the two can never disagree about where Aurora's state belongs.
struct SettingsStore {
    let path: String

    init(path: String? = nil) {
        self.path = path ?? SettingsStore.defaultPath()
    }

    static func defaultPath() -> String {
        let directory = (SourceStore.defaultPath() as NSString).deletingLastPathComponent
        return (directory as NSString).appendingPathComponent("settings.json")
    }

    struct LoadResult {
        let settings: AuroraSettings
        /// Set when the file existed but could not be read; the defaults are used.
        let failure: String?
    }

    func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: path) else {
            return LoadResult(settings: AuroraSettings(), failure: nil)
        }
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            if data.isEmpty { return LoadResult(settings: AuroraSettings(), failure: nil) }
            return LoadResult(settings: try JSONDecoder().decode(AuroraSettings.self, from: data), failure: nil)
        } catch {
            return LoadResult(
                settings: AuroraSettings(),
                failure: "\(path) could not be read (\(AuroraFormat.message(for: error))); using the defaults."
            )
        }
    }

    func save(_ settings: AuroraSettings) throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(settings)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
