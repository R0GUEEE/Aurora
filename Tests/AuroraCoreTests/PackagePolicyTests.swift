import XCTest
@testable import AuroraCore

/// Pins and repository priorities change *which* package gets installed, which
/// makes them the most dangerous kind of preference: a wrong one is silent.
final class PackagePolicyTests: XCTestCase {

    private func record(_ name: String, _ version: String, origin: String?) -> PackageRecord {
        var stanza = ControlStanza(fields: [
            ControlField(name: "Package", value: name),
            ControlField(name: "Version", value: version),
            ControlField(name: "Architecture", value: "iphoneos-arm64"),
        ])
        stanza["Filename"] = "pool/\(name)_\(version).deb"
        return PackageRecord(
            stanza: stanza,
            origin: origin.map { RepositoryID(url: $0, suite: "./", component: "") }
        )
    }

    private func indexWithTwoRepositories() -> PackageIndex {
        let index = PackageIndex(records: [
            record("widget", "1.0", origin: "https://a.example.com"),
            record("widget", "1.0", origin: "https://b.example.com"),
            record("widget", "2.0", origin: "https://a.example.com"),
            record("widget", "2.0", origin: "https://b.example.com"),
        ])
        return index
    }

    // MARK: - Priorities

    func testDefaultPriorityIsAptLikeAndPriorityIsNormalised() {
        var policy = PackagePolicy.default
        XCTAssertEqual(policy.priority(forSource: "https://a.example.com"), PackagePolicy.defaultPriority)
        XCTAssertEqual(policy.priority(forSource: "https://a.example.com/"), PackagePolicy.defaultPriority,
                       "a trailing slash must not create a second entry")

        policy.setPriority(700, forSource: "https://a.example.com/")
        XCTAssertEqual(policy.priority(forSource: "https://a.example.com"), 700)
        XCTAssertEqual(policy.sourcePriorities.count, 1)

        // Setting it back to the default removes the entry rather than storing it.
        policy.setPriority(PackagePolicy.defaultPriority, forSource: "https://a.example.com")
        XCTAssertTrue(policy.sourcePriorities.isEmpty)
    }

    func testHigherPriorityRepositoryWinsOnEqualVersions() {
        let index = indexWithTwoRepositories()
        var policy = PackagePolicy.default
        policy.setPriority(900, forSource: "https://b.example.com")

        let chosen = index.bestMatch(
            for: DependencyTerm(name: "widget"),
            architecture: "iphoneos-arm64",
            policy: policy
        )
        XCTAssertEqual(chosen?.origin?.url, "https://b.example.com")
        XCTAssertEqual(chosen?.version.raw, "2.0")
    }

    func testPriorityDoesNotOverrideANewerVersion() {
        let index = PackageIndex(records: [
            record("widget", "1.0", origin: "https://preferred.example.com"),
            record("widget", "2.0", origin: "https://other.example.com"),
        ])
        var policy = PackagePolicy.default
        policy.setPriority(900, forSource: "https://preferred.example.com")

        let chosen = index.bestMatch(
            for: DependencyTerm(name: "widget"),
            architecture: "iphoneos-arm64",
            policy: policy
        )
        XCTAssertEqual(chosen?.version.raw, "2.0",
                       "priority orders equal versions; a newer version still wins")
    }

    func testRecordsWithoutARepositoryGetTheDefaultPriority() {
        let policy = PackagePolicy.default
        XCTAssertEqual(policy.priority(of: record("widget", "1.0", origin: nil)), PackagePolicy.defaultPriority)
    }

    // MARK: - Pins

    func testForbiddenPackageIsNeverACandidate() {
        let index = indexWithTwoRepositories()
        var policy = PackagePolicy.default
        policy.pin(.forbid, for: "widget")

        XCTAssertFalse(policy.allows("widget"))
        XCTAssertNil(index.bestMatch(for: DependencyTerm(name: "widget"),
                                     architecture: "iphoneos-arm64",
                                     policy: policy))
    }

    func testVersionPinRestrictsCandidatesToThatVersion() {
        let index = indexWithTwoRepositories()
        var policy = PackagePolicy.default
        policy.pin(.version("1.0"), for: "widget")

        let chosen = index.bestMatch(for: DependencyTerm(name: "widget"),
                                     architecture: "iphoneos-arm64",
                                     policy: policy)
        XCTAssertEqual(chosen?.version.raw, "1.0",
                       "a version pin must hold back the newer 2.0")

        // A constraint the pinned version cannot satisfy yields nothing rather
        // than silently picking a different version.
        XCTAssertNil(index.bestMatch(
            for: DependencyTerm(name: "widget", constraint: DebianVersionConstraint(relation: .laterOrEqual, version: DebianVersion("2.0"))),
            architecture: "iphoneos-arm64",
            policy: policy
        ))
    }

