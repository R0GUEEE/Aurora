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
        // Repository metadata has its own ETag/Last-Modified cache. Disabling
        // Foundation's response cache avoids storing the same multi-megabyte
        // indexes twice in memory/on disk and prevents stale cache-policy surprises.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldUsePipelining = true
        config.httpMaximumConnectionsPerHost = 8
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
            allowNotModified: true,
            originalURL: url,
            allowCrossOriginRedirects: false
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
        do {
            try fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
        } catch {
            throw TransportError.transport(directory, underlying: error)
        }
        let staging = destination + ".partial"
        try? fileManager.removeItem(atPath: staging)

        let delegate = DownloadDelegate(
            stagingPath: staging,
            onProgress: progress,
            originalURL: url,
            allowCrossOriginRedirects: allowCrossOriginRedirects
        )
        var response: URLResponse
        do {
            // The delegate owns the temporary file and moves it as it finishes;
            // the URL the async call returns is only a placeholder we ignore.
            (_, response) = try await session.download(for: request, delegate: delegate)
            if let failure = delegate.failure { throw failure }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled && delegate.failure == nil {
            throw CancellationError()
        } catch {
            // Some jailbreak/runtime combinations return NSURLError -3000...-3005
            // from URLSessionDownloadTask even though Aurora's cache directory is
            // writable. In that case bypass CFNetwork's temporary download file
            // and stream response chunks directly into Aurora's own .partial file.
            guard Self.shouldFallbackToStreamingDownload(error) else {
                throw TransportError.transport(url.absoluteString, underlying: error)
            }
            try? fileManager.removeItem(atPath: staging)
            response = try await streamDownload(
                request: request,
                originalURL: url,
                stagingPath: staging,
                allowCrossOriginRedirects: allowCrossOriginRedirects,
                progress: progress
            )
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? fileManager.removeItem(atPath: staging)
            throw TransportError.httpStatus(http.statusCode, url.absoluteString)
        }
        guard let finalURL = response.url else {
            try? fileManager.removeItem(atPath: staging)
            throw TransportError.invalidURL("download completed without a final URL")
        }
        let stayedSameOrigin = Self.sameOrigin(url, finalURL)
        if !allowCrossOriginRedirects && !stayedSameOrigin {
            try? fileManager.removeItem(atPath: staging)
            throw TransportError.invalidURL("download redirected away from repository origin \(url.host ?? "?")")
        }
        guard let finalScheme = finalURL.scheme?.lowercased(), finalScheme == "http" || finalScheme == "https" else {
            try? fileManager.removeItem(atPath: staging)
            throw TransportError.invalidURL("download redirected to an unsupported URL scheme")
        }
        if !stayedSameOrigin && finalScheme != "https" {
            try? fileManager.removeItem(atPath: staging)
            throw TransportError.invalidURL("cross-origin package redirects must use HTTPS")
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

    static func shouldFallbackToStreamingDownload(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return (-3005 ... -3000).contains(nsError.code)
    }

    private func streamDownload(
        request: URLRequest,
        originalURL: URL,
        stagingPath: String,
        allowCrossOriginRedirects: Bool,
        progress: ((Int64, Int64) -> Void)?
    ) async throws -> URLResponse {
        let delegate: StreamingDownloadDelegate
        do {
            delegate = try StreamingDownloadDelegate(
                stagingPath: stagingPath,
                onProgress: progress,
                originalURL: originalURL,
                allowCrossOriginRedirects: allowCrossOriginRedirects
            )
        } catch {
            throw TransportError.transport(stagingPath, underlying: error)
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldUsePipelining = true
        config.httpMaximumConnectionsPerHost = 8
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.start(
                    request: request,
                    configuration: config,
                    delegateQueue: queue,
                    continuation: continuation
                )
            }
        } onCancel: {
            delegate.cancel()
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
    private let originalURL: URL
    private let allowCrossOriginRedirects: Bool
    private(set) var failure: Error?

    init(
        stagingPath: String,
        onProgress: ((Int64, Int64) -> Void)?,
        maximumBytes: Int64? = nil,
        allowNotModified: Bool = false,
        originalURL: URL,
        allowCrossOriginRedirects: Bool
    ) {
        self.stagingPath = stagingPath
        self.onProgress = onProgress
        self.maximumBytes = maximumBytes
        self.allowNotModified = allowNotModified
        self.originalURL = originalURL
        self.allowCrossOriginRedirects = allowCrossOriginRedirects
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let target = request.url,
              let scheme = target.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              target.user == nil,
              target.password == nil else {
            failure = TransportError.invalidURL("redirected to an unsupported URL")
            completionHandler(nil)
            return
        }

        let sameOrigin = target.scheme?.lowercased() == originalURL.scheme?.lowercased()
            && target.host?.lowercased() == originalURL.host?.lowercased()
            && target.port == originalURL.port

        if sameOrigin {
            completionHandler(request)
            return
        }

        guard allowCrossOriginRedirects, scheme == "https" else {
            failure = TransportError.invalidURL("cross-origin redirect was not permitted")
            completionHandler(nil)
            return
        }
        completionHandler(request)
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

/// Fallback package downloader that bypasses URLSessionDownloadTask's private
/// temporary file. It writes response chunks directly to Aurora's staging file,
/// keeping memory bounded even for very large .deb archives.
private final class StreamingDownloadDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let stagingPath: String
    private let onProgress: ((Int64, Int64) -> Void)?
    private let originalURL: URL
    private let allowCrossOriginRedirects: Bool
    private let handle: FileHandle

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<URLResponse, Error>?
    private var response: URLResponse?
    private var received: Int64 = 0
    private var expected: Int64 = NSURLSessionTransferSizeUnknown
    private var failure: Error?
    private var completed = false

    init(
        stagingPath: String,
        onProgress: ((Int64, Int64) -> Void)?,
        originalURL: URL,
        allowCrossOriginRedirects: Bool
    ) throws {
        self.stagingPath = stagingPath
        self.onProgress = onProgress
        self.originalURL = originalURL
        self.allowCrossOriginRedirects = allowCrossOriginRedirects

        let manager = FileManager.default
        try? manager.removeItem(atPath: stagingPath)
        guard manager.createFile(atPath: stagingPath, contents: nil) else {
            throw URLError(.cannotCreateFile)
        }
        self.handle = try FileHandle(forWritingTo: URL(fileURLWithPath: stagingPath))
        super.init()
    }

    func start(
        request: URLRequest,
        configuration: URLSessionConfiguration,
        delegateQueue: OperationQueue,
        continuation: CheckedContinuation<URLResponse, Error>
    ) {
        self.continuation = continuation
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let target = request.url,
              let scheme = target.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              target.user == nil,
              target.password == nil else {
            failure = TransportError.invalidURL("redirected to an unsupported URL")
            completionHandler(nil)
            return
        }

        let sameOrigin = target.scheme?.lowercased() == originalURL.scheme?.lowercased()
            && target.host?.lowercased() == originalURL.host?.lowercased()
            && target.port == originalURL.port
        if sameOrigin {
            completionHandler(request)
            return
        }

        guard allowCrossOriginRedirects, scheme == "https" else {
            failure = TransportError.invalidURL("cross-origin redirect was not permitted")
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        self.response = response
        self.expected = response.expectedContentLength
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        do {
            try handle.write(contentsOf: data)
            received += Int64(data.count)
            onProgress?(received, expected)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !completed else { return }
        completed = true

        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            if failure == nil { failure = error }
        }

        let result: Result<URLResponse, Error>
        if let failure {
            result = .failure(failure)
        } else if let error {
            result = .failure(error)
        } else if let response = response ?? task.response {
            result = .success(response)
        } else {
            result = .failure(URLError(.badServerResponse))
        }

        continuation?.resume(with: result)
        continuation = nil
        self.task = nil
        self.session?.finishTasksAndInvalidate()
        self.session = nil
    }
}
