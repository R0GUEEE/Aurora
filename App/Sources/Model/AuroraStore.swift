import Combine
import Foundation
import AuroraCore

/// One section of the browse list: the packages of one repository `Section:`
/// field, collapsed to the newest version of each package name.
struct PackageSection: Identifiable, Equatable {
    let name: String
    let records: [PackageRecord]
    var id: String { name }
}

/// Progress of a refresh run, so the UI can say "refreshing 2 of 5".
enum RefreshState: Equatable {
    case idle
    case refreshing(done: Int, total: Int)

    var isRefreshing: Bool {
        if case .refreshing = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .idle: return "Idle"
        case .refreshing(let done, let total): return "Refreshing \(done) of \(total)…"
        }
    }
}

struct RepositoryRefreshActivity: Identifiable, Equatable {
    enum Phase: String {
        case queued = "Queued"
        case refreshing = "Scanning"
        case complete = "Complete"
        case failed = "Failed"
    }
    let id: UUID
    var phase: Phase
    var startedAt: Date?
    var finishedAt: Date?
    var message: String?

    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        return (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }
}

/// The result of reading the dpkg database off the main thread.
private struct InstalledLoadOutcome: Sendable {
    let database: InstalledPackageDatabase
    let failure: String?
}

/// How a candidate record relates to what is installed.
enum PackageState: Equatable {
    case notInstalled
    case installed
    /// The record is newer than the installed version.
    case update(to: String)
    /// The record is older than the installed version (a downgrade candidate).
    case olderThanInstalled

    var label: String {
        switch self {
        case .notInstalled: return "Not installed"
        case .installed: return "Installed"
        case .update(let version): return "Update \(version)"
        case .olderThanInstalled: return "Older version"
        }
    }

    var isInstalled: Bool {
        switch self {
        case .installed, .update, .olderThanInstalled: return true
        case .notInstalled: return false
        }
    }
}

/// The single owner of Aurora's state.
///
/// Everything the UI shows comes from here: the repository list and its
/// persistence, one `PackageIndex` per source plus the merged index, the installed
/// database, the staged `PackageQueue`, refresh state and per-source errors.
///
/// The class is `@MainActor` for two reasons: SwiftUI reads it from the main
/// actor, and every mutation then has exactly one thread, so the published values
/// can never be observed half-updated.
// `@MainActor` because `AuroraStore` is main-actor isolated: only `body` is
// isolated by default, so helper members that touch the store need it explicitly.
@MainActor
final class AuroraStore: ObservableObject {

    // MARK: - Jailbreak

    /// Detected once: everything that touches the filesystem goes through it.
    let environment: JailbreakEnvironment

    // MARK: - Published state

    @Published private(set) var sources: [RepositorySource] = []
    /// One index per source, kept separate so a single repository can be
    /// refreshed (or dropped) without reloading the others.
    @Published private(set) var indexBySource: [UUID: PackageIndex] = [:]
    @Published private(set) var indexErrors: [UUID: String] = [:]
    @Published private(set) var indexWarnings: [UUID: [String]] = [:]
    @Published private(set) var signatureStatus: [UUID: SignatureStatus] = [:]
    /// Every enabled source, merged. This is what search and the resolver see.
    @Published private(set) var combinedIndex = PackageIndex()
    /// The browse list, precomputed so a view body never groups 30 000 records.
    @Published private(set) var sections: [PackageSection] = []
    @Published private(set) var sectionNames: [String] = []

    @Published private(set) var installed = InstalledPackageDatabase()
    /// Why the installed database is empty, when it is (no jailbreak, no dpkg).
    @Published private(set) var installedError: String?

    @Published private(set) var refreshState: RefreshState = .idle
    @Published private(set) var repositoryRefreshActivity: [UUID: RepositoryRefreshActivity] = [:]
    @Published private(set) var sourcesPersistenceError: String?
    @Published private(set) var settingsPersistenceError: String?

    @Published var queue = PackageQueue()
    @Published private(set) var userLibrary = UserLibraryState.load()
    /// The queue screen's model: staged changes plus what the resolver makes of
    /// them. Recomputing a plan touches every loaded record, so it is done when
    /// the queue or the indexes change, never from a view body.
    @Published private(set) var queueAnalysis = QueueAnalysis()
    @Published private(set) var upgradePlan = UpgradePlanner.Plan()
    @Published var settings = AuroraSettings()
    @Published private(set) var packagePolicy = PackagePolicy.default
    @Published private(set) var policyPersistenceError: String?
    /// A problem worth an alert. Set by any operation that can fail.
    @Published var lastError: String?
    /// A short confirmation line ("Repository added.").
    @Published var statusMessage: String?

    // MARK: - Private state

    private let sourceStore: SourceStore
    private let settingsStore: SettingsStore
    private let policyStore: PackagePolicy.Store
    private var hasStarted = false
    private var upgradableNames: Set<String> = []

    // MARK: - Lifecycle

    init(environment: JailbreakEnvironment = JailbreakEnvironment.detect()) {
        let sourceStore = SourceStore()
        let settingsStore = SettingsStore()
        let policyStore = PackagePolicy.Store()

        self.environment = environment
        self.sourceStore = sourceStore
        self.settingsStore = settingsStore
        self.policyStore = policyStore

        let loadedSettings = settingsStore.load()
        self.settings = loadedSettings.settings
        self.settingsPersistenceError = loadedSettings.failure

        let loadedPolicy = policyStore.load()
        self.packagePolicy = loadedPolicy.policy
        self.policyPersistenceError = loadedPolicy.failure

        // A missing or corrupt sources.json is not fatal: SourceStore returns the
        // built-in repositories and tells us why.
        let loadedSources = sourceStore.load()
        self.sources = loadedSources.list.sources
        self.sourcesPersistenceError = loadedSources.failure
        // Restore persisted health so "skip failed repositories" remains effective
        // after relaunch instead of retrying every known-dead source immediately.
        self.indexErrors = Dictionary(uniqueKeysWithValues: self.sources.compactMap { source in
            source.lastError.map { (source.id, $0) }
        })

        rebuildIndexes()
    }

