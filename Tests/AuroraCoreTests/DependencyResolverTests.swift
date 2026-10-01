import XCTest
@testable import AuroraCore

/// The resolver is the part of Aurora that can break a device, so this file walks
/// the whole fixture world: an upgrade that must not pull anything, a virtual
/// `Provides`, an uninstallable package, dependent removal, essential packages,
/// conflicts, order, cycles and the size arithmetic.
final class DependencyResolverTests: XCTestCase {

    // MARK: - Helpers

    private func fixtureIndex() throws -> PackageIndex {
        PackageIndex(records: ControlParser.parse(try Fixture.text(Fixture.packagesIndex))
            .map { PackageRecord(stanza: $0) })
    }

    private func fixtureDatabase() throws -> InstalledPackageDatabase {
        InstalledPackageDatabase(parsing: try Fixture.text(Fixture.status))
    }

    private func makeResolver(_ policy: DependencyResolver.Policy = .default) throws -> DependencyResolver {
        DependencyResolver(available: try fixtureIndex(), installed: try fixtureDatabase(), policy: policy)
    }

    private func record(_ name: String, _ version: String? = nil,
                        in index: PackageIndex) throws -> PackageRecord {
        let candidates = index.candidates(named: name)
        if let version {
            return try XCTUnwrap(candidates.first { $0.version.raw == version },
                                 "\(name) \(version) is not in the fixture index")
        }
        return try XCTUnwrap(candidates.first, "\(name) is not in the fixture index")
    }

    private func staged(_ action: PackageAction) -> PackageQueue {
        var queue = PackageQueue()
        queue.stage(action)
        return queue
    }

    private func described(_ steps: [TransactionPlan.Step]) -> [String] {
        steps.map { step in
            switch step {
            case .remove(let package, let purge): return "remove \(package.name)\(purge ? " (purge)" : "")"
            case .unpack(let record): return "unpack \(record.name)"
            case .configure(let name): return "configure \(name)"
            }
        }
    }

    /// Unwraps the failure side of `attempt(_:)`, failing the test on success.
    private func resolutionFailure(_ result: Result<TransactionPlan, ResolutionFailure>,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) -> ResolutionFailure? {
        switch result {
        case .success:
            XCTFail("expected the queue to fail to resolve", file: file, line: line)
            return nil
        case .failure(let failure):
            return failure
        }
    }

    // MARK: - (a) An upgrade that pulls nothing else

    func testInstallingPluginUpgradesFooAppAndPullsNothingElse() throws {
        let index = try fixtureIndex()
        let plan = try makeResolver().resolve(staged(.install(try record("plugin", "3.1-1", in: index))))

        XCTAssertEqual(plan.installed.map(\.name), ["plugin"])
        XCTAssertEqual(plan.upgraded.map(\.name), ["foo-app"])
        XCTAssertEqual(plan.upgraded.first?.version.raw, "2.0.0-1", "the >= 2.0 dependency forces the new version")
        XCTAssertTrue(plan.downgraded.isEmpty)
        XCTAssertTrue(plan.reinstalled.isEmpty)
        XCTAssertTrue(plan.removed.isEmpty)
        XCTAssertTrue(plan.dependencies.isEmpty,
                      "foo-app and libfoo1 are already installed, so nothing is a new dependency")

        XCTAssertEqual(plan.unpackSteps.map(\.name), ["foo-app", "plugin"])
        XCTAssertEqual(described(plan.steps),
                       ["unpack foo-app", "unpack plugin", "configure foo-app", "configure plugin"])
        XCTAssertEqual(plan.summary, "Install 1, Upgrade 1")
        XCTAssertFalse(plan.isEmpty)
        XCTAssertEqual(plan.downloadSize, 23296 + 618496)
        XCTAssertEqual(plan.installedSize, Int64(64 + 2048 - 2000) * 1024,
                       "the upgrade's new 2048 KiB replaces the installed 2000 KiB")
    }

    func testUnrelatedInstallCanProceedWithPreexistingUnmetDependency() throws {
        var database = try fixtureDatabase()
        database.set(ControlStanza(fields: [
            ControlField(name: "Package", value: "stale-broken-package"),
            ControlField(name: "Version", value: "1"),
            ControlField(name: "Architecture", value: "iphoneos-arm64"),
            ControlField(name: "Status", value: "install ok installed"),
            ControlField(name: "Depends", value: "missing-from-all-repositories"),
        ]))
        let index = try fixtureIndex()
        let record = try XCTUnwrap(index.candidates(named: "arch-all-tool").first)
        let resolver = DependencyResolver(available: index, installed: database, policy: .default)

        let plan = try resolver.resolve(staged(.install(record)))
        XCTAssertTrue(plan.installed.contains { $0.name == "arch-all-tool" })
        XCTAssertFalse(plan.installed.contains { $0.name == "stale-broken-package" })
    }

