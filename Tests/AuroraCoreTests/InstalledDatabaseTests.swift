import XCTest
@testable import AuroraCore

/// The dpkg database: what Aurora makes of `/var/lib/dpkg/status`, and what it
/// offers to write back.
final class InstalledDatabaseTests: XCTestCase {

    private func database() throws -> InstalledPackageDatabase {
        InstalledPackageDatabase(parsing: try Fixture.text(Fixture.status))
    }

    private func stanza(_ name: String, version: String = "1.0-1", architecture: String = "iphoneos-arm64",
                        status: String = "install ok installed") -> ControlStanza {
        ControlStanza(fields: [
            ControlField(name: "Package", value: name),
            ControlField(name: "Status", value: status),
            ControlField(name: "Version", value: version),
            ControlField(name: "Architecture", value: architecture),
        ])
    }

    // MARK: - Parsing

    func testParsesTheStatusFile() throws {
        let database = try database()
        XCTAssertEqual(database.count, 7)
        XCTAssertEqual(database.all.map(\.name),
                       ["bash", "coreutils", "foo-app", "goneconf", "halfbroken", "libfoo1", "oldapp"],
                       "the database is kept sorted by name")

        XCTAssertTrue(database.isInstalled("bash"))
        XCTAssertTrue(database.isInstalled("coreutils"))
        XCTAssertFalse(database.isInstalled("goneconf"))
        XCTAssertFalse(database.isInstalled("halfbroken"))
        XCTAssertFalse(database.isInstalled("not-in-the-file-at-all"))

        XCTAssertEqual(database.package(named: "foo-app")?.version.raw, "1.9.0-1")
        XCTAssertEqual(database.package(named: "bash")?.architecture, "iphoneos-arm64")
        XCTAssertEqual(database.package(named: "bash")?.status.serialized, "install ok installed")
        XCTAssertNil(database.package(named: "nothing-here"))
    }

    func testConffilesKeepsItsMultiLineValue() throws {
        let halfbroken = try XCTUnwrap(try database().package(named: "halfbroken"))
        XCTAssertEqual(halfbroken.stanza["Conffiles"], "\n /etc/halfbroken.conf deadbeef")
        XCTAssertTrue(halfbroken.stanza.has("Conffiles"))
    }

    // MARK: - Status flags

    func testStatusFlags() throws {
        let database = try database()

        let halfbroken = try XCTUnwrap(database.package(named: "halfbroken"))
        XCTAssertEqual(halfbroken.status.state, "half-configured")
        XCTAssertTrue(halfbroken.status.isBroken)
        XCTAssertTrue(halfbroken.status.needsConfigure)
        XCTAssertFalse(halfbroken.status.isInstalled)
        XCTAssertFalse(halfbroken.status.isRemoved)

        let goneconf = try XCTUnwrap(database.package(named: "goneconf"))
        XCTAssertTrue(goneconf.status.isRemoved)
        XCTAssertFalse(goneconf.status.isBroken)
        XCTAssertFalse(goneconf.status.isInstalled)
        XCTAssertFalse(goneconf.status.needsConfigure)
        XCTAssertEqual(goneconf.status.serialized, "deinstall ok config-files")

        let bash = try XCTUnwrap(database.package(named: "bash"))
        XCTAssertTrue(bash.status.isInstalled)
        XCTAssertFalse(bash.status.isBroken)
        XCTAssertFalse(bash.status.needsConfigure)
        XCTAssertFalse(bash.status.isRemoved)
        XCTAssertTrue(bash.record.isEssential)
        XCTAssertTrue(bash.record.isProtected)
    }

    func testStatusParsingDefaults() {
        XCTAssertEqual(InstalledPackage.Status().serialized, "install ok installed")
        let partial = InstalledPackage.Status(parsing: "deinstall")
        XCTAssertEqual(partial.want, "deinstall")
        XCTAssertEqual(partial.flag, "ok")
        XCTAssertEqual(partial.state, "installed")

        let unpacked = InstalledPackage.Status(parsing: "install ok unpacked")
        XCTAssertTrue(unpacked.needsConfigure)
        XCTAssertTrue(unpacked.isBroken)
        XCTAssertFalse(unpacked.isInstalled)

        let badFlag = InstalledPackage.Status(parsing: "install reinstreq half-configured")
        XCTAssertTrue(badFlag.isBroken)
        XCTAssertTrue(badFlag.needsConfigure)
    }

    func testPresentAndBrokenExcludeRemovedPackages() throws {
        let database = try database()
        XCTAssertEqual(database.present.map(\.name).sorted(),
                       ["bash", "coreutils", "foo-app", "halfbroken", "libfoo1", "oldapp"],
                       "`goneconf` is deinstall/config-files, so it is not present")
        XCTAssertFalse(database.present.contains { $0.name == "goneconf" })
        XCTAssertEqual(database.brokenPackages.map(\.name), ["halfbroken"])
        XCTAssertEqual(database.present.count, database.count - 1)
    }

    // MARK: - Keys

