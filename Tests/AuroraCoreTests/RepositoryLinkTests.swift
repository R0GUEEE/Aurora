import XCTest
@testable import AuroraCore

final class RepositoryLinkTests: XCTestCase {
    func testBareHostUsesHTTPSLikeZebra() throws {
        let link = try XCTUnwrap(RepositoryLink.parse("kernelrw.github.io"))
        XCTAssertEqual(link.url, "https://kernelrw.github.io")
        XCTAssertNil(link.suite)
        XCTAssertTrue(link.components.isEmpty)
    }

    func testSileoSourceDeepLinkUnwrapsRepository() throws {
        let link = try XCTUnwrap(RepositoryLink.parse("sileo://source/https://kernelrw.github.io/"))
        XCTAssertEqual(link.url, "https://kernelrw.github.io")
        XCTAssertNil(link.suite)
    }

    func testZebraSourceDeepLinkUnwrapsRepository() throws {
        let encoded = "https%3A%2F%2Fkernelrw.github.io%2F"
        let link = try XCTUnwrap(RepositoryLink.parse("zbra://sources/add/\(encoded)"))
        XCTAssertEqual(link.url, "https://kernelrw.github.io")
    }

    func testSileoDistributionLinkPreservesSuiteAndComponents() throws {
        let link = try XCTUnwrap(RepositoryLink.parse(
            "sileo://url/https://apt.example.test?suites=stable&components=main,tweaks"
        ))
        XCTAssertEqual(link.url, "https://apt.example.test")
        XCTAssertEqual(link.suite, "stable")
        XCTAssertEqual(link.components, ["main", "tweaks"])
    }

    func testDirectPackagesLinkFoldsBackToFlatRepositoryRoot() throws {
        let link = try XCTUnwrap(RepositoryLink.parse(
            "https://kernelrw.github.io/Packages.xz"
        ))
        XCTAssertEqual(link.url, "https://kernelrw.github.io")
        XCTAssertNil(link.suite)
    }

    func testDistributionPackagesLinkInfersLayout() throws {
        let link = try XCTUnwrap(RepositoryLink.parse(
            "https://repo.example.test/apt/dists/iphoneos-arm64/1800/main/binary-iphoneos-arm64/Packages.gz"
        ))
        XCTAssertEqual(link.url, "https://repo.example.test/apt")
        XCTAssertEqual(link.suite, "iphoneos-arm64/1800")
        XCTAssertEqual(link.components, ["main"])
        XCTAssertEqual(link.architectures, ["iphoneos-arm64"])
    }

    func testDistributionReleaseLinkInfersSuite() throws {
        let link = try XCTUnwrap(RepositoryLink.parse(
            "https://repo.example.test/dists/stable/Release"
        ))
        XCTAssertEqual(link.url, "https://repo.example.test")
        XCTAssertEqual(link.suite, "stable")
    }

    func testFlatRepositoryReleasePathIsAtPackageRoot() {
        XCTAssertEqual(
            RepositorySource(name: "Flat", url: "https://repo.example", suite: "./").releasePath,
            "Release"
        )
        XCTAssertEqual(
            RepositorySource(name: "Nested", url: "https://repo.example", suite: "./apt").releasePath,
            "apt/Release"
        )
    }

    func testSourceInterchangeAcceptsSileoZebraStyleLinks() {
        let sources = SourceInterchange.parse("""
        kernelrw.github.io
        sileo://source/https://repo.example.test/
        zbra://sources/add/https%3A%2F%2Fanother.example.test%2F
        """)
        XCTAssertEqual(sources.map(\.normalizedURL), [
            "https://kernelrw.github.io",
            "https://repo.example.test",
            "https://another.example.test"
        ])
        XCTAssertTrue(sources.allSatisfy(\.isFlat))
    }


    func testKnownBigBossAliasUsesSileoCanonicalDistribution() throws {
        let link = try XCTUnwrap(RepositoryLink.parse("bigboss.org"))
        XCTAssertEqual(link.url, "http://apt.thebigboss.org/repofiles/cydia")
        XCTAssertEqual(link.suite, "stable")
        XCTAssertEqual(link.components, ["main"])
    }

    func testProcursusAliasUsesCanonicalDistributionRoot() throws {
        let link = try XCTUnwrap(RepositoryLink.parse("https://apt.procurs.us/"))
        XCTAssertEqual(link.url, "https://apt.procurs.us")
        XCTAssertEqual(link.suite, "iphoneos-arm64/1800")
        XCTAssertEqual(link.components, ["main"])
    }

    func testDeb822DirectDistsURIInfersMissingLayoutFields() throws {
        let sources = SourceInterchange.parse("""
        Types: deb
        URIs: https://repo.example.test/apt/dists/stable/tweaks/binary-iphoneos-arm64/Packages.xz
        """)

        let source = try XCTUnwrap(sources.first)
        XCTAssertEqual(source.normalizedURL, "https://repo.example.test/apt")
        XCTAssertEqual(source.suite, "stable")
        XCTAssertEqual(source.components, ["tweaks"])
        XCTAssertEqual(source.architectures, ["iphoneos-arm64"])
    }

    func testDeb822ExplicitFlatFieldsOverrideURIInference() throws {
        let sources = SourceInterchange.parse("""
        Types: deb
        URIs: https://repo.example.test/dists/stable/Release
        Suites: ./
        Components:
        """)

        let source = try XCTUnwrap(sources.first)
        XCTAssertEqual(source.normalizedURL, "https://repo.example.test")
        XCTAssertEqual(source.suite, "./")
        XCTAssertTrue(source.components.isEmpty)
    }

    func testRejectsNonRepositoryTextAndCredentials() {
        XCTAssertNil(RepositoryLink.parse("not a repository"))
        XCTAssertNil(RepositoryLink.parse("https://user:pass@repo.example.test"))
    }
}