    // MARK: - (b) A virtual name

    func testInstallingMailclientPullsTheVirtualProvider() throws {
        let index = try fixtureIndex()
        let plan = try makeResolver().resolve(staged(.install(try record("mailclient", in: index))))

        XCTAssertEqual(plan.installed.map(\.name), ["mailclient", "mailserver"])
        XCTAssertEqual(plan.dependencies.map(\.name), ["mailserver"],
                       "mailserver is pulled in as `mail-transport-agent` and flagged as a dependency")
        XCTAssertEqual(plan.unpackSteps.map(\.name), ["mailserver", "mailclient"])
        XCTAssertTrue(plan.upgraded.isEmpty)
    }

    func testTheProviderWarningIsEmittedWhenTheProviderIsAlreadyInTheSet() throws {
        let index = try fixtureIndex()
        var queue = PackageQueue()
        queue.stage(.install(try record("mailserver", in: index)))
        queue.stage(.install(try record("mailclient", in: index)))
        let plan = try makeResolver().resolve(queue)

        XCTAssertTrue(plan.warnings.contains(.packageProvides(virtual: "mail-transport-agent",
                                                              providedBy: "mailserver")),
                      "the user should be told why mailserver is being installed")
        XCTAssertEqual(plan.installed.map(\.name), ["mailclient", "mailserver"])
    }

    // MARK: - (c) and (j) An uninstallable package

    func testInstallingBrokenAppFailsAndProducesNoPlan() throws {
        let index = try fixtureIndex()
        let resolver = try makeResolver()
        let queue = staged(.install(try record("brokenapp", in: index)))

        XCTAssertThrowsError(try resolver.resolve(queue)) { error in
            guard let failure = error as? ResolutionFailure else {
                XCTFail("expected a ResolutionFailure, got \(error)")
                return
            }
            XCTAssertTrue(failure.errors.contains(.unsatisfiedDependency(package: "brokenapp",
                                                                         clause: "does-not-exist (>= 1)")))
            XCTAssertTrue(failure.errors.contains(.packageNotFound(term: "does-not-exist",
                                                                   requestedBy: "brokenapp")))
            XCTAssertEqual(failure.errors.count, 2)
            XCTAssertTrue(failure.description.contains("does-not-exist"))
        }
    }

    func testAttemptReturnsFailureInsteadOfThrowing() throws {
        let index = try fixtureIndex()
        let resolver = try makeResolver()

        let broken = resolutionFailure(resolver.attempt(staged(.install(try record("brokenapp", in: index)))))
        XCTAssertEqual(broken?.errors.contains(.packageNotFound(term: "does-not-exist",
                                                                requestedBy: "brokenapp")),
                       true)

        // The same entry point still reports success for a queue that does resolve.
        switch resolver.attempt(staged(.install(try record("newapp", in: index)))) {
        case .success(let plan):
            XCTAssertEqual(plan.installed.map(\.name), ["newapp"])
        case .failure(let failure):
            XCTFail("newapp should resolve, got \(failure.description)")
        }
    }

    func testRemovingSomethingThatIsNotInstalledIsAnError() throws {
        let result = try makeResolver().attempt(staged(.remove(name: "plugin", purge: false)))
        let failure = resolutionFailure(result)
        XCTAssertEqual(failure?.errors, [ResolutionError.notInstalled(name: "plugin")])
    }

    // MARK: - (d) Removing a dependency

    func testRemovingLibfoo1TakesItsDependentsWithIt() throws {
        let plan = try makeResolver().resolve(staged(.remove(name: "libfoo1", purge: false)))

        XCTAssertEqual(plan.removed.map { $0.package.name }, ["foo-app", "libfoo1"],
                       "foo-app depends on libfoo1, so it goes too; removals are sorted by name")
        XCTAssertTrue(plan.removed.allSatisfy { !$0.purge })
        XCTAssertTrue(plan.unpackSteps.isEmpty)
        XCTAssertTrue(plan.warnings.contains(.removingDependents(package: "libfoo1", dependents: ["foo-app"])))
        XCTAssertEqual(described(plan.steps), ["remove foo-app", "remove libfoo1"])
        XCTAssertEqual(plan.summary, "Remove 2")
        XCTAssertEqual(plan.installedSize, -Int64(2000 + 312) * 1024,
                       "removing two packages takes their installed size off the disk")
        XCTAssertEqual(plan.downloadSize, 0)
    }