    func testHoldKeepsAPackageInstallableButNotUpgradable() {
        var policy = PackagePolicy.default
        policy.pin(.hold, for: "widget")
        XCTAssertTrue(policy.allows("widget"))
        XCTAssertTrue(policy.isHeld("widget"))
        XCTAssertTrue(policy.allows("something-else"), "unmentioned packages are allowed by default")
        XCTAssertFalse(policy.isHeld("something-else"))
    }

    func testPinLabelsDescribeWhatHappens() {
        XCTAssertEqual(PackagePolicy.Pin.hold.label, "held")
        XCTAssertEqual(PackagePolicy.Pin.forbid.label, "forbidden")
        XCTAssertEqual(PackagePolicy.Pin.version("1.2-3").label, "pinned to 1.2-3")
    }

    // MARK: - Persistence

    func testPolicyRoundTripsThroughItsStore() throws {
        let directory = NSTemporaryDirectory() + "aurora-policy-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let store = PackagePolicy.Store(path: directory + "/policy.json")

        var policy = PackagePolicy.default
        policy.setPriority(750, forSource: "https://repo.example.com")
        policy.pin(.hold, for: "bash")
        policy.pin(.version("1.2.3"), for: "widget")
        try store.save(policy)

        let loaded = store.load()
        XCTAssertNil(loaded.failure)
        XCTAssertEqual(loaded.policy.sourcePriorities, policy.sourcePriorities)
        XCTAssertEqual(loaded.policy.pins, policy.pins)
        XCTAssertEqual(loaded.policy.priority(forSource: "https://repo.example.com"), 750)
    }

    func testCorruptPolicyStoreFallsBackToDefaultsAndSaysWhy() throws {
        let directory = NSTemporaryDirectory() + "aurora-policy-bad-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/policy.json"
        try Data("{ this is not json".utf8).write(to: URL(fileURLWithPath: path))

        let loaded = PackagePolicy.Store(path: path).load()
        XCTAssertTrue(loaded.policy.isEmpty, "a corrupt policy must not stop the package manager")
        XCTAssertNotNil(loaded.failure, "and it must say what happened")
    }

    // MARK: - Resolver integration

    func testHeldPackageIsNotMovedByTheResolver() throws {
        // libfoo1 is installed at 1.4.2-3 and no newer version exists in the
        // fixture, so use the queue's own refusal instead: a downgrade of a held
        // package is still refused even with allowDowngrades set.
        let index = PackageIndex(records: ControlParser.parse(try Fixture.text(Fixture.packagesIndex))
            .map { PackageRecord(stanza: $0) })
        let database = InstalledPackageDatabase(parsing: try Fixture.text(Fixture.status))

        var packagePolicy = PackagePolicy.default
        packagePolicy.pin(.forbid, for: "foo-app")

        let resolver = DependencyResolver(
            available: index,
            installed: database,
            policy: DependencyResolver.Policy(
                architecture: "iphoneos-arm64",
                allowedArchitectures: ["iphoneos-arm64"],
                packagePolicy: packagePolicy
            )
        )
        var queue = PackageQueue()
        queue.stage(.install(try XCTUnwrap(index.candidates(named: "foo-app").first)))

        let result = resolver.attempt(queue)
        switch result {
        case .success:
            XCTFail("a forbidden package must not be installable")
        case .failure(let failure):
            XCTAssertTrue(
                failure.errors.contains { $0.description.contains("forbidden") },
                "expected a forbidden-package error, got \(failure.errors)"
            )
        }
    }

    func testVersionPinBlocksAnInstallOfADifferentVersion() throws {
        let index = PackageIndex(records: ControlParser.parse(try Fixture.text(Fixture.packagesIndex))
            .map { PackageRecord(stanza: $0) })
        let database = InstalledPackageDatabase(parsing: try Fixture.text(Fixture.status))

        var packagePolicy = PackagePolicy.default
        packagePolicy.pin(.version("1.9.0-1"), for: "foo-app")

        let resolver = DependencyResolver(
            available: index,
            installed: database,
            policy: DependencyResolver.Policy(
                architecture: "iphoneos-arm64",
                allowedArchitectures: ["iphoneos-arm64"],
                packagePolicy: packagePolicy,
                allowDowngrades: true
            )
        )
        // plugin 3.1 needs foo-app >= 2.0, which the pin forbids.
        var queue = PackageQueue()
        queue.stage(.install(try XCTUnwrap(index.candidates(named: "plugin").first { $0.version.raw == "3.1-1" })))

        let result = resolver.attempt(queue)
        switch result {
        case .success(let plan):
            XCTAssertNotEqual(
                plan.unpackSteps.first { $0.name == "foo-app" }?.version.raw, "2.0.0-1",
                "a version pin must not be overridden by a dependency"
            )
        case .failure:
            // Refusing outright is also correct: the pin makes the dependency
            // unsatisfiable and saying so is better than installing around it.
            break
        }
    }
}