    /// First-launch work. Idempotent, so `.task` can call it again after a
    /// background/foreground cycle without re-refreshing everything.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        await reloadInstalled()
        if settings.autoCleanRepositoryData {
            _ = cleanRepositoryData(clearFailures: false)
        }
        if settings.autoRefreshOnLaunch {
            await refreshAll(forceReload: false)
        }
    }

    // MARK: - Jailbreak facts used by the UI

    var isJailbroken: Bool { environment.layout.isJailbroken }

    var layoutName: String {
        switch environment.layout {
        case .rootless: return "Rootless"
        case .rootful: return "Rootful"
        case .notJailbroken: return "Not jailbroken"
        }
    }

    var canInstall: Bool { environment.isUsable }

    // MARK: - Sources

    /// Adds a repository, returning a message to show the user, or nil on success.
    @discardableResult
    func addSource(urlText: String, suite: String, name: String) -> String? {
        let trimmedURL = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else { return "Enter a repository URL." }

        let trimmedSuite = suite.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = RepositorySource(
            name: trimmedName.isEmpty ? Self.derivedName(for: trimmedURL) : trimmedName,
            url: trimmedURL,
            suite: trimmedSuite.isEmpty ? "./" : trimmedSuite
        )
        guard candidate.isValid else {
            return "\(trimmedURL) is not a usable repository URL: it needs a scheme (http:// or https://) and a host."
        }

        var list = RepositoryList(sources: sources)
        do {
            // RepositoryList rejects a duplicate before it can double every
            // package in the store.
            try list.add(candidate)
        } catch {
            return AuroraFormat.message(for: error)
        }

        sources = list.sources
        persistSources()
        statusMessage = "Added \(candidate.name)."
        return nil
    }

    func removeSource(id: UUID) {
        guard let removed = sources.first(where: { $0.id == id }) else { return }
        sources.removeAll { $0.id == id }
        indexBySource[id] = nil
        indexErrors[id] = nil
        indexWarnings[id] = nil
        signatureStatus[id] = nil
        persistSources()
        rebuildIndexes()
        statusMessage = "Removed \(removed.name)."
    }

    func updateSource(
        id: UUID,
        name: String,
        url: String,
        suite: String,
        components: [String],
        architectures: [String]
    ) -> String? {
        guard let position = sources.firstIndex(where: { $0.id == id }) else { return "Repository not found." }
        var candidate = sources[position]
        candidate.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.derivedName(for: url)
            : name.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.suite = suite.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "./" : suite.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.components = components.isEmpty ? ["main"] : components
        candidate.architectures = architectures
        guard candidate.isValid else { return "Enter a valid http:// or https:// repository URL." }
        let duplicate = sources.contains {
            $0.id != id && $0.normalizedURL.caseInsensitiveCompare(candidate.normalizedURL) == .orderedSame && $0.suite == candidate.suite
        }
        guard !duplicate else { return "\(candidate.normalizedURL) is already configured for this suite." }
        sources[position] = candidate
        indexErrors[id] = nil
        indexWarnings[id] = nil
        signatureStatus[id] = nil
        persistSources()
        statusMessage = "Updated \(candidate.name). Refresh it to reload metadata."
        return nil
    }

    func clearSourceError(id: UUID) {
        guard let position = sources.firstIndex(where: { $0.id == id }) else { return }
        indexErrors[id] = nil
        indexWarnings[id] = nil
        sources[position].lastError = nil
        persistSources()
    }

    func resetSourceData(id: UUID) {
        guard let position = sources.firstIndex(where: { $0.id == id }) else { return }
        indexBySource[id] = nil
        indexErrors[id] = nil
        indexWarnings[id] = nil
        signatureStatus[id] = nil
        sources[position].lastError = nil
        sources[position].lastRefreshed = nil
        persistSources()
        rebuildIndexes()
        statusMessage = "Cleared cached state for \(sources[position].name). Refresh to reload it."
    }

    func setSourceEnabled(id: UUID, enabled: Bool) {
        guard let position = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[position].isEnabled = enabled
        persistSources()
        rebuildIndexes()
    }

    func moveSources(from offsets: IndexSet, to destination: Int) {
        sources.move(fromOffsets: offsets, toOffset: destination)
        persistSources()
    }

    func enableFailedSources(_ enabled: Bool) {
        let failed = Set(failedSourceIDs)
        for index in sources.indices where failed.contains(sources[index].id) {
            sources[index].isEnabled = enabled
        }
        persistSources()
        rebuildIndexes()
    }

    func setAllSourcesEnabled(_ enabled: Bool) {
        for index in sources.indices { sources[index].isEnabled = enabled }
        persistSources()
        rebuildIndexes()
    }

    func removeFailedSources() {
        let failed = Set(indexErrors.keys)
        guard !failed.isEmpty else { return }
        sources.removeAll { failed.contains($0.id) && !$0.isBuiltIn }
        for id in failed {
            indexBySource[id] = nil
            indexErrors[id] = nil
            indexWarnings[id] = nil
            signatureStatus[id] = nil
        }
        persistSources()
        rebuildIndexes()
        statusMessage = "Removed failed non-built-in repositories."
    }

    var failedSourceIDs: [UUID] {
        sources.compactMap { indexErrors[$0.id] == nil ? nil : $0.id }
    }

    func refreshFailedSources() async {
        let ids = failedSourceIDs
        for id in ids { await refresh(sourceID: id) }
    }

    /// Sources with a recorded error are skipped by normal bulk refreshes. They
    /// remain enabled and keep their last known-good index; explicit retry is the
    /// recovery path so a dead host cannot repeatedly consume the refresh window.
    var skippedFailedSourceCount: Int {
        guard settings.skipFailedRepositories && !settings.refreshFailedRepositories else { return 0 }
        return sources.filter { $0.isEnabled && indexErrors[$0.id] != nil }.count
    }

    func restoreDefaultSources() {
        var list = RepositoryList(sources: sources)
        var added = 0
        for builtIn in SourceStore.builtInSources {
            let exists = list.sources.contains {
                $0.normalizedURL.lowercased() == builtIn.normalizedURL.lowercased() && $0.suite == builtIn.suite
            }
            if !exists {
                list.sources.append(builtIn)
                added += 1
            }
        }
        sources = list.sources
        persistSources()
        rebuildIndexes()
        statusMessage = added == 0 ? "Default repositories were already present." : "Restored \(added) default repositories."
    }

    @discardableResult
    func importSources(_ text: String) -> (added: Int, skipped: Int) {
        let incoming = SourceInterchange.parse(text)
        var list = RepositoryList(sources: sources)
        var added = 0
        var skipped = 0
        for source in incoming {
            do {
                try list.add(source)
                added += 1
            } catch {
                skipped += 1
            }
        }
        sources = list.sources
        persistSources()
        rebuildIndexes()
        statusMessage = "Imported \(added) source\(added == 1 ? "" : "s")\(skipped > 0 ? "; skipped \(skipped)" : "")."
        return (added, skipped)
    }

    var exportedSources: String { SourceInterchange.export(sources) }

    struct BackupDocument: Codable {
        let createdAt: Date
        let sources: [RepositorySource]
        let settings: AuroraSettings
        let library: UserLibraryState
        let policy: PackagePolicy
        let installedPackages: [String]
    }

    var exportedBackup: String {
        let document = BackupDocument(
            createdAt: Date(),
            sources: sources,
            settings: settings,
            library: userLibrary,
            policy: packagePolicy,
            installedPackages: installed.present.map { "\($0.name)=\($0.version.raw)" }.sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(document) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    func importBackup(_ text: String) -> Bool {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = text.data(using: .utf8),
              let backup = try? decoder.decode(BackupDocument.self, from: data) else {
            lastError = "This is not a valid Aurora backup."
            return false
        }
        sources = backup.sources
        settings = backup.settings
        userLibrary = backup.library
        packagePolicy = backup.policy
        // Runtime repository state belongs to the pre-restore source set. Never
        // merge stale indexes/errors/signatures into a restored configuration,
        // even when a backup happens to reuse a UUID.
        indexBySource = [:]
        indexErrors = [:]
        indexWarnings = [:]
        signatureStatus = [:]
        persistSources()
        persistSettings()
        persistUserLibrary()
        persistPackagePolicy()
        rebuildIndexes()
        statusMessage = "Aurora backup restored."
        return true
    }

    func stageLocalPackage(at url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            // Document-picker security scope only lasts for this call. Keep a
            // private copy so a package staged now is still readable when the
            // transaction is confirmed later.
            let directory = URL(fileURLWithPath: environment.cacheDirectory, isDirectory: true)
                .appendingPathComponent("LocalPackages", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            try FileManager.default.copyItem(at: url, to: destination)

            let package = try LocalPackageLoader.load(
                path: destination.path,
                deviceArchitecture: environment.architecture,
                requireCompatibleArchitecture: true
            )
            stage(.install(package.record))
            statusMessage = "Staged local package \(package.record.displayName) \(package.version.raw)."
        } catch {
            lastError = "Could not open \(url.lastPathComponent): \(AuroraFormat.message(for: error))"
        }
    }

    func packageRecords(for sourceID: UUID, matching query: String = "") -> [PackageRecord] {
        guard let index = indexBySource[sourceID] else { return [] }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var best: [String: PackageRecord] = [:]
        for record in index.records {
            if filtersRootlessOnly && !Self.isCompatible(record) { continue }
            if !needle.isEmpty {
                let matches = record.name.lowercased().contains(needle)
                    || record.displayName.lowercased().contains(needle)
                    || record.synopsis.lowercased().contains(needle)
                    || record.section.lowercased().contains(needle)
                if !matches { continue }
            }
            if let existing = best[record.name] {
                if DebianVersion.compare(record.version, existing.version) > 0 {
                    best[record.name] = record
                }
            } else {
                best[record.name] = record
            }
        }

        return best.values.sorted {
            let order = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return order == .orderedSame ? $0.name < $1.name : order == .orderedAscending
        }
    }

    func packageCount(for id: UUID) -> Int { indexBySource[id]?.count ?? 0 }

    func signatureDescription(for id: UUID) -> String? {
        signatureStatus[id]?.shortDescription
    }

    /// The first three warnings for a source, for the row's disclosure.
    func warnings(for id: UUID) -> [String] { indexWarnings[id] ?? [] }

    var totalPackageCount: Int { combinedIndex.count }

    // MARK: - Refresh

    func refreshAll(forceReload: Bool = true) async {
        let allEnabled = sources.filter(\.isEnabled)
        let enabled = (settings.skipFailedRepositories && !settings.refreshFailedRepositories)
            ? allEnabled.filter { indexErrors[$0.id] == nil }
            : allEnabled
        let skipped = allEnabled.count - enabled.count
        guard !allEnabled.isEmpty else {
            refreshState = .idle
            statusMessage = "Add a repository to get packages."
            return
        }
        guard !enabled.isEmpty else {
            refreshState = .idle
            statusMessage = skipped > 0
                ? "Skipped \(skipped) failed repositor\(skipped == 1 ? "y" : "ies"). Use Retry Failed to check them again."
                : "No repositories need refreshing."
            return
        }
        refreshState = .refreshing(done: 0, total: enabled.count)
        repositoryRefreshActivity = Dictionary(uniqueKeysWithValues: enabled.map {
            ($0.id, RepositoryRefreshActivity(id: $0.id, phase: .queued, startedAt: nil, finishedAt: nil, message: nil))
        })
        defer { refreshState = .idle }
        // Keep the cache available even for a forced refresh. A forced refresh means
        // revalidate with the server; ETag/Last-Modified can still turn unchanged
        // indexes into tiny 304 responses instead of full downloads.
        let useCache = settings.useRepositoryCache
        // Keep a rolling window full instead of waiting for the slowest member of
        // each fixed batch. This removes head-of-line blocking from dead/slow repos.
        let configuredConcurrency = settings.fastRepositoryScan ? max(settings.refreshConcurrency, 12) : settings.refreshConcurrency
        let concurrency = min(configuredConcurrency, enabled.count)
        let environment = self.environment
        let requireSignature = !settings.ignoreSignatureFailures
        let metadataTimeout = TimeInterval(settings.repositoryTimeoutSeconds)
        let maximumIndexBytes = settings.maximumIndexSizeMB * (1 << 20)
        // Snapshot MainActor settings before entering Sendable child tasks.
        let refreshDeadline = settings.repositoryRefreshDeadlineSeconds
        let parallelFlatIndexScan = settings.fastRepositoryScan
        let preferCachedIndexFormat = settings.preferCachedIndexFormat
        var completed = 0
        var next = 0

        await withTaskGroup(of: RefreshOutcome.self) { group in
            func enqueue(_ source: RepositorySource) {
                repositoryRefreshActivity[source.id] = RepositoryRefreshActivity(
                    id: source.id, phase: .refreshing, startedAt: Date(), finishedAt: nil, message: nil
                )
                group.addTask {
                    let client = RepositoryClient(
                        environment: environment,
                        downloader: HTTPDownloader(metadataTimeout: metadataTimeout),
                        policy: RepositoryPolicy(
                            requireSignature: requireSignature,
                            maximumIndexBytes: maximumIndexBytes,
                            useCache: useCache,
                            maximumRefreshSeconds: refreshDeadline,
                            parallelFlatIndexScan: parallelFlatIndexScan,
                            preferCachedIndexFormat: preferCachedIndexFormat
                        )
                    )
                    do {
                        let result = try await client.refresh(source)
                        return .success(source.id, result)
                    } catch {
                        return .failure(source.id, AuroraFormat.message(for: error))
                    }
                }
            }

            while next < min(concurrency, enabled.count) {
                enqueue(enabled[next])
                next += 1
            }

            while let outcome = await group.next() {
                applyRefreshOutcome(outcome)
                completed += 1
                refreshState = .refreshing(done: completed, total: enabled.count)
                if next < enabled.count {
                    enqueue(enabled[next])
                    next += 1
                }
            }
        }
        // Rebuild once after all source outcomes have landed. Rebuilding the full
        // merged index after every network batch is O(batches × packages) and was
        // a major cost on 50–100 source configurations.
        persistSources()
        rebuildIndexes()
        if skipped > 0 {
            statusMessage = "Refresh complete. Skipped \(skipped) failed repositor\(skipped == 1 ? "y" : "ies")."
        }
    }

    func refresh(sourceID: UUID) async {
        guard let source = sources.first(where: { $0.id == sourceID }) else { return }
        refreshState = .refreshing(done: 0, total: 1)
        defer { refreshState = .idle }
        await refresh(source, using: makeRepositoryClient(useCache: true))
    }

    private enum RefreshOutcome: Sendable {
        case success(UUID, RepositoryRefresh)
        case failure(UUID, String)
    }

    private func applyRefreshOutcome(_ outcome: RefreshOutcome) {
        switch outcome {
        case .success(let id, let result):
            if var activity = repositoryRefreshActivity[id] {
                activity.phase = .complete
                activity.finishedAt = Date()
                activity.message = "\(result.index.count) packages"
                repositoryRefreshActivity[id] = activity
            }
            indexBySource[id] = result.index
            indexErrors[id] = nil
            indexWarnings[id] = result.warnings
            signatureStatus[id] = result.signature
            recordSourceOutcome(id: id, refreshedAt: result.fetchedAt, error: nil, persist: false)
        case .failure(let id, let message):
            if var activity = repositoryRefreshActivity[id] {
                activity.phase = .failed
                activity.finishedAt = Date()
                activity.message = message
                repositoryRefreshActivity[id] = activity
            }
            indexErrors[id] = message
            indexWarnings[id] = []
            signatureStatus[id] = nil
            recordSourceOutcome(id: id, refreshedAt: nil, error: message, persist: false)
        }
    }

    private func refresh(_ source: RepositorySource, using client: RepositoryClient) async {
        do {
            let result = try await client.refresh(source)
            indexBySource[source.id] = result.index
            indexErrors[source.id] = nil
            indexWarnings[source.id] = result.warnings
            signatureStatus[source.id] = result.signature
            recordSourceOutcome(id: source.id, refreshedAt: result.fetchedAt, error: nil)
        } catch {
            // A failed source keeps its place in the list and shows why: a dead
            // repository must not take the whole store down with it.
            // Keep the last known-good index visible. A transient network or
            // repository failure must not make every package from this source vanish.
            indexErrors[source.id] = AuroraFormat.message(for: error)
            indexWarnings[source.id] = []
            signatureStatus[source.id] = nil
            recordSourceOutcome(id: source.id, refreshedAt: nil, error: AuroraFormat.message(for: error))
        }
        rebuildIndexes()
    }

    private func makeRepositoryClient(useCache: Bool = true) -> RepositoryClient {
        RepositoryClient(
            environment: environment,
            downloader: HTTPDownloader(metadataTimeout: TimeInterval(settings.repositoryTimeoutSeconds)),
            policy: RepositoryPolicy(
                requireSignature: !settings.ignoreSignatureFailures,
                maximumIndexBytes: settings.maximumIndexSizeMB * (1 << 20),
                useCache: useCache && settings.useRepositoryCache,
                maximumRefreshSeconds: settings.repositoryRefreshDeadlineSeconds,
                parallelFlatIndexScan: settings.fastRepositoryScan,
                preferCachedIndexFormat: settings.preferCachedIndexFormat
            )
        )
    }

    private func recordSourceOutcome(id: UUID, refreshedAt: Date?, error: String?, persist: Bool = true) {
        guard let position = sources.firstIndex(where: { $0.id == id }) else { return }
        if let refreshedAt {
            sources[position].lastRefreshed = refreshedAt
        }
        sources[position].lastError = error
        if persist { persistSources() }
    }

    // MARK: - Derived indexes

    var filtersRootlessOnly: Bool {
        settings.showOnlyRootlessCompatible && environment.layout == .rootless
    }

    /// Records that can actually work in this layout. Rootless means `/var/jb`,
    /// so an `iphoneos-arm` package (which installs into `/`) is not something to
    /// offer: it would either fail or fight the jailbreak.
    static func isCompatible(_ record: PackageRecord) -> Bool {
        let architecture = record.architecture
        return architecture == "all" || architecture == "iphoneos-arm64"
    }

    private func rebuildIndexes() {
        var merged = PackageIndex()
        for source in sources where source.isEnabled {
            if let index = indexBySource[source.id] {
                merged.merge(index)
            }
        }
        combinedIndex = merged
        updateFirstSeen(from: merged.records)
        sections = Self.buildSections(from: merged, rootlessOnly: filtersRootlessOnly)
        sectionNames = Self.buildSectionNames(from: merged)
        // Derived plans are expensive over large indexes; compute them once when
        // their inputs change instead of from SwiftUI body evaluation.
        refreshUpgradePlan()
        refreshQueueAnalysis()
    }

    /// Groups the merged index by `Section:`, one row per package name (newest
    /// version wins), sections in alphabetical order.
    static func buildSections(from index: PackageIndex, rootlessOnly: Bool) -> [PackageSection] {
        var best: [String: PackageRecord] = [:]
        for record in index.records {
            guard !record.name.isEmpty else { continue }
            if rootlessOnly && !isCompatible(record) { continue }
            if let existing = best[record.name] {
                if DebianVersion.compare(record.version, existing.version) > 0 {
                    best[record.name] = record
                }
            } else {
                best[record.name] = record
            }
        }

        var grouped: [String: [PackageRecord]] = [:]
        for record in best.values {
            let key = record.section.isEmpty ? "Uncategorised" : record.section
            grouped[key, default: []].append(record)
        }

        return grouped.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { name in
                let records = (grouped[name] ?? []).sorted { lhs, rhs in
                    let order = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                    if order == .orderedSame { return lhs.name < rhs.name }
                    return order == .orderedAscending
                }
                return PackageSection(name: name, records: records)
            }
    }

    /// Raw `Section:` values, for the search scope filter. The browse list adds a
    /// synthetic "Uncategorised" bucket, which must not leak in here: filtering by
    /// it would match nothing.
    static func buildSectionNames(from index: PackageIndex) -> [String] {
        var seen: Set<String> = []
        var names: [String] = []
        for record in index.records where !record.section.isEmpty {
            if seen.insert(record.section).inserted {
                names.append(record.section)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func browseRecords(matching query: String) -> [PackageSection] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return sections }
        return sections.compactMap { section in
            let filtered = section.records.filter { record in
                record.name.lowercased().contains(needle)
                    || record.displayName.lowercased().contains(needle)
                    || record.synopsis.lowercased().contains(needle)
            }
            return filtered.isEmpty ? nil : PackageSection(name: section.name, records: filtered)
        }
    }

    // MARK: - Search

    func searchResults(query: String, section: String?) -> [PackageRecord] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var results = combinedIndex.search(needle, section: section, limit: 200)
        if filtersRootlessOnly {
            results = results.filter(Self.isCompatible)
        }
        return results
    }

    // MARK: - Packages

    /// Every version of a package the loaded repositories know, newest first.
    func allRecords(named name: String) -> [PackageRecord] {
        combinedIndex.candidates(named: name)
    }

    func bestRecord(named name: String) -> PackageRecord? {
        combinedIndex.candidates(named: name).first
    }

    /// Newest package versions across enabled repositories. Repositories do not
    /// have a universal publication-date field, so records with a parseable
    /// Date/Timestamp/Last-Modified field sort first; otherwise stable index
    /// arrival order is used as a fallback.
    func newPackageRecords(limit: Int = 200) -> [PackageRecord] {
        var best: [String: PackageRecord] = [:]
        for record in combinedIndex.records {
            if filtersRootlessOnly && !Self.isCompatible(record) { continue }
            if userLibrary.hiddenPackages.contains(record.name) { continue }
            if let existing = best[record.name] {
                if DebianVersion.compare(record.version, existing.version) > 0 {
                    best[record.name] = record
                }
            } else {
                best[record.name] = record
            }
        }
        let cutoff = Calendar.current.date(byAdding: .day, value: -settings.newPackageDays, to: Date()) ?? .distantPast
        return best.values.filter { record in
            (userLibrary.firstSeen[firstSeenKey(for: record)] ?? .distantPast) >= cutoff
        }.sorted { lhs, rhs in
            let ld = userLibrary.firstSeen[firstSeenKey(for: lhs)] ?? .distantPast
            let rd = userLibrary.firstSeen[firstSeenKey(for: rhs)] ?? .distantPast
            if ld != rd { return ld > rd }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }.prefix(limit).map { $0 }
    }


    private func updateFirstSeen(from records: [PackageRecord]) {
        let now = Date()
        var changed = false
        for record in records {
            let key = firstSeenKey(for: record)
            if userLibrary.firstSeen[key] == nil {
                userLibrary.firstSeen[key] = Self.publishedDate(for: record) ?? now
                changed = true
            }
        }
        // Keep discovery history bounded. Entries for packages that vanished
        // from every configured repository and are older than six months no
        // longer contribute to New, so retaining them forever only bloats state.
        let active = Set(records.map { firstSeenKey(for: $0) })
        let cutoff = Calendar.current.date(byAdding: .month, value: -6, to: now) ?? .distantPast
        let stale = userLibrary.firstSeen.filter { !active.contains($0.key) && $0.value < cutoff }.map(\.key)
        if !stale.isEmpty {
            for key in stale { userLibrary.firstSeen[key] = nil }
            changed = true
        }
        if changed { persistUserLibrary() }
    }

    private func firstSeenKey(for record: PackageRecord) -> String {
        "\(record.name)|\(record.version.raw)|\(record.origin?.description ?? "local")"
    }

    static func publishedDate(for record: PackageRecord) -> Date? {
        let candidates = ["Date", "Timestamp", "Last-Modified", "LastModified"]
        let iso = ISO8601DateFormatter()
        let rfc = DateFormatter()
        rfc.locale = Locale(identifier: "en_US_POSIX")
        rfc.timeZone = TimeZone(secondsFromGMT: 0)
        for key in candidates {
            guard let raw = record.stanza.string(key)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }
            if let date = iso.date(from: raw) { return date }
            if let seconds = TimeInterval(raw) { return Date(timeIntervalSince1970: seconds) }
            for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "yyyy-MM-dd HH:mm:ss Z", "yyyy-MM-dd"] {
                rfc.dateFormat = format
                if let date = rfc.date(from: raw) { return date }
            }
        }
        return nil
    }


    /// The newest package that is strictly newer than `version`, for the Upgrade
    /// action.
    func newestRecord(named name: String, newerThan version: DebianVersion) -> PackageRecord? {
        combinedIndex.candidates(named: name).first { DebianVersion.compare($0.version, version) > 0 }
    }

    func installedPackage(named name: String) -> InstalledPackage? {
        installed.package(named: name)
    }

    func isInstalled(_ name: String) -> Bool {
        installed.package(named: name) != nil
    }

    /// How `record` relates to what is installed.
    ///
    /// Versions are compared with `DebianVersion.compare`, never with `==`:
    /// `1.0` and `1:1.0` are equal to dpkg but are two different values.
    func state(for record: PackageRecord) -> PackageState {
        guard let current = installed.package(named: record.name) else { return .notInstalled }
        let order = DebianVersion.compare(record.version, current.version)
        if order > 0 { return .update(to: record.version.raw) }
        if order < 0 { return .olderThanInstalled }
        return .installed
    }

    private func refreshUpgradePlan() {
        upgradePlan = UpgradePlanner(
            available: combinedIndex,
            installed: installed,
            policy: makeResolver().policy
        ).plan()
        upgradableNames = Set(upgradePlan.upgradable.map(\.name))
    }

    /// Whether policy and architecture rules permit a newer candidate.
    func hasUpdate(named name: String) -> Bool {
        upgradableNames.contains(name)
    }

    /// The action a user expects when they tap Install on `record`.
    func defaultAction(for record: PackageRecord) -> PackageAction {
        guard let current = installed.package(named: record.name) else { return .install(record) }
        let order = DebianVersion.compare(record.version, current.version)
        if order > 0 { return .upgrade(record) }
        if order < 0 { return .downgrade(record) }
        return .reinstall(record)
    }

    // MARK: - Queue

    var queueCount: Int { queue.count }

    var packageHistory: [PackageActivity] { userLibrary.history }

    var bookmarkedRecords: [PackageRecord] {
        userLibrary.bookmarks.compactMap { bestRecord(named: $0) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func isBookmarked(_ name: String) -> Bool { userLibrary.bookmarks.contains(name) }

    func toggleBookmark(_ name: String) {
        if userLibrary.bookmarks.contains(name) { userLibrary.bookmarks.remove(name) }
        else { userLibrary.bookmarks.insert(name) }
        persistUserLibrary()
    }

    func isHidden(_ name: String) -> Bool { userLibrary.hiddenPackages.contains(name) }

    func toggleHidden(_ name: String) {
        if userLibrary.hiddenPackages.contains(name) { userLibrary.hiddenPackages.remove(name) }
        else { userLibrary.hiddenPackages.insert(name) }
        persistUserLibrary()
        rebuildIndexes()
    }

    func isHeld(_ name: String) -> Bool { packagePolicy.isHeld(name) }

    func setHeld(_ name: String, held: Bool) {
        packagePolicy.pin(held ? .hold : nil, for: name)
        persistPackagePolicy()
        rebuildIndexes()
    }

    func pinVersion(_ record: PackageRecord) {
        packagePolicy.pin(.version(record.version.raw), for: record.name)
        persistPackagePolicy()
        rebuildIndexes()
    }

    func clearPin(_ name: String) {
        packagePolicy.pin(nil, for: name)
        persistPackagePolicy()
        rebuildIndexes()
    }

    func setSourcePriority(id: UUID, priority: Int) {
        guard let source = sources.first(where: { $0.id == id }) else { return }
        packagePolicy.setPriority(priority, forSource: source.normalizedURL)
        persistPackagePolicy()
        rebuildIndexes()
    }

    func sourcePriority(id: UUID) -> Int {
        guard let source = sources.first(where: { $0.id == id }) else { return PackagePolicy.defaultPriority }
        return packagePolicy.priority(forSource: source.normalizedURL)
    }

    private func persistPackagePolicy() {
        do {
            try policyStore.save(packagePolicy)
            policyPersistenceError = nil
        } catch {
            policyPersistenceError = "Package policy could not be saved (\(AuroraFormat.message(for: error)))."
        }
    }

    private func persistUserLibrary() {
        do { try userLibrary.save() }
        catch { lastError = "Could not save bookmarks/history: \(AuroraFormat.message(for: error))" }
    }

    func stage(_ action: PackageAction) {
        queue.stage(action)
        statusMessage = "\(action.kind.label): \(action.name)"
        refreshQueueAnalysis()
    }

    func unstage(_ name: String) {
        queue.unstage(name: name)
        refreshQueueAnalysis()
    }

    func clearQueue() {
        queue.removeAll()
        refreshQueueAnalysis()
    }

    func recordCompletedTransaction(_ plan: TransactionPlan) {
        var activities: [PackageActivity] = []
        activities += plan.installed.map { PackageActivity(package: $0.name, version: $0.version.raw, kind: .install) }
        activities += plan.reinstalled.map { PackageActivity(package: $0.name, version: $0.version.raw, kind: .reinstall) }
        activities += plan.upgraded.map { PackageActivity(package: $0.name, version: $0.version.raw, kind: .upgrade) }
        activities += plan.downgraded.map { PackageActivity(package: $0.name, version: $0.version.raw, kind: .downgrade) }
        activities += plan.removed.map {
            PackageActivity(
                package: $0.package.name,
                version: $0.package.version.raw,
                kind: $0.purge ? .purge : .remove
            )
        }
        userLibrary.history.insert(contentsOf: activities, at: 0)
        if userLibrary.history.count > 500 {
            userLibrary.history = Array(userLibrary.history.prefix(500))
        }
        persistUserLibrary()
    }

    func stagedAction(for name: String) -> PackageAction? {
        queue.action(for: name)
    }

    /// A downgrade has to be asked for explicitly: `DependencyResolver` refuses
    /// version regressions unless the policy allows them, and an "Upgrade" action
    /// that resolves downwards must stay refused.
    var queueContainsDowngrade: Bool {
        for action in queue.actions {
            switch action {
            case .downgrade:
                return true
            case .reinstall(let record):
                if let current = installed.package(named: record.name),
                   DebianVersion.compare(record.version, current.version) < 0 {
                    return true
                }
            case .install, .upgrade, .remove:
                break
            }
        }
        return false
    }

    func makeResolver() -> DependencyResolver {
        var allowed = Set(environment.compatibleArchitectures)
        if environment.layout == .rootless && settings.showOnlyRootlessCompatible {
            allowed = [environment.architecture]
        }
        let policy = DependencyResolver.Policy(
            architecture: environment.architecture,
            allowedArchitectures: allowed,
            packagePolicy: packagePolicy,
            installRecommends: false,
            allowDowngrades: queueContainsDowngrade,
            removeDependentsWithPackage: true,
            protectEssential: true,
            removeOrphanedDependencies: false
        )
        return DependencyResolver(available: combinedIndex, installed: installed, policy: policy)
    }

    /// Turns the staged queue into a plan, without throwing, so the queue screen
    /// can show resolution failures as the user edits it.
    func attemptPlan() -> Result<TransactionPlan, ResolutionFailure> {
        makeResolver().attempt(queue)
    }

    /// Recomputes the queue screen's model. Called from every mutation that can
    /// change it: staging, the installed database, the indexes, the policy.
    func refreshQueueAnalysis() {
        guard !queue.isEmpty else {
            queueAnalysis = QueueAnalysis()
            return
        }
        queueAnalysis = QueueAnalyzer.analyse(
            queue: queue,
            installed: installed,
            index: combinedIndex,
            architecture: environment.architecture,
            attempt: attemptPlan()
        )
    }

    // MARK: - Installed database

    func reloadInstalled() async {
        let client = DpkgClient(environment: environment)
        let outcome: InstalledLoadOutcome = await Task.detached(priority: .userInitiated) {
            do {
                return InstalledLoadOutcome(database: try client.loadDatabase(), failure: nil)
            } catch {
                return InstalledLoadOutcome(database: InstalledPackageDatabase(), failure: AuroraFormat.message(for: error))
            }
        }.value
        installed = outcome.database
        installedError = outcome.failure
        refreshUpgradePlan()
        refreshQueueAnalysis()
    }

    // MARK: - Settings

    func setAutoRefresh(_ value: Bool) {
        settings.autoRefreshOnLaunch = value
        persistSettings()
    }

    func setIgnoreSignatureFailures(_ value: Bool) {
        settings.ignoreSignatureFailures = value
        persistSettings()
    }

    func setRootlessOnly(_ value: Bool) {
        settings.showOnlyRootlessCompatible = value
        persistSettings()
        rebuildIndexes()
    }

    func setAllowRootfulConversion(_ value: Bool) {
        settings.allowRootfulConversion = value
        persistSettings()
    }

    func canOfferRootfulConversion(for record: PackageRecord) -> Bool {
        environment.layout == .rootless
            && settings.allowRootfulConversion
            && record.architecture == "iphoneos-arm"
    }

    func setDepictionPreference(_ value: DepictionPreference) {
        settings.depictionPreference = value
        persistSettings()
    }

    func setAutoRefreshOnLaunch(_ value: Bool) {
        settings.autoRefreshOnLaunch = value
        persistSettings()
    }

    func setShowPackageIcons(_ value: Bool) {
        settings.showPackageIcons = value
        persistSettings()
    }

    func setCompactPackageRows(_ value: Bool) {
        settings.compactPackageRows = value
        persistSettings()
    }

    func setShowPackageDescriptions(_ value: Bool) {
        settings.showPackageDescriptions = value
        persistSettings()
    }

    func setSkipFailedRepositories(_ value: Bool) {
        settings.skipFailedRepositories = value
        persistSettings()
    }

    func setRefreshConcurrency(_ value: Int) {
        settings.refreshConcurrency = min(12, max(2, value))
        persistSettings()
    }

    func setRepositoryTimeoutSeconds(_ value: Int) {
        settings.repositoryTimeoutSeconds = min(60, max(3, value))
        persistSettings()
    }

    func setRefreshFailedRepositories(_ value: Bool) {
        settings.refreshFailedRepositories = value
        persistSettings()
    }

    func setFastRepositoryScan(_ value: Bool) {
        settings.fastRepositoryScan = value
        persistSettings()
    }

    func setRepositoryRefreshDeadlineSeconds(_ value: Int) {
        settings.repositoryRefreshDeadlineSeconds = min(180, max(10, value))
        persistSettings()
    }

    func setPreferCachedIndexFormat(_ value: Bool) {
        settings.preferCachedIndexFormat = value
        persistSettings()
    }

    func setUseRepositoryCache(_ value: Bool) {
        settings.useRepositoryCache = value
        persistSettings()
    }

    func setMaximumIndexSizeMB(_ value: Int) {
        settings.maximumIndexSizeMB = min(1024, max(32, value))
        persistSettings()
    }

    func setAutoCleanRepositoryData(_ value: Bool) {
        settings.autoCleanRepositoryData = value
        persistSettings()
    }

    func setAutoCleanDownloadedPackages(_ value: Bool) {
        settings.autoCleanDownloadedPackages = value
        persistSettings()
    }

    func setShowRepositoryWarnings(_ value: Bool) {
        settings.showRepositoryWarnings = value
        persistSettings()
    }

    func setConfirmQueueBeforeInstall(_ value: Bool) {
        settings.confirmQueueBeforeInstall = value
        persistSettings()
    }

    func setRefreshAfterTransaction(_ value: Bool) {
        settings.refreshAfterTransaction = value
        persistSettings()
    }

    func applyPerformancePreset(_ preset: String) {
        switch preset {
        case "aggressive":
            settings.refreshConcurrency = 12
            settings.repositoryTimeoutSeconds = 6
            settings.repositoryRefreshDeadlineSeconds = 20
            settings.fastRepositoryScan = true
            settings.preferCachedIndexFormat = true
            settings.useRepositoryCache = true
        case "conservative":
            settings.refreshConcurrency = 4
            settings.repositoryTimeoutSeconds = 20
            settings.repositoryRefreshDeadlineSeconds = 60
            settings.fastRepositoryScan = false
            settings.preferCachedIndexFormat = true
            settings.useRepositoryCache = true
        default:
            settings.refreshConcurrency = 8
            settings.repositoryTimeoutSeconds = 12
            settings.repositoryRefreshDeadlineSeconds = 30
            settings.fastRepositoryScan = true
            settings.preferCachedIndexFormat = true
            settings.useRepositoryCache = true
        }
        persistSettings()
    }

    func resetSettings() {
        let tabs = settings.tabs
        settings = AuroraSettings(tabs: tabs)
        persistSettings()
        rebuildIndexes()
    }

    func setNewPackageDays(_ value: Int) {
        settings.newPackageDays = min(90, max(1, value))
        persistSettings()
    }

    func setHomePackageLimit(_ value: Int) {
        settings.homePackageLimit = min(20, max(3, value))
        persistSettings()
    }

    func setTabs(_ tabs: [AppTab]) {
        settings.tabs = AuroraSettings.sanitizedTabs(tabs)
        persistSettings()
    }

    func resetTabs() {
        setTabs(AppTab.defaultTabs)
    }

    private func persistSettings() {
        do {
            try settingsStore.save(settings)
            settingsPersistenceError = nil
        } catch {
            settingsPersistenceError = "Settings could not be saved (\(AuroraFormat.message(for: error)))."
        }
    }

    // MARK: - Caches

    /// Deletes the index and package caches. The downloaded `.deb` files are what
    /// actually take space, so this is a real "free up storage" action.
    func clearCaches() -> String {
        URLCache.shared.removeAllCachedResponses()

        let manager = FileManager.default
        // LocalPackages contains security-scoped document imports copied into
        // Aurora's sandbox. Queue entries can still reference those files, so it
        // is staged transaction data rather than disposable cache.
        let directories = [
            environment.cacheDirectory + "/indexes",
            environment.cacheDirectory + "/packages",
        ]
        var removed = 0
        for directory in directories where manager.fileExists(atPath: directory) {
            if (try? manager.removeItem(atPath: directory)) != nil { removed += 1 }
        }

        // The in-memory indexes came from those files, so drop them too: leaving
        // them would make the UI claim packages exist while the cache is gone.
        indexBySource = [:]
        indexErrors = [:]
        indexWarnings = [:]
        signatureStatus = [:]
        rebuildIndexes()

        return removed == 0
            ? "Nothing was cached."
            : "Caches cleared. Refresh to load the repositories again."
    }

    /// Deep-clean repository runtime and disk cache while preserving source
    /// configuration, installed packages, downloaded .debs and local queue files.
    func cleanRepositoryData(clearFailures: Bool = true) -> String {
        let manager = FileManager.default
        let indexes = environment.cacheDirectory + "/indexes"
        var bytes: Int64 = 0
        if let enumerator = manager.enumerator(atPath: indexes) {
            for case let relative as String in enumerator {
                let path = (indexes as NSString).appendingPathComponent(relative)
                if let attrs = try? manager.attributesOfItem(atPath: path),
                   let size = attrs[.size] as? NSNumber { bytes += size.int64Value }
            }
        }
        try? manager.removeItem(atPath: indexes)
        try? manager.createDirectory(atPath: indexes, withIntermediateDirectories: true)
        indexBySource = [:]
        indexWarnings = [:]
        signatureStatus = [:]
        if clearFailures {
            indexErrors = [:]
            for index in sources.indices { sources[index].lastError = nil }
        }
        for index in sources.indices { sources[index].lastRefreshed = nil }
        persistSources()
        rebuildIndexes()
        return "Repository data cleaned (\(AuroraFormat.bytes(Int(bytes)))). Refresh to rebuild indexes."
    }

    /// Removes downloaded repository package archives without touching indexes
    /// or staged document imports. Safe after a completed transaction.
    func pruneDownloadedPackages() -> String {
        let directory = environment.cacheDirectory + "/packages"
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory) else { return "No downloaded packages to clean." }
        do {
            try manager.removeItem(atPath: directory)
            try manager.createDirectory(atPath: directory, withIntermediateDirectories: true)
            return "Downloaded package cache cleaned."
        } catch {
            return "Could not clean downloaded packages: \(AuroraFormat.message(for: error))"
        }
    }

    /// Remove copied local .deb files that are no longer referenced by the
    /// current queue. This keeps document imports from accumulating forever.
    func pruneUnusedLocalPackages() -> String {
        let directory = environment.cacheDirectory + "/LocalPackages"
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: directory) else {
            return "No local packages to clean."
        }
        let referenced = Set(queue.actions.compactMap { action -> String? in
            switch action {
            case .install(let record), .reinstall(let record), .upgrade(let record), .downgrade(let record):
                guard LocalPackageLoader.isLocalRecord(record) else { return nil }
                return record.filename.map { URL(fileURLWithPath: $0).lastPathComponent }
            case .remove:
                return nil
            }
        })
        var removed = 0
        for name in names where !referenced.contains(name) {
            let path = (directory as NSString).appendingPathComponent(name)
            if (try? manager.removeItem(atPath: path)) != nil { removed += 1 }
        }
        return removed == 0 ? "No unused local packages." : "Removed \(removed) unused local package\(removed == 1 ? "" : "s")."
    }

    func cacheBreakdown() -> [(name: String, bytes: Int)] {
        let manager = FileManager.default
        let root = environment.cacheDirectory
        let categories = [
            ("Repository indexes", root + "/indexes"),
            ("Downloaded packages", root + "/packages"),
            ("Local packages", root + "/LocalPackages")
        ]
        return categories.map { name, path in
            (name, directorySize(path, manager: manager))
        }
    }

    private func directorySize(_ path: String, manager: FileManager) -> Int {
        guard let enumerator = manager.enumerator(atPath: path) else { return 0 }
        var total = 0
        for case let relative as String in enumerator {
            let full = (path as NSString).appendingPathComponent(relative)
            if let attributes = try? manager.attributesOfItem(atPath: full),
               let size = attributes[.size] as? NSNumber {
                total += size.intValue
            }
        }
        return total
    }

    var diagnosticsReport: String {
        var lines = [
            "Aurora \(AuroraBuildInfo.version) (\(AuroraBuildInfo.build))",
            "Layout: \(layoutName)",
            "Architecture: \(environment.architecture)",
            "Repositories: \(sources.count) total, \(sources.filter(\.isEnabled).count) enabled, \(failedSourceIDs.count) failed",
            "Packages loaded: \(totalPackageCount)",
            "Installed packages: \(installed.count)",
            "Updates: \(upgradePlan.upgradable.count)",
            "Held/pinned: \(packagePolicy.pins.count)",
            "Cache: \(AuroraFormat.bytes(cacheSizeBytes()))",
            ""
        ]
        for source in sources {
            var line = "[\(source.isEnabled ? "enabled" : "disabled")] \(source.name) — \(source.normalizedURL) — \(packageCount(for: source.id)) packages"
            if let error = indexErrors[source.id] { line += " — ERROR: \(error)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Best-effort size of everything Aurora has cached on disk.
    func cacheSizeBytes() -> Int {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(atPath: environment.cacheDirectory) else { return 0 }
        var total = 0
        for case let relative as String in enumerator {
            let full = (environment.cacheDirectory as NSString).appendingPathComponent(relative)
            if let attributes = try? manager.attributesOfItem(atPath: full),
               let size = attributes[.size] as? NSNumber {
                total += size.intValue
            }
        }
        return total
    }

    // MARK: - Persistence

    private func persistSources() {
        do {
            try sourceStore.save(RepositoryList(sources: sources))
            sourcesPersistenceError = nil
        } catch {
            sourcesPersistenceError = "Repository list could not be saved (\(AuroraFormat.message(for: error))); changes apply to this session only."
        }
    }

    /// Where the two JSON files live, for the About section.
    var stateDirectoryDescription: String {
        (sourceStore.path as NSString).deletingLastPathComponent
    }

    // MARK: - Naming

    /// Derives a repository name from its host, so the user does not have to type
    /// one: `https://repo.chariz.com` becomes `chariz.com`.
    static func derivedName(for urlText: String) -> String {
        guard let host = URL(string: urlText)?.host, !host.isEmpty else { return urlText }
        var name = host
        for prefix in ["www.", "repo.", "apt.", "get."] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        return name
    }
}