    func testRemovingLibfoo1IsRefusedWhenDependentsMayNotBeRemoved() throws {
        var policy = DependencyResolver.Policy.default
        policy.removeDependentsWithPackage = false
        let resolver = try makeResolver(policy)

        let failure = resolutionFailure(resolver.attempt(staged(.remove(name: "libfoo1", purge: false))))
        XCTAssertEqual(failure?.errors,
                       [ResolutionError.protectedPackage(name: "foo-app",
                                                         reason: "it depends on libfoo1, which you are removing")])
    }

    func testRemovingADependencyNothingElseUsesSucceeds() throws {
        var database = try fixtureDatabase()
        database.markRemoved(name: "foo-app", purge: true)
        let resolver = DependencyResolver(available: try fixtureIndex(), installed: database)
        let plan = try resolver.resolve(staged(.remove(name: "libfoo1", purge: true)))

        XCTAssertEqual(plan.removed.map { $0.package.name }, ["libfoo1"])
        XCTAssertTrue(plan.removed.first?.purge ?? false)
        XCTAssertTrue(plan.warnings.isEmpty)
    }

    // MARK: - (e) Essential packages

    func testRemovingEssentialBashIsRefused() throws {
        let failure = resolutionFailure(try makeResolver().attempt(staged(.remove(name: "bash", purge: true))))
        XCTAssertEqual(failure?.errors, [ResolutionError.protectedPackage(name: "bash", reason: "it is an essential package")])
    }

    func testEssentialPackagesAreProtectedRegardlessOfEssentialPolicyForRemoval() throws {
        var policy = DependencyResolver.Policy.default
        policy.protectEssential = false
        let resolver = try makeResolver(policy)
        let plan = try resolver.resolve(staged(.remove(name: "bash", purge: false)))

        XCTAssertEqual(plan.removed.map { $0.package.name }.sorted(), ["bash", "coreutils", "foo-app"],
                       "with protection off, coreutils goes because it needs bash")
    }

    // MARK: - (f) Conflicts

    func testInstallingNewappRemovesThePackageItConflictsWith() throws {
        let index = try fixtureIndex()
        let plan = try makeResolver().resolve(staged(.install(try record("newapp", in: index))))

        // `newapp` declares `Conflicts: oldapp` and `Replaces: oldapp`: it takes the
        // files over *and* the old package has to go, so dpkg gets a removal step
        // before the unpack and the user gets told why.
        XCTAssertEqual(plan.installed.map(\.name), ["newapp"])
        XCTAssertEqual(plan.removed.map { $0.package.name }, ["oldapp"])
        XCTAssertFalse(plan.removed.first?.purge ?? true, "a conflict removal keeps conffiles")
        XCTAssertTrue(plan.warnings.contains(.conflictingPackageRemoved(package: "oldapp",
                                                                        because: "newapp")))
        XCTAssertEqual(described(plan.steps),
                       ["remove oldapp", "unpack newapp", "configure newapp"],
                       "the conflicting package has to be gone before the newcomer unpacks")
        XCTAssertEqual(plan.summary, "Install 1, Remove 1")
    }

    func testAConflictWithAPackageThatIsNotInstalledJustDropsItFromThePlan() throws {
        // `arch-all-tool` is in the index but not installed, so a conflict with it
        // removes it from the target set without a removal step — dpkg never had it.
        let conflicting = PackageRecord(stanza: ControlStanza(fields: [
            ControlField(name: "Package", value: "conflicting-app"),
            ControlField(name: "Version", value: "1.0-1"),
            ControlField(name: "Architecture", value: "iphoneos-arm64"),
            ControlField(name: "Conflicts", value: "arch-all-tool"),
            ControlField(name: "Description", value: "Conflicts with arch-all-tool"),
        ]))
        var index = try fixtureIndex()
        index.append(conflicting)

        let resolver = DependencyResolver(available: index, installed: try fixtureDatabase())
        var queue = PackageQueue()
        queue.stage(.install(conflicting))
        queue.stage(.install(try record("arch-all-tool", in: index)))
        let plan = try resolver.resolve(queue)

        XCTAssertEqual(plan.installed.map(\.name), ["conflicting-app"],
                       "the loser is dropped from the target set")
        XCTAssertTrue(plan.removed.isEmpty, "nothing has to be removed on disk")
        XCTAssertFalse(plan.warnings.contains { warning in
            if case .conflictingPackageRemoved = warning { return true }
            return false
        })
        XCTAssertEqual(described(plan.steps), ["unpack conflicting-app", "configure conflicting-app"])
    }

    // MARK: - (g) Order

