import XCTest
@testable import AuroraCore

final class PackageMetadataTests: XCTestCase {
    func testSourceInterchangeParsesURLsAndAptLines() {
        let text = """
        # exported sources
        https://repo.example.com/
        deb https://apt.example.org stable main tweaks
        https://repo.example.com
        """
        let sources = SourceInterchange.parse(text)
        XCTAssertEqual(sources.count, 2)
        XCTAssertEqual(sources[0].normalizedURL, "https://repo.example.com")
        XCTAssertTrue(sources[0].isFlat)
        XCTAssertEqual(sources[1].suite, "stable")
        XCTAssertEqual(sources[1].components, ["main", "tweaks"])
    }

    func testSourceInterchangeRoundTrip() {
        let sources = [
            RepositorySource(name: "Flat", url: "https://flat.example", suite: "./"),
            RepositorySource(name: "Dists", url: "https://dists.example", suite: "stable", components: ["main"])
        ]
        let parsed = SourceInterchange.parse(SourceInterchange.export(sources))
        XCTAssertEqual(parsed.map(\.normalizedURL), sources.map(\.normalizedURL))
        XCTAssertEqual(parsed.map(\.suite), sources.map(\.suite))
    }

    func testRootlessRejectsLegacyArchitecture() {
        var stanza = ControlStanza()
        stanza["Package"] = "legacy.tweak"
        stanza["Version"] = "1.0"
        stanza["Architecture"] = "iphoneos-arm"
        let record = PackageRecord(stanza: stanza)
        let environment = JailbreakEnvironment(
            layout: .rootless,
            root: "/var/jb",
            architecture: "iphoneos-arm64",
            dpkgPath: "/var/jb/usr/bin/dpkg",
            statusFilePath: "/var/jb/var/lib/dpkg/status"
        )
        XCTAssertEqual(PackageCompatibility.evaluate(record, environment: environment).level, .incompatible)
    }

    func testRichMetadataAliases() {
        var stanza = ControlStanza()
        stanza["Package"] = "example"
        stanza["Version"] = "1"
        stanza["Architecture"] = "all"
        stanza["Changelog-URL"] = "https://example.test/changelog"
        stanza["Support"] = "https://example.test/support"
        stanza["Min-iOS"] = "16.0"
        let record = PackageRecord(stanza: stanza)
        XCTAssertEqual(record.changelogURL, "https://example.test/changelog")
        XCTAssertEqual(record.supportURL, "https://example.test/support")
        XCTAssertEqual(record.minimumOSVersion, "16.0")
    }
}
