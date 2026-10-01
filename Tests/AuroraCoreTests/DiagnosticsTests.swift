import XCTest
@testable import AuroraCore

/// Diagnostics runs against whatever device it is on, so these tests exercise the
/// decision logic rather than asserting a particular machine's state.
final class DiagnosticsTests: XCTestCase {

    private func environment(root: String, layout: JailbreakEnvironment.Layout, status: String) -> JailbreakEnvironment {
        JailbreakEnvironment(
            layout: layout,
            root: root,
            architecture: "iphoneos-arm64",
            dpkgPath: layout.isJailbroken ? root + "usr/bin/dpkg" : nil,
            statusFilePath: status
        )
    }

    private func temporaryDirectory() throws -> String {
        let path = NSTemporaryDirectory() + "aurora-diag-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    func testHealthyDatabaseReportsNoProblems() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let status = directory + "/status"
        try Data(try Fixture.text(Fixture.status).utf8).write(to: URL(fileURLWithPath: status))

        let report = Diagnostics(environment: environment(root: "/", layout: .rootful, status: status)).run()

        XCTAssertTrue(report.statusFilePresent)
        XCTAssertEqual(report.installedCount, 7)
        // bash, coreutils, libfoo1, foo-app, oldapp are present; halfbroken is
        // present-but-unconfigured and goneconf is only configuration files.
        XCTAssertEqual(report.presentCount, 6, "goneconf is removed; halfbroken is present but broken")
        XCTAssertEqual(report.pendingConfiguration.map(\.name), ["halfbroken"],
                       "an unpacked-but-unconfigured package is the classic half-finished transaction")
        XCTAssertEqual(report.obsoleteConfiguration.map(\.name), ["goneconf"])
        XCTAssertFalse(report.isHealthy, "pending configuration is not healthy")
    }

    func testMissingDatabaseIsReportedNotCrashed() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let report = Diagnostics(environment: environment(
            root: directory + "/",
            layout: .rootless,
            status: directory + "/nonexistent/status"
        )).run()

        XCTAssertFalse(report.statusFilePresent)
        XCTAssertEqual(report.installedCount, 0)
        XCTAssertTrue(report.notes.contains { $0.contains("database is missing") })
    }

    func testNotJailbrokenSaysSoInsteadOfFailing() throws {
        let report = Diagnostics(environment: environment(root: "/", layout: .notJailbroken, status: "/nonexistent")).run()
        XCTAssertFalse(report.jailbroken)
        XCTAssertNil(report.dpkgPath)
        XCTAssertEqual(report.summary, "No jailbreak detected")
        XCTAssertTrue(report.notes.contains { $0.contains("does not look jailbroken") })
    }

    func testMissingDependenciesAreFoundAndClassified() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let status = directory + "/status"
        // A device with an installed package whose dependency is nowhere: exactly
        // what a dead repository leaves behind.
        let text = """
        Package: lonely
        Status: install ok installed
        Version: 1.0-1
        Architecture: iphoneos-arm64
        Depends: vanished (>= 1.0), present

        Package: present
        Status: install ok installed
        Version: 2.0-1
        Architecture: iphoneos-arm64

        """
        try Data(text.utf8).write(to: URL(fileURLWithPath: status))

        let report = Diagnostics(environment: environment(root: "/", layout: .rootful, status: status)).run()
        XCTAssertEqual(report.missingDependencies.map(\.package), ["lonely"])
        XCTAssertEqual(report.missingDependencies.first?.clause, "vanished (>= 1.0)",
                       "a satisfied clause must not be reported")
        XCTAssertFalse(report.missingDependencies.first?.satisfiableFromRepositories ?? true,
                      "with no index loaded, nothing can be classified as fixable")
    }

    func testRepairPlanConfiguresPendingAndPurgesLeftoversOnRequest() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let status = directory + "/status"
        try Data(try Fixture.text(Fixture.status).utf8).write(to: URL(fileURLWithPath: status))
        let diagnostics = Diagnostics(environment: environment(root: "/", layout: .rootful, status: status))
        let report = diagnostics.run()

        let configureOnly = diagnostics.repairPlan(for: report)
        XCTAssertEqual(configureOnly.steps.count, 1)
        guard case .configure = configureOnly.steps.first else {
            return XCTFail("expected a configure step, got \(configureOnly.steps)")
        }
        XCTAssertTrue(configureOnly.removed.isEmpty)

        let withPurge = diagnostics.repairPlan(for: report, purgeObsoleteConfiguration: true)
        XCTAssertEqual(withPurge.removed.map(\.package.name), ["goneconf"])
        XCTAssertTrue(withPurge.removed.first?.purge ?? false)
        XCTAssertEqual(withPurge.steps.count, 2, "the purge precedes the configure pass")
    }

    func testDirectorySizeIsRecursive() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try FileManager.default.createDirectory(atPath: directory + "/nested", withIntermediateDirectories: true)
        try Data(repeating: 0, count: 100).write(to: URL(fileURLWithPath: directory + "/a"))
        try Data(repeating: 0, count: 250).write(to: URL(fileURLWithPath: directory + "/nested/b"))

        XCTAssertEqual(Diagnostics.directorySize(at: directory), 350)
        XCTAssertEqual(Diagnostics.directorySize(at: directory + "/nothing-here"), 0)
    }
}