    func testDependenciesAreUnpackedBeforeTheirDependents() throws {
        let index = try fixtureIndex()
        var database = try fixtureDatabase()
        database.markRemoved(name: "libfoo1", purge: true)
        database.markRemoved(name: "foo-app", purge: true)
        let resolver = DependencyResolver(available: index, installed: database)

        let plan = try resolver.resolve(staged(.install(try record("plugin", "3.1-1", in: index))))

        XCTAssertEqual(plan.unpackSteps.map(\.name), ["libfoo1", "foo-app", "plugin"])
        XCTAssertEqual(described(plan.steps),
                       ["unpack libfoo1", "unpack foo-app", "unpack plugin",
                        "configure libfoo1", "configure foo-app", "configure plugin"])
        XCTAssertEqual(plan.installed.map(\.name), ["foo-app", "libfoo1", "plugin"])
        XCTAssertEqual(plan.dependencies.map(\.name), ["foo-app", "libfoo1"])
        XCTAssertTrue(plan.warnings.isEmpty, "libfoo1 satisfies newapp-style alternatives directly")
    }

    // MARK: - (h) Cycles

    func testDependencyCyclesDoNotHangAndAreUnpackedTogether() throws {
        let index = try fixtureIndex()
        let resolver = DependencyResolver(available: index, installed: InstalledPackageDatabase())

        let plan = try resolver.resolve(staged(.install(try record("cyc-a", in: index))))

        XCTAssertEqual(Set(plan.unpackSteps.map(\.name)), ["cyc-a", "cyc-b"])
        XCTAssertEqual(plan.unpackSteps.map(\.name), ["cyc-b", "cyc-a"],
                       "the cycle is broken at the entry point, deterministically")
        XCTAssertEqual(plan.dependencies.map(\.name), ["cyc-b"])
        XCTAssertEqual(Set(plan.warnings), [.dependencyCycle(packages: ["cyc-a:iphoneos-arm64", "cyc-b:iphoneos-arm64"])])
        XCTAssertEqual(plan.installed.map(\.name), ["cyc-a", "cyc-b"])
    }

    // MARK: - (i) Sizes

    func testSizesOnASimpleUpgrade() throws {
        let index = try fixtureIndex()
        let resolver = DependencyResolver(available: index, installed: try fixtureDatabase())
        let plan = try resolver.resolve(staged(.upgrade(try record("foo-app", "2.0.0-1", in: index))))

        XCTAssertEqual(plan.upgraded.map(\.name), ["foo-app"])
        XCTAssertEqual(plan.installed.map(\.name), [])
        XCTAssertEqual(plan.downloadSize, 618496, "only foo-app 2.0.0-1 is downloaded")
        XCTAssertEqual(plan.installedSize, Int64(2048 - 2000) * 1024,
                       "Installed-Size is in kibibytes, and the replaced copy is subtracted")
        XCTAssertEqual(plan.summary, "Upgrade 1")
        XCTAssertTrue(plan.warnings.isEmpty)
    }

    func testSizesIncludeDependenciesAndSubtractRemovals() throws {
        let index = try fixtureIndex()
        let plan = try makeResolver().resolve(staged(.install(try record("plugin", "3.1-1", in: index))))
        XCTAssertEqual(plan.downloadSize, 23296 + 618496)
        XCTAssertEqual(plan.installedSize, Int64(64 + 2048 - 2000) * 1024)

        let removal = try makeResolver().resolve(staged(.remove(name: "oldapp", purge: true)))
        XCTAssertEqual(removal.installedSize, -100 * 1024)
        XCTAssertEqual(removal.downloadSize, 0)
    }

    // MARK: - Policy

    func testRecommendsAreOnlyInstalledWhenThePolicyAsksForThem() throws {
        let index = try fixtureIndex()
        var database = try fixtureDatabase()
        database.markRemoved(name: "coreutils", purge: true)

        let quiet = DependencyResolver(available: index, installed: database)
        let plan = try quiet.resolve(staged(.install(try record("plugin", "3.1-1", in: index))))
        XCTAssertFalse(plan.installed.contains { $0.name == "coreutils" })
        XCTAssertTrue(plan.warnings.contains(.recommendsNotInstalled(package: "plugin",
                                                                    missing: ["coreutils"])))

        var policy = DependencyResolver.Policy.default
        policy.installRecommends = true
        let eager = DependencyResolver(available: index, installed: database, policy: policy)
        let eagerPlan = try eager.resolve(staged(.install(try record("plugin", "3.1-1", in: index))))
        XCTAssertTrue(eagerPlan.installed.contains { $0.name == "coreutils" },
                      "Recommends: coreutils is installed when the policy asks for it")
        XCTAssertFalse(eagerPlan.warnings.contains { warning in
            if case .recommendsNotInstalled = warning { return true }
            return false
        })
    }

