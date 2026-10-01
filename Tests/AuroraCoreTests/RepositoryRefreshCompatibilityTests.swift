import XCTest
import Foundation
@testable import AuroraCore

final class RepositoryRefreshCompatibilityTests: XCTestCase {
    override func tearDown() {
        MockRepositoryURLProtocol.reset()
        super.tearDown()
    }

    func testUnsignedFlatReleaseDoesNotBlockValidPackagesIndex() async throws {
        let packageIndex = Data("""
        Package: com.example.demo
        Version: 1.0
        Architecture: iphoneos-arm64
        Name: Demo
        Description: Compatibility fixture

        """.utf8)

        // Deliberately advertises only a stale Packages.gz checksum. Sileo/Zebra
        // style flat repositories must still be allowed to discover another valid
        // Packages variant when the Release file is not cryptographically verified.
        let release = Data("""
        Origin: Compatibility Fixture
        Suite: stable
        Architectures: iphoneos-arm64
        Components: main
        SHA256:
         0000000000000000000000000000000000000000000000000000000000000000 12 Packages.gz

        """.utf8)

        MockRepositoryURLProtocol.install { request in
            guard let url = request.url else {
                return (500, Data())
            }
            switch url.path {
            case "/Release":
                return (200, release)
            case "/Packages":
                return (200, packageIndex)
            default:
                return (404, Data("not found".utf8))
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockRepositoryURLProtocol.self]
        let downloader = HTTPDownloader(configuration: configuration, metadataTimeout: 3)
        let environment = JailbreakEnvironment(
            layout: .notJailbroken,
            root: "/",
            architecture: "iphoneos-arm64",
            dpkgPath: nil,
            statusFilePath: "/var/lib/dpkg/status"
        )
        let client = RepositoryClient(
            environment: environment,
            downloader: downloader,
            policy: RepositoryPolicy(
                requireSignature: true,
                requirePackageDigest: true,
                allowFlatUnsigned: true,
                maximumIndexBytes: 4 * (1 << 20),
                useCache: false,
                maximumRefreshSeconds: 10,
                parallelFlatIndexScan: true,
                preferCachedIndexFormat: true
            )
        )
        let source = RepositorySource(
            name: "Compatibility Fixture",
            url: "https://repo.example.test",
            suite: "./",
            components: []
        )

        let result = try await client.refresh(source)

        XCTAssertEqual(result.records.count, 1)
        XCTAssertEqual(result.records.first?.name, "com.example.demo")
        XCTAssertNotNil(result.release)
        XCTAssertFalse(result.signature.isVerified)
    }
}

private final class MockRepositoryURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> (status: Int, body: Data)

    private static let lock = NSLock()
    private static var handler: Handler?

    static func install(_ newHandler: @escaping Handler) {
        lock.lock()
        handler = newHandler
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        handler = nil
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let current = Self.handler
        Self.lock.unlock()

        guard let current, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let result = current(request)
        let response = HTTPURLResponse(
            url: url,
            statusCode: result.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/octet-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !result.body.isEmpty {
            client?.urlProtocol(self, didLoad: result.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
