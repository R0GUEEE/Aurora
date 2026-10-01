import Foundation

public enum RepositoryError: Error, CustomStringConvertible {
    case duplicateSource(String)
    case invalidURL(String)
    case noPackageIndex(source: String, tried: [String], details: [String])
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
        case .noPackageIndex(let source, let tried, let details):
            let list = tried.isEmpty ? "no index paths" : tried.joined(separator: ", ")
            let explanation = details.isEmpty ? "" : "; \(details.prefix(3).joined(separator: "; "))"
            return "\(source) published no package index Aurora can read (tried \(list))\(explanation)"
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
    /// Refuse unsigned, unverifiable, or flat indexes. Callers that intentionally
    /// use legacy unsigned repositories must opt out explicitly.
    public var requireSignature: Bool
    /// Refuse package archives that have no collision-resistant digest in the index.
    public var requirePackageDigest: Bool
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
        requireSignature: Bool = true,
        requirePackageDigest: Bool = true,
        allowFlatUnsigned: Bool = true,
        maximumIndexBytes: Int = 256 * (1 << 20),
        useCache: Bool = true,
        maximumRefreshSeconds: Int = 45,
        parallelFlatIndexScan: Bool = true,
        preferCachedIndexFormat: Bool = true
    ) {
        self.requireSignature = requireSignature
        self.requirePackageDigest = requirePackageDigest
        self.allowFlatUnsigned = allowFlatUnsigned
        self.maximumIndexBytes = maximumIndexBytes
        self.useCache = useCache
        self.maximumRefreshSeconds = min(180, max(10, maximumRefreshSeconds))
        self.parallelFlatIndexScan = parallelFlatIndexScan
        self.preferCachedIndexFormat = preferCachedIndexFormat
    }

    public static let `default` = RepositoryPolicy()

    /// A cryptographically rejected signature is never ignorable. The compatibility
    /// switch only permits metadata for which no usable signature was published.
    public func signatureRejection(for status: SignatureStatus) -> String? {
        switch status {
        case .verified:
            return nil
        case .rejected:
            return status.shortDescription
        case .unsigned, .untrusted, .unavailable:
            return requireSignature ? status.shortDescription : nil
        }
    }

    public var flatRepositoryRejection: String? {
        // A flat source has no Release/InRelease metadata to sign. Respect the
        // explicit flat-source policy independently from signature enforcement
        // for Release-backed repositories; otherwise the default policy rejects
        // every ordinary jailbreak repo before its Packages index is scanned.
        allowFlatUnsigned ? nil : "flat repositories cannot be signed"
    }
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
public struct RepositoryProbeResult: Sendable {
    public let packageCount: Int
    public let repositoryName: String?
    public let warnings: [String]
}