    func testDowngradesAreRefusedByDefault() throws {
        // foo-app 1.9.0-1 is installed; staging an older version as a downgrade
        // must be refused rather than turned into an accidental uninstall.
        let older = PackageRecord(stanza: ControlStanza(fields: [
            ControlField(name: "Package", value: "foo-app"),
            ControlField(name: "Version", value: "1.0-1"),
            ControlField(name: "Architecture", value: "iphoneos-arm64"),
        ]))
        let refusal = resolutionFailure(try makeResolver().attempt(staged(.downgrade(older))))
        XCTAssertEqual(refusal?.errors, [ResolutionError.downgradeRefused(package: "foo-app",
                                                                          from: "1.9.0-1", to: "1.0-1")])
    }

    func testAnyActionThatWouldRegressAVersionIsRefused() throws {
        // The refusal is not limited to the `.downgrade` action: an install or an
        // upgrade that resolves to an older version is a downgrade too.
        let older = PackageRecord(stanza: ControlStanza(fields: [
            ControlField(name: "Package", value: "foo-app"),
            ControlField(name: "Version", value: "1.0-1"),
            ControlField(name: "Architecture", value: "iphoneos-arm64"),
        ]))
        for action in [PackageAction.install(older), .upgrade(older), .downgrade(older)] {
            let failure = resolutionFailure(try makeResolver().attempt(staged(action)))
            XCTAssertEqual(failure?.errors, [ResolutionError.downgradeRefused(package: "foo-app",
                                                                              from: "1.9.0-1", to: "1.0-1")])
        }
    }

    func testDowngradesAreAllowedWhenThePolicySaysSo() throws {
        let index = try fixtureIndex()
        var database = try fixtureDatabase()
        database.set(try record("foo-app", "2.0.0-1", in: index).stanza)
        var policy = DependencyResolver.Policy.default
        policy.allowDowngrades = true

        let resolver = DependencyResolver(available: index, installed: database, policy: policy)
        let plan = try resolver.resolve(staged(.downgrade(try record("foo-app", "1.9.0-1", in: index))))

        XCTAssertEqual(plan.downgraded.map(\.name), ["foo-app"])
        XCTAssertEqual(plan.downgraded.first?.version.raw, "1.9.0-1")
        XCTAssertTrue(plan.upgraded.isEmpty)
        XCTAssertTrue(plan.warnings.contains(.downgrade(package: "foo-app",
                                                        from: "2.0.0-1", to: "1.9.0-1")))
        XCTAssertEqual(plan.summary, "Downgrade 1")
    }

    func testReinstallingTheSameVersionIsAReinstallNotADowngrade() throws {
        let index = try fixtureIndex()
        let plan = try makeResolver().resolve(staged(.reinstall(try record("foo-app", "1.9.0-1", in: index))))
        XCTAssertEqual(plan.reinstalled.map(\.name), ["foo-app"])
        XCTAssertTrue(plan.downgraded.isEmpty)
        XCTAssertTrue(plan.upgraded.isEmpty)
        XCTAssertEqual(plan.summary, "Reinstall 1")
    }

    func testAnEmptyQueueProducesAnEmptyPlan() throws {
        let plan = try makeResolver().resolve(PackageQueue())
        XCTAssertTrue(plan.isEmpty)
        XCTAssertEqual(plan.summary, "No changes")
        XCTAssertEqual(plan.installedSize, 0)
        XCTAssertEqual(plan.downloadSize, 0)
        XCTAssertTrue(plan.warnings.isEmpty)
    }

    func testTheFullQueueStagesEveryKindOfChange() throws {
        let index = try fixtureIndex()
        var queue = PackageQueue()
        queue.stage(.install(try record("newapp", in: index)))
        queue.stage(.upgrade(try record("plugin", "3.1-1", in: index)))
        queue.stage(.remove(name: "oldapp", purge: true))

        let plan = try makeResolver().resolve(queue)
        XCTAssertEqual(plan.installed.map(\.name), ["newapp", "plugin"])
        XCTAssertEqual(plan.upgraded.map(\.name), ["foo-app"])
        XCTAssertEqual(plan.removed.map { $0.package.name }, ["oldapp"])
        XCTAssertEqual(described(plan.steps).filter { $0.hasPrefix("remove") }, ["remove oldapp (purge)"])
        XCTAssertEqual(plan.summary, "Install 2, Upgrade 1, Remove 1")
    }
}
