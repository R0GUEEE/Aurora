import Foundation

public enum TransportError: Error, CustomStringConvertible {
    case invalidURL(String)
    case httpStatus(Int, String)
    case responseTooLarge(Int64)
    case transport(String, underlying: Error)

    public var description: String {
        switch self {
        case .invalidURL(let url): return "not a usable URL: \(url)"
        case .httpStatus(let status, let url): return "the server answered \(status) for \(url)"
        case .responseTooLarge(let limit): return "the response exceeded the \(limit)-byte safety limit"
        case .transport(let url, let underlying): return "\(url): \(underlying.localizedDescription)"
        }
    }
}

/// HTTP transport.
///
/// Downloads go through `URLSession`'s **download** task rather than an in-memory
/// data task: a `.deb` can be several hundred megabytes, and a jailbroken phone
/// cannot hold that twice.
public final class HTTPDownloader: NSObject, @unchecked Sendable {

    private let session: URLSession
    private let metadataTimeout: TimeInterval

    public init(configuration: URLSessionConfiguration? = nil, metadataTimeout: TimeInterval = 12) {
        let config = configuration ?? .default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600
        config.httpAdditionalHeaders = ["User-Agent": HTTPDownloader.userAgent]
        self.metadataTimeout = min(60, max(3, metadataTimeout))
        self.session = URLSession(configuration: config)
        super.init()
    }

    public static let userAgent = "Aurora/1.0 (iOS; like Sileo)"

    /// A plain GET, used for index files which are small enough to hold in memory.
    public func data(
        for url: URL,
        headers: [String: String] = [:],
        maximumBytes: Int = 32 * (1 << 20)
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Repository metadata should fail fast. Package downloads use the
        // session's much longer resource timeout separately.
        request.timeoutInterval = metadataTimeout
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let byteLimit = max(0, maximumBytes)
        let staging = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("aurora-metadata-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: staging) }
        let delegate = DownloadDelegate(
            stagingPath: staging,
            onProgress: nil,
            maximumBytes: Int64(byteLimit),
            allowNotModified: true
        )
        do {
            let (temporaryURL, response) = try await session.download(for: request, delegate: delegate)
            guard let http = response as? HTTPURLResponse else {
                throw TransportError.transport(url.absoluteString, underlying: URLError(.badServerResponse))
            }
            guard (200...299).contains(http.statusCode) || http.statusCode == 304 else {
                throw TransportError.httpStatus(http.statusCode, url.absoluteString)
            }
            if let failure = delegate.failure { throw failure }
            if http.statusCode == 304, !FileManager.default.fileExists(atPath: staging) {
                return (Data(), http)
            }

            // URLSession's download delegate normally moves the temporary file to
            // the staging path, but some Foundation builds return before that move
            // is visible. There is also a narrow race where the file can move
            // after we choose the temporary URL but before Data opens it, so retry
            // the stable staging path if that first read loses the race.
            let stagingURL = URL(fileURLWithPath: staging)
            let data: Data
            if FileManager.default.fileExists(atPath: staging) {
                data = try Data(contentsOf: stagingURL, options: .mappedIfSafe)
            } else {
                do {
                    data = try Data(contentsOf: temporaryURL, options: .mappedIfSafe)
                } catch {
                    guard FileManager.default.fileExists(atPath: staging) else { throw error }
                    data = try Data(contentsOf: stagingURL, options: .mappedIfSafe)
                }
            }
            guard data.count <= byteLimit else { throw TransportError.responseTooLarge(Int64(byteLimit)) }
            return (data, http)
        } catch let error as TransportError {
            throw error
        } catch is CancellationError {
            if let failure = delegate.failure { throw failure }
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            if let failure = delegate.failure { throw failure }
            throw CancellationError()
        } catch {
            throw TransportError.transport(url.absoluteString, underlying: error)
        }
    }

    /// Streams a file to `destination`, replacing it atomically.
    ///
    /// `destination.partial` is the staging path: the delegate moves the finished
    /// download there, so a file at `destination` is always complete.
    public func download(
        from url: URL,
        to destination: String,
        headers: [String: String] = [:],
        allowCrossOriginRedirects: Bool = false,
        progress: ((Int64, Int64) -> Void)? = nil
    ) async throws {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        let fileManager = FileManager.default
        let directory = (destination as NSString).deletingLastPathComponent
        try? fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let staging = destination + ".partial"
        try? fileManager.removeItem(atPath: staging)

        let delegate = DownloadDelegate(stagingPath: staging, onProgress: progress)
        let response: URLResponse
        do {
            // The delegate owns the temporary file and moves it as it finishes;
            // the URL the async call returns is only a placeholder we ignore.
            (_, response) = try await session.download(for: request, delegate: delegate)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw TransportError.transport(url.absoluteString, underlying: error)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? fileManager.removeItem(atPath: staging)
            throw TransportError.httpStatus(http.statusCode, url.absoluteString)
        }
        guard let finalURL = response.url else {
            try? fileManager.removeItem(atPath: staging)
            throw TransportError.invalidURL("download completed without a final URL")
        }
        if !allowCrossOriginRedirects && !Self.sameOrigin(url, finalURL) {
            try? fileManager.removeItem(atPath: staging)
            throw TransportError.invalidURL("download redirected away from repository origin \(url.host ?? "?")")
        }
        guard let finalScheme = finalURL.scheme?.lowercased(), finalScheme == "http" || finalScheme == "https" else {
            try? fileManager.removeItem(atPath: staging)
            throw TransportError.invalidURL("download redirected to an unsupported URL scheme")
        }
        if let failure = delegate.failure {
            try? fileManager.removeItem(atPath: staging)
            throw TransportError.transport(url.absoluteString, underlying: failure)
        }
        guard fileManager.fileExists(atPath: staging) else {
            throw TransportError.transport(url.absoluteString, underlying: URLError(.cannotWriteToFile))
        }
        do {
            try? fileManager.removeItem(atPath: destination)
            try fileManager.moveItem(atPath: staging, toPath: destination)
        } catch {
            throw TransportError.transport(destination, underlying: error)
        }
    }

    /// Size of a remote file without downloading it.
    public func contentLength(of url: URL) async -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else { return nil }
        let length = http.expectedContentLength
        return length > 0 ? length : nil
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && lhs.port == rhs.port
    }
}

/// Moves the finished download out of the system's temporary directory before the
/// download task tears it down.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let stagingPath: String
    private let onProgress: ((Int64, Int64) -> Void)?
    private let maximumBytes: Int64?
    private let allowNotModified: Bool
    private(set) var failure: Error?

    init(
        stagingPath: String,
        onProgress: ((Int64, Int64) -> Void)?,
        maximumBytes: Int64? = nil,
        allowNotModified: Bool = false
    ) {
        self.stagingPath = stagingPath
        self.onProgress = onProgress
        self.maximumBytes = maximumBytes
        self.allowNotModified = allowNotModified
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
        if let maximumBytes, totalBytesWritten > maximumBytes {
            failure = TransportError.responseTooLarge(maximumBytes)
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let http = downloadTask.response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) || (allowNotModified && http.statusCode == 304) else {
            failure = URLError(.badServerResponse)
            return
        }
        do {
            try? FileManager.default.removeItem(atPath: stagingPath)
            try FileManager.default.moveItem(atPath: location.path, toPath: stagingPath)
        } catch {
            failure = error
        }
    }
}
