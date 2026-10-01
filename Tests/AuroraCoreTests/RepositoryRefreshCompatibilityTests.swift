import XCTest
import Foundation
@testable import AuroraCore

final class RepositoryRefreshCompatibilityTests: XCTestCase {
    override func tearDown() {
        MockRepositoryURLProtocol.reset()
        super.tearDown()
    }


    func testDistributionReleaseUsesPathsRelativeToSuiteRoot() async throws {
        let packageIndex = Data("""
        Package: com.example.dist
        Version: 1.0
        Architecture: iphoneos-arm64
        Filename: pool/com.example.dist.deb
        SHA256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

        """.utf8)
        let digest = try Hashing.hexDigest(of: packageIndex, using: .sha256)
        let release = Data("""
        Origin: Distribution Fixture
        Suite: stable
        Architectures: iphoneos-arm64
        Components: main
        SHA256:
         \(digest) \(packageIndex.count) main/binary-iphoneos-arm64/Packages

        """.utf8)

        MockRepositoryURLProtocol.install { request in
            switch request.url?.path {
            case "/dists/stable/InRelease":
                return (404, Data())
            case "/dists/stable/Release":
                return (200, release)
            case "/dists/stable/Release.gpg", "/dists/stable/Release.asc":
                return (404, Data())
            case "/dists/stable/main/binary-iphoneos-arm64/Packages":
                return (200, packageIndex)
            default:
                return (404, Data("not found".utf8))
            }
        }

        let client = makeClient(requireSignature: false)
        let source = RepositorySource(
            name: "Distribution Fixture",
            url: "https://repo.example.test",
            suite: "stable",
            components: ["main"],
            architectures: ["iphoneos-arm64"]
        )

        let result = try await client.refresh(source)
        XCTAssertEqual(result.records.map(\.name), ["com.example.dist"])
    }

    func testDistributionAcquireByHashFallsBackToHashAddressedIndex() async throws {
        let packageIndex = Data("""
        Package: com.example.byhash
        Version: 1.0
        Architecture: iphoneos-arm64
        Filename: pool/com.example.byhash.deb
        SHA256: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

        """.utf8)
        let digest = try Hashing.hexDigest(of: packageIndex, using: .sha256)
        let release = Data("""
        Origin: ByHash Fixture
        Suite: stable
        Architectures: iphoneos-arm64
        Components: main
        Acquire-By-Hash: yes
        SHA256:
         \(digest) \(packageIndex.count) main/binary-iphoneos-arm64/Packages

        """.utf8)
        let byHashPath = "/dists/stable/main/binary-iphoneos-arm64/by-hash/SHA256/\(digest)"

        MockRepositoryURLProtocol.install { request in
            switch request.url?.path {
            case "/dists/stable/InRelease":
                return (404, Data())
            case "/dists/stable/Release":
                return (200, release)
            case "/dists/stable/Release.gpg", "/dists/stable/Release.asc":
                return (404, Data())
            case byHashPath:
                return (200, packageIndex)
            default:
                return (404, Data("not found".utf8))
            }
        }

        let client = makeClient(requireSignature: false)
        let source = RepositorySource(
            name: "ByHash Fixture",
            url: "https://repo.example.test",
            suite: "stable",
            components: ["main"],
            architectures: ["iphoneos-arm64"]
        )

        let result = try await client.refresh(source)
        XCTAssertEqual(result.records.map(\.name), ["com.example.byhash"])
        XCTAssertTrue(MockRepositoryURLProtocol.requestedPaths().contains(byHashPath))
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

    private func makeClient(requireSignature: Bool) -> RepositoryClient {
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
        return RepositoryClient(
            environment: environment,
            downloader: downloader,
            policy: RepositoryPolicy(
                requireSignature: requireSignature,
                requirePackageDigest: true,
                allowFlatUnsigned: true,
                maximumIndexBytes: 4 * (1 << 20),
                useCache: false,
                maximumRefreshSeconds: 10,
                parallelFlatIndexScan: true,
                preferCachedIndexFormat: true
            )
        )
    }
}

private final class MockRepositoryURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> (status: Int, body: Data)

    private static let lock = NSLock()
    private static var handler: Handler?
    private static var paths: [String] = []

    static func install(_ newHandler: @escaping Handler) {
        lock.lock()
        handler = newHandler
        paths = []
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        handler = nil
        paths = []
        lock.unlock()
    }

    static func requestedPaths() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return paths
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let current = Self.handler
        if let path = request.url?.path { Self.paths.append(path) }
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
