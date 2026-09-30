import Foundation

public enum TransportError: Error, CustomStringConvertible {
    case invalidURL(String)
    case httpStatus(Int, String)
    case transport(String, underlying: Error)

    public var description: String {
        switch self {
        case .invalidURL(let url): return "not a usable URL: \(url)"
        case .httpStatus(let status, let url): return "the server answered \(status) for \(url)"
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

    public init(configuration: URLSessionConfiguration? = nil) {
        let config = configuration ?? .default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 3600
        config.httpAdditionalHeaders = ["User-Agent": HTTPDownloader.userAgent]
        self.session = URLSession(configuration: config)
        super.init()
    }

    public static let userAgent = "Aurora/1.0 (iOS; like Sileo)"

    /// A plain GET, used for index files which are small enough to hold in memory.
    public func data(for url: URL, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw TransportError.transport(url.absoluteString, underlying: URLError(.badServerResponse))
            }
            return (data, http)
        } catch let error as TransportError {
            throw error
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
        } catch {
            throw TransportError.transport(url.absoluteString, underlying: error)
        }

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            try? fileManager.removeItem(atPath: staging)
            throw TransportError.httpStatus(http.statusCode, url.absoluteString)
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
}

/// Moves the finished download out of the system's temporary directory before the
/// download task tears it down.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let stagingPath: String
    private let onProgress: ((Int64, Int64) -> Void)?
    private(set) var failure: Error?

    init(stagingPath: String, onProgress: ((Int64, Int64) -> Void)?) {
        self.stagingPath = stagingPath
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        onProgress?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let http = downloadTask.response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
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