    func testKeyFormatting() {
        XCTAssertEqual(InstalledPackage.key(for: stanza("arch-all-tool", architecture: "all")), "arch-all-tool")
        XCTAssertEqual(InstalledPackage.key(for: stanza("libfoo1")), "libfoo1:iphoneos-arm64")
        XCTAssertEqual(InstalledPackage(stanza: stanza("libfoo1")).key, "libfoo1:iphoneos-arm64")
        XCTAssertEqual(InstalledPackage(stanza: stanza("x", architecture: "all")).architecture, "all")
        XCTAssertEqual(InstalledPackage.key(for: ControlStanza(fields: [ControlField(name: "Package", value: "x")])),
                       "x", "a missing Architecture defaults to `all`")
        XCTAssertEqual(InstalledPackage.key(for: ControlStanza()), "",
                       "a stanza with no name has an empty key")
    }

    func testForeignArchitectureInstancesGetTheirOwnKey() {
        var database = InstalledPackageDatabase()
        database.set(stanza("libfoo1", architecture: "iphoneos-arm64"))
        database.set(stanza("libfoo1", architecture: "iphoneos-arm"))
        XCTAssertEqual(database.count, 2, "multi-arch keeps one entry per architecture")
        XCTAssertEqual(database.package(named: "libfoo1", architecture: "iphoneos-arm")?.architecture,
                       "iphoneos-arm")
        XCTAssertEqual(database.package(named: "libfoo1", architecture: "iphoneos-arm64")?.architecture,
                       "iphoneos-arm64")
        XCTAssertTrue(database.packages.keys.contains("libfoo1:iphoneos-arm"))

        // Setting the same key twice replaces the entry instead of duplicating it.
        database.set(stanza("libfoo1", version: "2.0-1", architecture: "iphoneos-arm"))
        XCTAssertEqual(database.count, 2)
        XCTAssertEqual(database.package(named: "libfoo1", architecture: "iphoneos-arm")?.version.raw, "2.0-1")
    }

    // MARK: - Mutation

    func testMarkRemovedKeepsConfigFiles() throws {
        var database = try database()
        database.markRemoved(name: "oldapp", purge: false)

        let kept = try XCTUnwrap(database.package(named: "oldapp"))
        XCTAssertEqual(kept.status.serialized, "deinstall ok config-files")
        XCTAssertTrue(kept.status.isRemoved)
        XCTAssertFalse(database.isInstalled("oldapp"))
        XCTAssertFalse(database.present.contains { $0.name == "oldapp" })
        XCTAssertEqual(database.count, 7, "the entry stays, only its status changes")
        XCTAssertEqual(kept.stanza["Version"], "1.0-1", "the rest of the stanza is preserved")
    }

    func testMarkRemovedPurgeDeletesEveryInstance() throws {
        var database = try database()
        database.markRemoved(name: "libfoo1", purge: true)
        XCTAssertNil(database.package(named: "libfoo1"))
        XCTAssertEqual(database.count, 6)

        var multi = InstalledPackageDatabase()
        multi.set(stanza("libfoo1", architecture: "iphoneos-arm64"))
        multi.set(stanza("libfoo1", architecture: "iphoneos-arm"))
        multi.markRemoved(name: "libfoo1", purge: true)
        XCTAssertEqual(multi.count, 0, "purge removes every architecture instance")
    }

    func testMarkRemovedOnSomethingThatIsNotThereIsANoOp() throws {
        var database = try database()
        database.markRemoved(name: "not-installed", purge: true)
        database.markRemoved(name: "not-installed", purge: false)
        XCTAssertEqual(database.count, 7)
    }

    // MARK: - Serialisation

    func testSerializedRoundTrips() throws {
        let database = try database()
        let text = database.serialized()
        let reparsed = InstalledPackageDatabase(parsing: text)

        XCTAssertEqual(reparsed.count, database.count)
        XCTAssertEqual(reparsed.packages.keys.sorted(), database.packages.keys.sorted())
        for key in database.packages.keys {
            XCTAssertEqual(reparsed.packages[key], database.packages[key],
                           "the stanza for \(key) did not survive the round trip")
        }
        XCTAssertEqual(reparsed.serialized(), text, "serialisation must be idempotent")

        let names = text.components(separatedBy: "\n")
            .filter { $0.hasPrefix("Package: ") }
            .map { String($0.dropFirst("Package: ".count)) }
        XCTAssertEqual(names, ["bash", "coreutils", "foo-app", "goneconf", "halfbroken", "libfoo1", "oldapp"])
    }

    func testSerializedIsStableAfterAMutation() throws {
        var database = try database()
        database.markRemoved(name: "oldapp", purge: false)
        let text = database.serialized()
        XCTAssertTrue(text.contains("Package: oldapp\nStatus: deinstall ok config-files\n"))
        XCTAssertEqual(InstalledPackageDatabase(parsing: text).serialized(), text)
    }

    func testDatabaseFromAnEmptyStatusFile() {
        let empty = InstalledPackageDatabase(parsing: "")
        XCTAssertEqual(empty.count, 0)
        XCTAssertTrue(empty.present.isEmpty)
        XCTAssertTrue(empty.all.isEmpty)
        XCTAssertTrue(empty.serialized().isEmpty)
        XCTAssertFalse(empty.isInstalled("bash"))

        // A stanza with no Package field is skipped rather than stored under "".
        let nameless = InstalledPackageDatabase(parsing: "Version: 1.0\nArchitecture: all\n")
        XCTAssertEqual(nameless.count, 0)
    }
}