public actor RepositoryClient {

    private let environment: JailbreakEnvironment
    private let downloader: HTTPDownloader
    private let signatureVerifier: SignatureVerifier
    private let policy: RepositoryPolicy
    private let cache: IndexCache?

    /// Prefer formats Aurora can decode on a stock device. Other formats remain
    /// available as fallbacks when the jailbreak provides helper binaries.
    public static let formatPreference: [CompressionFormat] = [.gzip, .xz, .plain, .zstd, .bzip2, .lzma]

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

    /// Lightweight validation used by URL-only source onboarding. It reuses the
    /// exact refresh scanner, so "valid" means Aurora can actually parse packages
    /// rather than merely receiving HTTP 200 from the host.
    public func probe(_ source: RepositorySource) async throws -> RepositoryProbeResult {
        let result = try await refresh(source)
        let name = result.release?.origin?.trimmingCharacters(in: .whitespacesAndNewlines)
        return RepositoryProbeResult(
            packageCount: result.records.count,
            repositoryName: (name?.isEmpty == false) ? name : nil,
            warnings: result.warnings
        )
    }

    /// Absolute URL of a package inside the repository that published it.
    public static func packageURL(_ record: PackageRecord, in source: RepositorySource) -> URL? {
        guard let rawFilename = record.filename else { return nil }
        let filename = rawFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !filename.isEmpty else { return nil }
        let resolved: URL
        if let absolute = URL(string: filename), absolute.scheme != nil {
            guard let scheme = absolute.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            resolved = absolute
        } else {
            guard var base = URL(string: source.normalizedURL) else { return nil }
            if !base.absoluteString.hasSuffix("/") {
                base = URL(string: base.absoluteString + "/") ?? base
            }
            // Resolve before validating: protocol-relative paths can switch hosts.
            guard let value = URL(string: filename, relativeTo: base)?.absoluteURL else { return nil }
            resolved = value
        }
        // Filename is repository-controlled. Same-origin locations are always
        // acceptable. Real repositories also use CDN/object-storage URLs, so
        // permit cross-origin package locations only when the package index gives
        // Aurora a collision-resistant digest to verify after download.
        guard let base = URL(string: source.normalizedURL),
              let scheme = resolved.scheme?.lowercased(), scheme == "http" || scheme == "https",
              resolved.user == nil, resolved.password == nil else { return nil }

        let sameOrigin = resolved.host?.lowercased() == base.host?.lowercased()
            && resolved.port == base.port
            && resolved.scheme?.lowercased() == base.scheme?.lowercased()
        if sameOrigin { return resolved }

        guard scheme == "https", hasValidStrongDigest(record) else { return nil }
        return resolved
    }

    private static func hasValidStrongDigest(_ record: PackageRecord) -> Bool {
        guard let digest = record.bestDigest, !digest.algorithm.isBroken else { return false }
        let expectedLength: Int
        switch digest.algorithm {
        case .sha256: expectedLength = 64
        case .sha512: expectedLength = 128
        case .sha1, .md5: return false
        }
        return digest.hex.count == expectedLength && digest.hex.allSatisfy(\.isHexDigit)
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

        let releaseOutcome = await fetchRelease(source)
        release = releaseOutcome.release
        signature = releaseOutcome.signature
        warnings.append(contentsOf: releaseOutcome.warnings)

        if source.isFlat {
            // Sileo/Zebra-style flat repositories may publish Release beside
            // Packages, but many legacy sources do not. Use it when present so
            // index size/hash verification works without making Release mandatory.
            if release == nil {
                if let rejection = policy.flatRepositoryRejection {
                    throw RepositoryError.signatureRequired(source: source.name, reason: rejection)
                }
                warnings.append("Flat repository has no Release metadata; Packages cannot be checksum-verified.")
            } else {
                switch signature {
                case .rejected(let reason):
                    // A published but invalid signature is never silently ignored.
                    throw RepositoryError.signatureRequired(source: source.name, reason: reason)
                case .untrusted(let reason):
                    if policy.requireSignature {
                        throw RepositoryError.signatureRequired(source: source.name, reason: reason)
                    }
                    if let rejection = policy.flatRepositoryRejection {
                        throw RepositoryError.signatureRequired(source: source.name, reason: rejection)
                    }
                    warnings.append("Flat repository is signed by an untrusted key; accepted by compatibility policy.")
                case .verified:
                    break
                case .unsigned, .unavailable:
                    if let rejection = policy.flatRepositoryRejection {
                        throw RepositoryError.signatureRequired(source: source.name, reason: rejection)
                    }
                    if policy.requireSignature {
                        warnings.append("Flat repository Release metadata is not verified; accepted by flat-repository compatibility policy.")
                    }
                }
            }
        } else if let rejection = policy.signatureRejection(for: signature) {
            // Distribution repositories promise signed metadata. Respect strict
            // signature policy for those sources.
            throw RepositoryError.signatureRequired(source: source.name, reason: rejection)
        }

        let configuredArchitectures = source.effectiveArchitectures(defaults: environment.compatibleArchitectures)
        // A flat repository has one Packages file, not one per architecture.
        // Fetching it once per compatible architecture duplicates every record.
        let architectures = source.isFlat ? [configuredArchitectures.first ?? environment.architecture] : configuredArchitectures
        var records: [PackageRecord] = []
        var tried: [String] = []

        for architecture in architectures {
            for component in components(for: source) {
                var paths = indexPaths(source: source, architecture: architecture, component: component)
                // Flat repositories probe their Packages variants independently
                // from Release metadata, matching Sileo/Zebra behavior. A flat
                // Release file is useful metadata, but unsigned/stale manifests are
                // common and must not turn a healthy Packages index into a dead repo.
                if source.isFlat, policy.preferCachedIndexFormat,
                   let preferred = await cache?.preferredFormat(for: source.normalizedURL),
                   let position = paths.firstIndex(where: { $0.1 == preferred }) {
                    let hit = paths.remove(at: position)
                    paths.insert(hit, at: 0)
                }
                var loaded = false

                if source.isFlat && policy.parallelFlatIndexScan {
                    // Limit the parallel probe to the three built-in decoders and
                    // zstd, which many modern repositories publish exclusively.
                    // For a cryptographically verified flat Release we enforce its
                    // checksum list. Unsigned flat Release files are advisory only:
                    // many jailbreak repos publish stale/incomplete metadata while
                    // their Packages files remain valid.
                    let enforceFlatManifest = signature.isVerified
                    let candidates = paths.prefix(4).compactMap { path, format -> (URL, String, CompressionFormat, ReleaseFile.Checksum?)? in
                        guard let indexURL = url(source, path: path) else { return nil }
                        let expected: ReleaseFile.Checksum?
                        if enforceFlatManifest, let release {
                            let checksumPath = releaseRelativeIndexPath(path, source: source)
                            guard let checksum = release.checksum(forPath: checksumPath) else { return nil }
                            expected = checksum
                        } else {
                            expected = nil
                        }
                        return (indexURL, path, format, expected)
                    }
                    let winner: (String, CompressionFormat, [PackageRecord], [String])? = await withTaskGroup(of: (String, CompressionFormat, Data?, [String]).self, returning: (String, CompressionFormat, [PackageRecord], [String])?.self) { group in
                        for (indexURL, path, format, expected) in candidates {
                            group.addTask {
                                let outcome = await self.fetch(indexURL: indexURL, checksum: expected)
                                return (path, format, outcome.data, outcome.warnings)
                            }
                        }
                        var collectedWarnings: [String] = []
                        while let result = await group.next() {
                            collectedWarnings.append(contentsOf: result.3)
                            guard let payload = result.2 else { continue }
                            do {
                                let decompressed = try Decompressor.decompress(
                                    payload,
                                    format: result.1,
                                    maximumOutputBytes: policy.maximumIndexBytes
                                )
                                let origin = RepositoryID(
                                    url: source.normalizedURL,
                                    suite: source.suite,
                                    component: component
                                )
                                let parsed = Self.packageRecords(in: decompressed, origin: origin)
                                // Some web servers return their HTML landing page
                                // with status 200 for every missing Packages path.
                                // A transport success is not an index; keep racing
                                // until a candidate actually contains package stanzas.
                                guard !parsed.isEmpty else {
                                    collectedWarnings.append("\(result.0): response did not contain package records")
                                    continue
                                }
                                group.cancelAll()
                                return (result.0, result.1, parsed, collectedWarnings)
                            } catch {
                                collectedWarnings.append("\(result.0): \(error)")
                            }
                        }
                        return nil
                    }
                    if let (_, format, parsed, scanWarnings) = winner {
                        warnings.append(contentsOf: scanWarnings)
                        tried.append(contentsOf: paths.map(\.0))
                        records.append(contentsOf: parsed)
                        await cache?.rememberPreferredFormat(format, for: source.normalizedURL)
                        loaded = true
                    }
                }

                if !loaded {
                for (path, format) in paths {
                    tried.append(path)
                    guard let indexURL = url(source, path: path) else { continue }

                    // Distribution Release files are authoritative. Flat
                    // Release files are authoritative only when their signature was
                    // actually verified; otherwise they are advisory metadata and
                    // Packages discovery proceeds exactly as it does in Sileo/Zebra.
                    var expected: ReleaseFile.Checksum?
                    if let release {
                        let checksumPath = releaseRelativeIndexPath(path, source: source)
                        if source.isFlat {
                            if signature.isVerified {
                                expected = release.checksum(forPath: checksumPath)
                                if expected == nil { continue }
                            }
                        } else {
                            expected = release.checksum(forPath: checksumPath)
                            if expected == nil { continue }
                        }
                    }

                    var outcome: (data: Data?, warnings: [String])
                    if let release, release.acquireByHash, let expected {
                        let hashedPath = byHashPath(for: path, checksum: expected)
                        if let hashedURL = url(source, path: hashedPath) {
                            tried.append(hashedPath)
                            outcome = await fetch(indexURL: hashedURL, checksum: expected)
                            warnings.append(contentsOf: outcome.warnings)
                            if outcome.data == nil {
                                outcome = await fetch(indexURL: indexURL, checksum: expected)
                            }
                        } else {
                            outcome = await fetch(indexURL: indexURL, checksum: expected)
                        }
                    } else {
                        outcome = await fetch(indexURL: indexURL, checksum: expected)
                    }
                    warnings.append(contentsOf: outcome.warnings)
                    guard let payload = outcome.data else { continue }

                    let decompressed: Data
                    do {
                        decompressed = try Decompressor.decompress(
                            payload,
                            format: format,
                            maximumOutputBytes: policy.maximumIndexBytes
                        )
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
                    let parsed = Self.packageRecords(in: decompressed, origin: origin)
                    guard !parsed.isEmpty else {
                        warnings.append("\(path): response did not contain package records")
                        continue
                    }
                    records.append(contentsOf: parsed)
                    if source.isFlat {
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
            var seenPaths: Set<String> = []
            var seenDetails: Set<String> = []
            let uniquePaths = tried.filter { seenPaths.insert($0).inserted }
            let uniqueDetails = warnings.filter { seenDetails.insert($0).inserted }
            throw RepositoryError.noPackageIndex(source: source.name, tried: uniquePaths, details: uniqueDetails)
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

    /// A successful HTTP response only counts as a Packages index if its control
    /// stanzas actually describe packages. Mirrors sometimes serve an HTML page
    /// with status 200 for missing files.
    static func packageRecords(in data: Data, origin: RepositoryID) -> [PackageRecord] {
        let text = String(decoding: data, as: UTF8.self)
        var records: [PackageRecord] = []
        // A typical Packages paragraph is several hundred bytes. Reserving a
        // conservative fraction avoids repeated growth without grossly
        // over-allocating on small indexes.
        records.reserveCapacity(max(8, data.count / 700))
        ControlParser.forEachStanza(in: text) { stanza in
            guard stanza.has("Package") else { return }
            records.append(PackageRecord(stanza: stanza, origin: origin))
        }
        return records
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
        var result: [(String, CompressionFormat)] = []
        for format in Self.formatPreference {
            let suffixes: [String]
            switch format {
            case .plain: suffixes = [""]
            case .gzip: suffixes = [".gz"]
            case .xz: suffixes = [".xz"]
            case .lzma: suffixes = [".lzma"]
            case .bzip2: suffixes = [".bz2", ".bzip2"]
            case .zstd: suffixes = [".zst", ".zstd"]
            }
            result.append(contentsOf: suffixes.map { (directory + "Packages" + $0, format) })
        }
        return result
    }

    /// Release checksum paths are relative to the directory containing Release,
    /// not to the repository root. This matters for dists repositories, where
    /// Release lists main/binary-*/Packages* rather than dists/<suite>/....
    private func releaseRelativeIndexPath(_ path: String, source: RepositorySource) -> String {
        if source.isFlat {
            let prefix = source.flatPathPrefix
            guard !prefix.isEmpty, path.hasPrefix(prefix + "/") else { return path }
            return String(path.dropFirst(prefix.count + 1))
        }
        let prefix = "dists/\(source.suite)/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    private func byHashPath(for normalPath: String, checksum: ReleaseFile.Checksum) -> String {
        let directory = (normalPath as NSString).deletingLastPathComponent
        let hashPath = "by-hash/\(checksum.algorithm.fieldName)/\(checksum.hex)"
        return directory.isEmpty ? hashPath : directory + "/" + hashPath
    }


    // MARK: - Release

    private func fetchRelease(
        _ source: RepositorySource
    ) async -> (release: ReleaseFile?, signature: SignatureStatus, warnings: [String]) {
        guard let suite = source.releasePath else { return (nil, .unsigned, []) }
        var warnings: [String] = []

        let inReleasePath = ((suite as NSString).deletingLastPathComponent as NSString).appendingPathComponent("InRelease")
        if let inReleaseURL = url(source, path: inReleasePath),
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
            let (body, response) = try await downloader.data(
                for: indexURL,
                headers: headers,
                maximumBytes: policy.maximumIndexBytes
            )
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
        } catch is CancellationError {
            // Cancellation is control flow, not a transport failure. Never turn a
            // cancelled refresh into a successful stale-cache result.
            return (nil, warnings)
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

        let strongDigest = Self.hasValidStrongDigest(record)
        try await downloader.download(
            from: remote,
            to: destination,
            allowCrossOriginRedirects: strongDigest,
            progress: progress
        )

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
        guard let size else { return false }
        if let expected = record.downloadSize, size != expected { return false }
        if let digest = record.bestDigest, !digest.algorithm.isBroken {
            guard let actual = try? Hashing.hexDigest(ofFileAt: path, using: digest.algorithm) else { return false }
            return Hashing.matches(actual, digest.hex)
        }
        if policy.requirePackageDigest { return false }
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
    private let memoryLimitBytes = 8 * (1 << 20)
    private var memory: [String: Entry] = [:]
    private var memoryOrder: [String] = []
    private var memoryBytes = 0
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

    private func rememberInMemory(_ entry: Entry, for url: String) {
        if let existing = memory[url] {
            memoryBytes -= existing.payload.count
            memoryOrder.removeAll { $0 == url }
        }
        memory[url] = entry
        memoryOrder.append(url)
        memoryBytes += entry.payload.count

        while memoryBytes > memoryLimitBytes, !memoryOrder.isEmpty {
            let victim = memoryOrder.removeFirst()
            guard let removed = memory.removeValue(forKey: victim) else { continue }
            memoryBytes -= removed.payload.count
        }
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
        rememberInMemory(entry, for: url)
        return entry
    }

    func store(payload: Data, for url: String, etag: String?, lastModified: String?) {
        let entry = Entry(payload: payload, etag: etag, lastModified: lastModified, fetchedAt: Date())
        rememberInMemory(entry, for: url)
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
        memoryOrder.removeAll()
        memoryBytes = 0
        preferredFormats.removeAll()
        try? FileManager.default.removeItem(atPath: directory)
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    }
}
