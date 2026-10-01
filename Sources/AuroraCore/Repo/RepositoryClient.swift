import Foundation

public enum RepositoryError: Error, CustomStringConvertible {
    case duplicateSource(String)
    case invalidURL(String)
    case noPackageIndex(source: String, tried: [String])
    case checksumMismatch(path: String, algorithm: HashAlgorithm, expected: String, actual: String)
    case sizeMismatch(path: String, expected: Int, actual: Int)
    case signatureRequired(source: String, reason: String)
    case decompression(path: String, underlying: Error)
    case indexTooLarge(path: String, bytes: Int)
    case packageNotInSource(String)
    case refreshTimedOut(source: String, seconds: Int)

    public var description: String {
        switch self {
        case .duplicateSource(let url): return "\(url) is already added"
        case .invalidURL(let url): return "\(url) is not a valid repository URL"
        case .noPackageIndex(let source, let tried):
            let list = tried.prefix(4).joined(separator: ", ")
            return "\(source) published no package index Aurora can read (tried \(list))"
        case .checksumMismatch(let path, let algorithm, let expected, let actual):
            return "\(path) has the wrong \(algorithm.rawValue): expected \(expected), got \(actual)"
        case .sizeMismatch(let path, let expected, let actual):
            return "\(path) is \(actual) bytes, the index says \(expected)"
        case .signatureRequired(let source, let reason):
            return "\(source) is not signed by a trusted key: \(reason)"
        case .decompression(let path, let underlying):
            return "\(path) could not be decompressed: \(underlying)"
        case .indexTooLarge(let path, let bytes):
            return "\(path) expands to \(bytes / (1 << 20)) MB, which is beyond the safety limit"
        case .packageNotInSource(let name):
            return "\(name) has no download location in this repository"
        case .refreshTimedOut(let source, let seconds):
            return "\(source) did not finish refreshing within \(seconds) seconds"
        }
    }
}

/// Client-side rules for what counts as an acceptable repository.
public struct RepositoryPolicy: Sendable {
    /// Refuse to load an index whose signature does not verify. Off by default:
    /// most jailbreak repositories are unsigned, and refusing them would leave a
    /// user with an empty store. The UI shows the state of every source instead.
    public var requireSignature: Bool
    /// Flat repositories carry no `Release` file at all, so a signature is
    /// impossible there by construction.
    public var allowFlatUnsigned: Bool
    /// Refuse an index that decompresses beyond this.
    public var maximumIndexBytes: Int
    public var useCache: Bool
    /// Hard wall-clock deadline for one complete repository refresh. This is
    /// separate from the per-request transport timeout so a broken source cannot
    /// consume the worker indefinitely while Aurora probes metadata/index paths.
    public var maximumRefreshSeconds: Int
    /// Race flat-repository Packages compression variants instead of waiting for
    /// serial 404/timeouts. Release-backed repositories already advertise the
    /// valid paths, so they do not need probing.
    public var parallelFlatIndexScan: Bool
    public var preferCachedIndexFormat: Bool

    public init(
        requireSignature: Bool = false,
        allowFlatUnsigned: Bool = true,
        maximumIndexBytes: Int = 256 * (1 << 20),
        useCache: Bool = true,
        maximumRefreshSeconds: Int = 45,
        parallelFlatIndexScan: Bool = true,
        preferCachedIndexFormat: Bool = true
    ) {
        self.requireSignature = requireSignature
        self.allowFlatUnsigned = allowFlatUnsigned
        self.maximumIndexBytes = maximumIndexBytes
        self.useCache = useCache
        self.maximumRefreshSeconds = min(180, max(10, maximumRefreshSeconds))
        self.parallelFlatIndexScan = parallelFlatIndexScan
        self.preferCachedIndexFormat = preferCachedIndexFormat
    }

    public static let `default` = RepositoryPolicy()
}

