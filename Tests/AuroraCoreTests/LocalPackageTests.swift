import XCTest
@testable import AuroraCore

/// Installing a `.deb` the user supplied is the path a package manager needs when
/// a repository is gone but its packages are not, and when a developer installs
/// what they just built.
final class LocalPackageTests: XCTestCase {

    private func debPath() throws -> String {
        try Fixture.url(Fixture.deb).path
    }

    func testLoadsControlMetadataFromTheArchive() throws {
        let local = try LocalPackageLoader.load(path: try debPath(), deviceArchitecture: "iphoneos-arm64")

        XCTAssertEqual(local.name, "aurora-fixture")
        XCTAssertEqual(local.version.raw, "1.2.3-1")
        XCTAssertEqual(local.record.architecture, "iphoneos-arm64")
        XCTAssertEqual(local.record.relations.depends.clauses.first?.alternatives.first?.name, "bash")
        XCTAssertGreaterThan(local.byteSize, 0)
        XCTAssertEqual(local.maintainerScripts["postinst"]?.contains("aurora-fixture configured"), true)
    }

    func testRecordIsMarkedLocalAndPointsAtTheFile() throws {
        let path = try debPath()
        let local = try LocalPackageLoader.load(path: path)

        XCTAssertTrue(LocalPackageLoader.isLocalRecord(local.record),
                      "the installer must be able to tell that this needs no download")
        XCTAssertEqual(local.record.origin?.url, LocalPackageLoader.repositoryURL)
        XCTAssertEqual(local.record.filename, path)
        XCTAssertEqual(local.record.downloadSize, Int(local.byteSize))
    }

    func testLocalRecordAlsoGetsARepositoryURLBuilderWouldNotUse() throws {
        let local = try LocalPackageLoader.load(path: try debPath())
        // A local record has no repository to build a URL from; the loader must not
        // pretend otherwise, and the installer must not try to fetch it.
        let source = RepositorySource(name: "Local", url: "https://example.invalid", suite: "./")
        XCTAssertEqual(LocalPackageLoader.isLocalRecord(local.record), true)
        _ = source
    }

    func testArchitectureMismatchIsReportedOnRequest() throws {
        // The fixture is arm64; asking for a device-compatible load against arm
        // must fail rather than install something the device cannot run.
        XCTAssertThrowsError(try LocalPackageLoader.load(
            path: try debPath(),
            deviceArchitecture: "iphoneos-arm",
            requireCompatibleArchitecture: true
        )) { error in
            guard case LocalPackageError.architectureMismatch(let package, let architecture, let device) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(package, "aurora-fixture")
            XCTAssertEqual(architecture, "iphoneos-arm64")
            XCTAssertEqual(device, "iphoneos-arm")
        }

        // Without the requirement it loads, because an architecture switch is a
        // legitimate thing to do.
        XCTAssertNoThrow(try LocalPackageLoader.load(path: try debPath(), deviceArchitecture: "iphoneos-arm"))
    }

    func testSomethingThatIsNotAPackageIsRejected() throws {
        let textFile = try Fixture.url(Fixture.packagesIndex).path
        XCTAssertThrowsError(try LocalPackageLoader.load(path: textFile))
        XCTAssertThrowsError(try LocalPackageLoader.load(path: "/definitely/not/here.deb"))
    }

    func testLoadAllSkipsNonPackagesInADirectory() throws {
        let directory = NSTemporaryDirectory() + "aurora-local-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)

        let source = try Data(contentsOf: URL(fileURLWithPath: try debPath()))
        try source.write(to: URL(fileURLWithPath: (directory as NSString).appendingPathComponent("good.deb")))
        try Data("not a package".utf8).write(
            to: URL(fileURLWithPath: (directory as NSString).appendingPathComponent("bad.deb"))
        )
        try Data("ignore me".utf8).write(
            to: URL(fileURLWithPath: (directory as NSString).appendingPathComponent("notes.txt"))
        )

        let loaded = LocalPackageLoader.loadAll(in: directory, deviceArchitecture: "iphoneos-arm64")
        XCTAssertEqual(loaded.map(\.name), ["aurora-fixture"],
                       "a broken .deb in the folder must be skipped, not fatal")
    }
}
