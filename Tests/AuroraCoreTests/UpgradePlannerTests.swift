import XCTest
@testable import AuroraCore

/// "12 updates available" must mean the same thing in the CLI and in the app, and a
/// held package must not be upgraded by one of them behind the other's back.
final class UpgradePlannerTests: XCTestCase {

    private func index() throws -> PackageIndex {
        PackageIndex(records: ControlParser.parse(try Fixture.text(Fixture.packagesIndex))
            .map { PackageRecord(stanza: $0) })
    }

    private func database() throws -> InstalledPackageDatabase {
        InstalledPackageDatabase(parsing: try Fixture.text(Fixture.status))
    }

    /// The fixture status file has foo-app at 1.9.0-1 while 2.0.0-1 is available,
    /// so exactly one upgrade exists out of the box.
    private func planner(_ policy: PackagePolicy = .default) throws -> UpgradePlanner {
        UpgradePlanner(
            available: try index(),
            installed: try database(),
            policy: DependencyResolver.Policy(
                architecture: "iphoneos-arm64",
                allowedArchitectures: ["iphoneos-arm64"],
                packagePolicy: policy
            )
        )
    }

    func testFindsTheUpgradeThatExists() throws {
        let plan = try planner().plan()
        XCTAssertEqual(plan.upgradable.map(\.name), ["foo-app"])
        XCTAssertEqual(plan.upgradable.first?.version.raw, "2.0.0-1")
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan.summary, "1 update")
    }

    func testHeldPackageIsReportedSeparatelyAndExcluded() throws {
        var policy = PackagePolicy.default
        policy.pin(.hold, for: "foo-app")

        let plan = try planner(policy).plan()
        XCTAssertTrue(plan.upgradable.isEmpty, "a hold must keep the package out of the update list")
        XCTAssertEqual(plan.held, ["foo-app"])
        XCTAssertEqual(plan.summary, "1 held")
    }

    func testHeldPackageIsUpgradedWhenExplicitlyAsked() throws {
        var policy = PackagePolicy.default
        policy.pin(.hold, for: "foo-app")

        let plan = try planner(policy).plan(includeHeld: true)
        XCTAssertEqual(plan.upgradable.map(\.name), ["foo-app"], "a hold is a default, not a lock")
        XCTAssertTrue(plan.held.isEmpty)
    }

    func testForbiddenPackageIsReportedAndNeverUpgraded() throws {
        var policy = PackagePolicy.default
        policy.pin(.forbid, for: "foo-app")

        let plan = try planner(policy).plan(includeHeld: true)
        XCTAssertEqual(plan.forbidden, ["foo-app"])
        XCTAssertTrue(plan.upgradable.isEmpty)
    }

    func testPackageMissingFromEveryRepositoryIsReportedAsOrphaned() throws {
        // halfbroken and goneconf are installed but exist in no index.
        let plan = try planner().plan()
        XCTAssertTrue(plan.orphaned.contains("halfbroken"),
                      "installed packages no repository offers must be visible, got \(plan.orphaned)")
    }

    func testQueueMatchesThePlan() throws {
        let queue = try planner().queue()
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.action(for: "foo-app")?.kind, .upgrade)
    }

    func testPinnedBackwardsIsReportedRatherThanSilentlyIgnored() throws {
        // Pin foo-app to an older version than the installed one: the planner must
        // say so instead of pretending there is nothing to do.
        var policy = PackagePolicy.default
        policy.pin(.version("1.9.0-1"), for: "foo-app")
        let plan = try planner(policy).plan()
        XCTAssertTrue(plan.upgradable.isEmpty)
        XCTAssertEqual(plan.pinnedBackwards.map(\.name), ["foo-app"])
    }
}