/// Everything one refresh produced.
public struct RepositoryRefresh: Sendable {
    public let source: RepositorySource
    public let release: ReleaseFile?
    public let signature: SignatureStatus
    public let records: [PackageRecord]
    public let warnings: [String]
    public let fetchedAt: Date

    public var index: PackageIndex { PackageIndex(records: records) }
}

/// Fetches repository metadata, verifies it, and turns it into records.
///
/// The order of operations is the part that matters and is deliberately apt's:
/// fetch the signed `Release`, use *its* hashes to decide which `Packages` file to
/// take, verify size and digest **before** parsing, and only then trust a single
/// byte of package metadata.
public actor RepositoryClient {

    private let environment: JailbreakEnvironment
    private let downloader: HTTPDownloader
    private let signatureVerifier: SignatureVerifier
    private let policy: RepositoryPolicy
    private let cache: IndexCache?

    /// Preference order for index compression: xz is by far the smallest thing
    /// every modern repository publishes.
    public static let formatPreference: [CompressionFormat] = [.xz, .gzip, .zstd, .bzip2, .lzma, .plain]

    public init(
        environment: JailbreakEnvironment,
        downloader: HTTPDownloader = HTTPDownloader(),
        signatureVerifier: SignatureVerifier? = nil,
        policy: RepositoryPolicy = .default,
        cacheDirectory: String? = nil
    ) {
        self.environment = environment
        self.downloader = downloader
        self.signatureVerifier = signatureVerifier ?? SignatureVerifier(environment: environment)
        self.policy = policy
        let directory = cacheDirectory ?? (environment.cacheDirectory + "/indexes")
        self.cache = policy.useCache ? IndexCache(directory: directory) : nil
    }

    /// Absolute URL of a package inside the repository that published it.
    public static func packageURL(_ record: PackageRecord, in source: RepositorySource) -> URL? {
        guard let filename = record.filename, !filename.isEmpty else { return nil }
        if filename.hasPrefix("http://") || filename.hasPrefix("https://") {
            return URL(string: filename)
        }
        var base = source.normalizedURL
        if !base.hasSuffix("/") { base += "/" }
        let relative = filename.hasPrefix("/") ? String(filename.dropFirst()) : filename
        return URL(string: base + relative)
    }

    private func url(_ source: RepositorySource, path: String) -> URL? {
        var base = source.normalizedURL
        if !base.hasSuffix("/") { base += "/" }
        return URL(string: base + path)
    }

    // MARK: - Refresh

    public func refresh(_ source: RepositorySource) async throws -> RepositoryRefresh {
        guard source.isValid else { throw RepositoryError.invalidURL(source.url) }
        let deadline = policy.maximumRefreshSeconds
        return try await withThrowingTaskGroup(of: RepositoryRefresh.self) { group in
            group.addTask { try await self.refreshWithoutDeadline(source) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(deadline) * 1_000_000_000)
                try Task.checkCancellation()
                throw RepositoryError.refreshTimedOut(source: source.name, seconds: deadline)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw RepositoryError.refreshTimedOut(source: source.name, seconds: deadline)
            }
            return first
        }
    }

    private func refreshWithoutDeadline(_ source: RepositorySource) async throws -> RepositoryRefresh {

        var warnings: [String] = []
        var release: ReleaseFile?
        var signature: SignatureStatus = .unsigned

        if source.releasePath != nil {
            let outcome = await fetchRelease(source)
            release = outcome.release
            signature = outcome.signature
            warnings.append(contentsOf: outcome.warnings)
            if policy.requireSignature, !signature.isVerified {
                // A repository that failed verification is a hard stop: that is
                // the entire point of signing metadata. Unsigned counts as
                // unverified, and so does "no verifier available" — a user who
                // asks for signatures must not silently get less than that.
                throw RepositoryError.signatureRequired(source: source.name, reason: signature.shortDescription)
            }
        } else if !policy.allowFlatUnsigned {
            throw RepositoryError.signatureRequired(source: source.name, reason: "flat repositories cannot be signed")
        } else {
            warnings.append("Flat repository: no Release file, so packages cannot be checksum-verified.")
        }

        let configuredArchitectures = source.architectures.isEmpty ? environment.compatibleArchitectures : source.architectures
        // A flat repository has one Packages file, not one per architecture.
        // Fetching it once per compatible architecture duplicates every record.
        let architectures = source.isFlat ? [configuredArchitectures.first ?? environment.architecture] : configuredArchitectures
        var records: [PackageRecord] = []
        var tried: [String] = []

        for architecture in architectures {
            for component in components(for: source) {
                var paths = indexPaths(source: source, architecture: architecture, component: component)
                // Flat repositories do not publish a Release manifest. Prefer the
                // compression format that worked last time, but always fall back to
                // every supported format. Repositories commonly change Packages.xz
                // to Packages.gz (or vice versa); pinning the cached format forever
                // makes a healthy source appear permanently broken.
                if release == nil, policy.preferCachedIndexFormat,
                   let preferred = await cache?.preferredFormat(for: source.normalizedURL),
                   let position = paths.firstIndex(where: { $0.1 == preferred }) {
                    let hit = paths.remove(at: position)
                    paths.insert(hit, at: 0)
                }
                var loaded = false

                if release == nil && policy.parallelFlatIndexScan {
                    let candidates = paths.compactMap { path, format -> (URL, String, CompressionFormat)? in
                        guard let indexURL = url(source, path: path) else { return nil }
                        return (indexURL, path, format)
                    }
                    let winner: (String, CompressionFormat, Data, [String])? = await withTaskGroup(of: (String, CompressionFormat, Data?, [String]).self, returning: (String, CompressionFormat, Data, [String])?.self) { group in
                        for (indexURL, path, format) in candidates {
                            group.addTask {
                                let outcome = await self.fetch(indexURL: indexURL, checksum: nil)
                                return (path, format, outcome.data, outcome.warnings)
                            }
                        }
                        var collectedWarnings: [String] = []
                        while let result = await group.next() {
                            collectedWarnings.append(contentsOf: result.3)
                            if let payload = result.2 {
                                group.cancelAll()
                                return (result.0, result.1, payload, collectedWarnings)
                            }
                        }
                        return nil
                    }
                    if let (path, format, payload, scanWarnings) = winner {
                        warnings.append(contentsOf: scanWarnings)
                        tried.append(contentsOf: paths.map(\.0))
                        do {
                            let decompressed = try Decompressor.decompress(payload, format: format)
                            guard decompressed.count <= policy.maximumIndexBytes else {
                                throw RepositoryError.indexTooLarge(path: path, bytes: decompressed.count)
                            }
                            let origin = RepositoryID(url: source.normalizedURL, suite: source.suite, component: component)
                            records.append(contentsOf: ControlParser.parse(decompressed).compactMap { stanza in
                                guard stanza.has("Package") else { return nil }
                                return PackageRecord(stanza: stanza, origin: origin)
                            })
                            await cache?.rememberPreferredFormat(format, for: source.normalizedURL)
                            loaded = true
                        } catch {
                            warnings.append("\(path): \(error)")
                        }
                    }
                }

                if !loaded {
                for (path, format) in paths {
                    tried.append(path)
                    guard let indexURL = url(source, path: path) else { continue }

                    // With a Release file, only paths it vouches for are allowed.
                    // This also makes format discovery free: paths absent from Release
                    // never generate a network request.
                    var expected: ReleaseFile.Checksum?
                    if let release {
                        expected = release.checksum(forPath: path)
                        if expected == nil { continue }
                    }

                    let outcome = await fetch(indexURL: indexURL, checksum: expected)
                    warnings.append(contentsOf: outcome.warnings)
                    guard let payload = outcome.data else { continue }

                    let decompressed: Data
                    do {
                        decompressed = try Decompressor.decompress(payload, format: format)
                    } catch {
                        warnings.append("\(path): \(error)")
                        continue
                    }
                    guard decompressed.count <= policy.maximumIndexBytes else {
                        throw RepositoryError.indexTooLarge(path: path, bytes: decompressed.count)
                    }

                    let origin = RepositoryID(
                        url: source.normalizedURL,
                        suite: source.suite,
                        component: component
                    )
                    let stanzas = ControlParser.parse(decompressed)
                    records.append(contentsOf: stanzas.compactMap { stanza in
                        guard stanza.has("Package") else { return nil }
                        return PackageRecord(stanza: stanza, origin: origin)
                    })
                    if release == nil {
                        await cache?.rememberPreferredFormat(format, for: source.normalizedURL)
                    }
                    loaded = true
                    break
                }
                }
                if !loaded && source.isFlat {
                    // Nothing to add: the caller turns this into a per-source
                    // error the user can act on.
                    continue
                }
            }
        }

        if records.isEmpty {
            throw RepositoryError.noPackageIndex(source: source.name, tried: tried)
        }

        return RepositoryRefresh(
            source: source,
            release: release,
            signature: signature,
            records: records,
            warnings: warnings,
            fetchedAt: Date()
        )
    }

    private func components(for source: RepositorySource) -> [String] {
        if source.isFlat { return [""] }
        return source.components.isEmpty ? ["main"] : source.components
    }

    /// `(path, format)` pairs for one component and architecture, best format first.
    private func indexPaths(
        source: RepositorySource,
        architecture: String,
        component: String
    ) -> [(String, CompressionFormat)] {
        let directory: String
        if source.isFlat {
            let prefix = source.flatPathPrefix
            directory = prefix.isEmpty ? "" : prefix + "/"
        } else {
            directory = "dists/\(source.suite)/\(component)/binary-\(architecture)/"
        }
        return Self.formatPreference.map { format in
            let suffix: String
            switch format {
            case .plain: suffix = ""
            case .gzip: suffix = ".gz"
            case .xz: suffix = ".xz"
            case .lzma: suffix = ".lzma"
            case .bzip2: suffix = ".bz2"
            case .zstd: suffix = ".zst"
            }
            return (directory + "Packages" + suffix, format)
        }
    }

    // MARK: - Release

    private func fetchRelease(
        _ source: RepositorySource
    ) async -> (release: ReleaseFile?, signature: SignatureStatus, warnings: [String]) {
        guard let suite = source.releasePath else { return (nil, .unsigned, []) }
        var warnings: [String] = []

        if let inReleaseURL = url(source, path: suite.replacingOccurrences(of: "Release", with: "InRelease")),
           let (data, response) = try? await downloader.data(for: inReleaseURL),
           response.statusCode == 200 {
            let verifier = SignatureVerifier(
                environment: environment,
                additionalArmoredKeys: source.trustedKeys
            )
            let (status, payload) = verifier.verify(clearsigned: data)
            if let payload,
               let stanza = ControlParser.parse(payload).first {
                return (ReleaseFile(stanza: stanza), status, warnings)
            }
            warnings.append("InRelease is not a readable Release file; falling back to Release + Release.gpg")
        }

        guard let releaseURL = url(source, path: suite),
              let (data, response) = try? await downloader.data(for: releaseURL),
              response.statusCode == 200,
              let stanza = ControlParser.parse(data).first else {
            return (nil, .unsigned, warnings + ["No Release file was published."])
        }

        var status: SignatureStatus = .unsigned
        if let signatureURL = url(source, path: suite + ".gpg"),
           let (signature, signatureResponse) = try? await downloader.data(for: signatureURL),
           signatureResponse.statusCode == 200 {
            let verifier = SignatureVerifier(
                environment: environment,
                additionalArmoredKeys: source.trustedKeys
            )
            status = verifier.verifyDetached(signature: signature, payload: data)
        } else if let signatureURL = url(source, path: suite + ".asc"),
                  let (signature, signatureResponse) = try? await downloader.data(for: signatureURL),
                  signatureResponse.statusCode == 200 {
            let verifier = SignatureVerifier(
                environment: environment,
                additionalArmoredKeys: source.trustedKeys
            )
            status = verifier.verifyDetached(signature: signature, payload: data)
        } else {
            warnings.append("Release is present but no Release.gpg/Release.asc accompanies it.")
        }
        return (ReleaseFile(stanza: stanza), status, warnings)
    }

    // MARK: - Fetching one index

    /// Fetches an index, using the cache when the server confirms nothing changed,
    /// and verifying size and digest when the Release file stated them.
    ///
    /// Warnings are returned rather than accumulated through an `inout` parameter:
    /// this method suspends, and passing a mutable local across a suspension point
    /// is exactly the kind of aliasing the compiler is right to complain about.
    private func fetch(indexURL: URL, checksum: ReleaseFile.Checksum?) async -> (data: Data?, warnings: [String]) {
        var warnings: [String] = []
        var headers: [String: String] = [:]
        let cached = await cache?.entry(for: indexURL.absoluteString)
        if let cached {
            if let etag = cached.etag { headers["If-None-Match"] = etag }
            if let modified = cached.lastModified { headers["If-Modified-Since"] = modified }
        }

        let data: Data
        do {
            let (body, response) = try await downloader.data(for: indexURL, headers: headers)
            if response.statusCode == 304, let cached {
                data = cached.payload
            } else if response.statusCode == 200 {
                data = body
                await cache?.store(
                    payload: body,
                    for: indexURL.absoluteString,
                    etag: response.value(forHTTPHeaderField: "ETag"),
                    lastModified: response.value(forHTTPHeaderField: "Last-Modified")
                )
            } else {
                return (nil, warnings)
            }
        } catch {
            // A network hiccup with a warm cache should not empty the store.
            if let cached {
                warnings.append("\(indexURL.lastPathComponent): using the cached copy (\(error))")
                data = cached.payload
            } else {
                warnings.append("\(indexURL.lastPathComponent): \(error)")
                return (nil, warnings)
            }
        }

        if let checksum {
            if data.count != checksum.size {
                warnings.append("\(indexURL.lastPathComponent): \(RepositoryError.sizeMismatch(path: indexURL.lastPathComponent, expected: checksum.size, actual: data.count))")
                return (nil, warnings)
            }
            guard let actual = try? Hashing.hexDigest(of: data, using: checksum.algorithm) else {
                return (nil, warnings)
            }
            guard Hashing.matches(actual, checksum.hex) else {
                warnings.append("\(indexURL.lastPathComponent): \(RepositoryError.checksumMismatch(path: indexURL.lastPathComponent, algorithm: checksum.algorithm, expected: checksum.hex, actual: actual))")
                return (nil, warnings)
            }
        }
        return (data, warnings)
    }

    // MARK: - Packages

    /// Downloads a `.deb`, verifying its digest and size, and returns the local path.
    @discardableResult
    public func fetchPackage(
        _ record: PackageRecord,
        from source: RepositorySource,
        progress: ((Int64, Int64) -> Void)? = nil
    ) async throws -> String {
        guard let remote = Self.packageURL(record, in: source) else {
            throw RepositoryError.packageNotInSource(record.name)
        }
        let fileName = "\(record.name)_\(record.version.raw)_\(record.architecture).deb"
            .replacingOccurrences(of: "/", with: "_")
        let directory = environment.cacheDirectory + "/packages"
        let destination = (directory as NSString).appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: destination),
           try verifyDownloadedFile(at: destination, record: record) {
            progress?(record.downloadSize.map(Int64.init) ?? 0, record.downloadSize.map(Int64.init) ?? 0)
            return destination
        }

        try await downloader.download(from: remote, to: destination, progress: progress)

        guard try verifyDownloadedFile(at: destination, record: record) else {
            try? FileManager.default.removeItem(atPath: destination)
            throw RepositoryError.checksumMismatch(
                path: remote.lastPathComponent,
                algorithm: record.bestDigest?.algorithm ?? .sha256,
                expected: record.bestDigest?.hex ?? "",
                actual: "downloaded file"
            )
        }
        return destination
    }

    /// Checks the digest and size a record declared. Returns false when the file
    /// cannot be vouched for, which is treated as a failed download.
    public func verifyDownloadedFile(at path: String, record: PackageRecord) throws -> Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.intValue
        if let expected = record.downloadSize, let size, size != expected { return false }
        if let digest = record.bestDigest {
            guard let actual = try? Hashing.hexDigest(ofFileAt: path, using: digest.algorithm) else { return false }
            return Hashing.matches(actual, digest.hex)
        }
        // No digest published: fall back to the pool file's own integrity marker.
        let deb = try? DebArchive(path: path)
        return deb?.controlMember != nil
    }
}

