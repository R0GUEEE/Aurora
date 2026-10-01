import Foundation
import XCTest
@testable import AuroraCore

private final class PackageDownloadURLProtocol: URLProtocol {
    static let payload = Data("streamed-deb-payload".utf8)

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "repo.example"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/vnd.debian.binary-package",
                    "Content-Length": "\(Self.payload.count)",
                ]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class HTTPDownloaderTests: XCTestCase {

    func testPackageDownloadStreamsDirectlyToDestination() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PackageDownloadURLProtocol.self]

        let downloader = HTTPDownloader(configuration: configuration)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aurora-package-download-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = directory.appendingPathComponent("package.deb").path
        try await downloader.download(
            from: URL(string: "https://repo.example/package.deb")!,
            to: destination
        )

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination)), PackageDownloadURLProtocol.payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination + ".partial"))
    }

    func testPackageDownloadCreatesMissingDestinationDirectory() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PackageDownloadURLProtocol.self]

        let downloader = HTTPDownloader(configuration: configuration)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("aurora-package-download-nested-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let destination = root
            .appendingPathComponent("nested/cache", isDirectory: true)
            .appendingPathComponent("package.deb")
            .path

        try await downloader.download(
            from: URL(string: "https://repo.example/package.deb")!,
            to: destination
        )

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: destination)), PackageDownloadURLProtocol.payload)
    }
}