/// On-disk cache for index files, keyed by URL.
///
/// Repository indexes are large and change rarely; re-downloading them on every
/// app launch is the difference between a store that opens instantly and one that
/// spins. Conditional requests make the common case a `304` with no body.
actor IndexCache {

    struct Entry {
        let payload: Data
        let etag: String?
        let lastModified: String?
        let fetchedAt: Date
    }

    private let directory: String
    private var memory: [String: Entry] = [:]
    private var preferredFormats: [String: CompressionFormat] = [:]

    init(directory: String) {
        self.directory = directory
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }

    private func key(for url: String) -> String {
        // FNV-1a: no CryptoKit needed, and collisions between repository URLs are
        // not a security boundary here — the payload is verified by digest.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in url.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }

    func preferredFormat(for sourceURL: String) -> CompressionFormat? {
        if let value = preferredFormats[sourceURL] { return value }
        let path = (directory as NSString).appendingPathComponent(key(for: "format|" + sourceURL) + ".format")
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8),
              let value = CompressionFormat(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        preferredFormats[sourceURL] = value
        return value
    }

    func rememberPreferredFormat(_ format: CompressionFormat, for sourceURL: String) {
        preferredFormats[sourceURL] = format
        let path = (directory as NSString).appendingPathComponent(key(for: "format|" + sourceURL) + ".format")
        try? format.rawValue.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func entry(for url: String) -> Entry? {
        if let cached = memory[url] { return cached }
        let path = (directory as NSString).appendingPathComponent(key(for: url))
        guard let payload = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let metadataPath = path + ".meta"
        var etag: String?
        var lastModified: String?
        if let metadata = try? Data(contentsOf: URL(fileURLWithPath: metadataPath)),
           let fields = try? JSONSerialization.jsonObject(with: metadata) as? [String: String] {
            etag = fields["etag"]
            lastModified = fields["lastModified"]
        }
        let entry = Entry(payload: payload, etag: etag, lastModified: lastModified, fetchedAt: Date())
        memory[url] = entry
        return entry
    }

    func store(payload: Data, for url: String, etag: String?, lastModified: String?) {
        memory[url] = Entry(payload: payload, etag: etag, lastModified: lastModified, fetchedAt: Date())
        let path = (directory as NSString).appendingPathComponent(key(for: url))
        try? payload.write(to: URL(fileURLWithPath: path), options: .atomic)
        var fields: [String: String] = ["url": url]
        if let etag { fields["etag"] = etag }
        if let lastModified { fields["lastModified"] = lastModified }
        if let metadata = try? JSONSerialization.data(withJSONObject: fields) {
            try? metadata.write(to: URL(fileURLWithPath: path + ".meta"), options: .atomic)
        }
    }

    /// Total bytes on disk, for the settings screen.
    func diskUsage() -> Int {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return 0 }
        return contents.reduce(0) { total, name in
            let path = (directory as NSString).appendingPathComponent(name)
            let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber
            return total + (size?.intValue ?? 0)
        }
    }

    func clear() {
        memory.removeAll()
        preferredFormats.removeAll()
        try? FileManager.default.removeItem(atPath: directory)
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }
}
