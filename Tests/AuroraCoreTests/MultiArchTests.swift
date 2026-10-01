import XCTest
@testable import AuroraCore

/// Multi-Arch is the part of Debian packaging that is easiest to get subtly wrong,
/// so these tests pin the rules rather than the implementation:
///
/// * a dependency is satisfied by the architecture asked for, by `all`, or by a
///   `Multi-Arch: foreign` package of any architecture — and by nothing else;
/// * `:any` accepts any installable architecture;
/// * only a *versioned* `Provides` satisfies a versioned dependency;
/// * `Multi-Arch: same` instances move together, and are left alone when they
///   cannot.
final class MultiArchTests: XCTestCase {

    // MARK: - Fixtures

    private func index() throws -> PackageIndex {
        PackageIndex(records: ControlParser.parse(try Fixture.text(Fixture.packagesMultiArch))
            .map { PackageRecord(stanza: $0) })
    }

    private func database() throws -> InstalledPackageDatabase {
        InstalledPackageDatabase(parsing: try Fixture.text(Fixture.statusMultiArch))
    }

    private func policy(
        architecture: String = "iphoneos-arm64",
        allowed: Set<String> = ["iphoneos-arm64", "iphoneos-arm"],
        packagePolicy: PackagePolicy = .default,
        downgrades: Bool = false
    ) -> DependencyResolver.Policy {
        DependencyResolver.Policy(
            architecture: architecture,
            allowedArchitectures: allowed,
            packagePolicy: packagePolicy,
            allowDowngrades: downgrades
        )
    }

    private func resolver(_ policy: DependencyResolver.Policy? = nil) throws -> DependencyResolver {
        DependencyResolver(
            available: try index(),
            installed: try database(),
            policy: policy ?? self.policy()
        )
    }

    private func record(_ name: String, _ architecture: String, in index: PackageIndex) throws -> PackageRecord {
        try XCTUnwrap(
            index.candidates(named: name).first { $0.architecture == architecture },
            "\(name) for \(architecture) is not in the multi-arch fixture"
        )
    }

    private func staged(_ action: PackageAction) -> PackageQueue {
        var queue = PackageQueue()
        queue.stage(action)
        return queue
    }

    // MARK: - Record helpers

    func testRecordReportsItsMultiArchRole() throws {
        let index = try self.index()
        XCTAssertTrue(try record("libmulti2", "iphoneos-arm64", in: index).isMultiArchSame)
        XCTAssertFalse(try record("libmulti2", "iphoneos-arm64", in: index).isMultiArchForeign)
        XCTAssertTrue(try record("toolbox", "iphoneos-arm", in: index).isMultiArchForeign)
        XCTAssertTrue(try record("libother", "iphoneos-arm", in: index).isNeitherMultiArchFeature)
    }

    func testInstanceKeysDistinguishArchitectures() throws {
        let index = try self.index()
        XCTAssertEqual(try record("libmulti2", "iphoneos-arm64", in: index).instanceKey, "libmulti2:iphoneos-arm64")
        XCTAssertEqual(try record("libmulti2", "iphoneos-arm", in: index).instanceKey, "libmulti2:iphoneos-arm")
        // Architecture-independent packages have one instance per name.
        let all = PackageRecord(stanza: ControlStanza(fields: [
            ControlField(name: "Package", value: "anything"),
            ControlField(name: "Version", value: "1.0"),
            ControlField(name: "Architecture", value: "all"),
        ]))
        XCTAssertEqual(all.instanceKey, "anything")
    }

    // MARK: - Architecture rules

    func testForeignPackageSatisfiesADependencyOfAnotherArchitecture() throws {
        let index = try self.index()
        // needs-toolbox is arm64 and depends on toolbox, which is only built for
        // the older architecture but declares Multi-Arch: foreign.
        let plan = try resolver().resolve(staged(.install(try record("needs-toolbox", "iphoneos-arm64", in: index))))
        XCTAssertEqual(plan.installed.map(\.name), ["needs-toolbox"])
        XCTAssertTrue(plan.upgraded.isEmpty)
        XCTAssertTrue(plan.dependencies.isEmpty, "toolbox is already installed, so nothing needs pulling in")
    }

    func testNonForeignPackageOfAnotherArchitectureDoesNotSatisfy() throws {
        let index = try self.index()
        // plain-client is arm64 and depends on libother, which is arm-only and
        // *not* foreign: that is an unsatisfiable dependency, not a silent install.
        let result = resolver().attempt(staged(.install(try record("plain-client", "iphoneos-arm64", in: index))))
        switch result {
        case .success:
            XCTFail("an arm-only, non-foreign dependency must not satisfy an arm64 package")
        case .failure(let failure):
            XCTAssertTrue(
                failure.errors.contains { $0.description.contains("libother") },
                "the failure should name libother, got \(failure.errors)"
            )
        }
    }

    func testAnyQualifierAcceptsAnotherArchitecture() throws {
        let index = try self.index()
        // anyarch-client declares `libother:any`, which does accept the arm build.
        let plan = try resolver().resolve(staged(.install(try record("anyarch-client", "iphoneos-arm64", in: index))))
        XCTAssertEqual(plan.dependencies.map(\.name), ["libother"])
        XCTAssertEqual(plan.installed.map(\.name), ["anyarch-client"])
    }

    func testDependencyOfAnArmPackageResolvesAgainstArm() throws {
        let index = try self.index()
        // armclient is arm and depends on libmulti3, which exists for arm64 and
        // arm: the arm build must be chosen, not the device's own architecture.
        let plan = try resolver().resolve(staged(.install(try record("armclient", "iphoneos-arm", in: index))))
        XCTAssertEqual(plan.dependencies.map(\.architecture), ["iphoneos-arm"],
                       "a dependency of an arm package must not resolve to an arm64 build")
    }

    func testUninstallableArchitectureIsNotACandidate() throws {
        let index = try self.index()
        // A rootless arm64-only device has no arm index, so the arm build of
        // libother is not installable at all.
        let rootless = policy(allowed: ["iphoneos-arm64"])
        let result = resolver(rootless).attempt(staged(.install(try record("anyarch-client", "iphoneos-arm64", in: index))))
        switch result {
        case .success:
            XCTFail("an architecture the client cannot install must not be selected")
        case .failure(let failure):
            XCTAssertTrue(failure.errors.contains { $0.description.contains("libother") })
        }
    }

    // MARK: - Multi-Arch: same alignment

    func testSamePackageIsUpgradedInEveryInstalledArchitecture() throws {
        let index = try self.index()
        // libmulti2 is installed for arm64 and arm at 2.0-1, and 2.1-1 exists for
        // both. Asking for one instance must move both, or dpkg would refuse the
        // mismatched set partway through.
        let plan = try resolver().resolve(staged(.upgrade(try record("libmulti2", "iphoneos-arm64", in: index))))

        XCTAssertEqual(plan.upgraded.map(\.architecture).sorted(), ["iphoneos-arm", "iphoneos-arm64"])
        XCTAssertEqual(Set(plan.upgraded.map { $0.version.raw }), ["2.1-1"], "both instances must land on one version")
        XCTAssertEqual(
            plan.warnings.contains { warning in
                if case .multiArchAligned(let name, let version, let architectures) = warning {
                    return name == "libmulti2" && version == "2.1-1" && architectures == ["iphoneos-arm", "iphoneos-arm64"]
                }
                return false
            },
            true,
            "the alignment should be reported, got \(plan.warnings.map(\.message))"
        )
    }

    func testSamePackageThatCannotAlignIsLeftAlone() throws {
        let index = try self.index()
        // libmulti3 is installed for both architectures at 2.0-1 and 3.0-1 only
        // exists for arm64, so the set cannot move.
        let plan = try resolver().resolve(staged(.upgrade(try record("libmulti3", "iphoneos-arm64", in: index))))

        XCTAssertTrue(plan.upgraded.isEmpty, "nothing should move, got \(plan.upgraded.map(\.name))")
        XCTAssertEqual(
            plan.warnings.contains { warning in
                if case .multiArchCannotAlign(let name, _) = warning { return name == "libmulti3" }
                return false
            },
            true,
            "the reason should be reported, got \(plan.warnings.map(\.message))"
        )
    }

    func testUnpackOrderPutsTheDependencyBeforeItsDependent() throws {
        let index = try self.index()
        let plan = try resolver().resolve(staged(.install(try record("anyarch-client", "iphoneos-arm64", in: index))))
        let order = plan.unpackSteps.map(\.name)
        XCTAssertEqual(order.first, "libother", "the dependency must be unpacked first, got \(order)")
        XCTAssertEqual(order.last, "anyarch-client")
    }

    // MARK: - Queue keys

    func testQueueKeepsTwoArchitecturesOfOnePackage() throws {
        let index = try self.index()
        var queue = PackageQueue()
        queue.stage(.install(try record("libmulti2", "iphoneos-arm64", in: index)))
        queue.stage(.install(try record("libmulti2", "iphoneos-arm", in: index)))
        XCTAssertEqual(queue.count, 2, "co-installable architectures are separate queue entries")

        // Staging the same instance twice still replaces.
        queue.stage(.upgrade(try record("libmulti2", "iphoneos-arm", in: index)))
        XCTAssertEqual(queue.count, 2)
        XCTAssertEqual(queue.action(for: "libmulti2")?.kind, .upgrade)
    }

    func testQueueKeyForRemovalIsTheName() {
        XCTAssertEqual(PackageAction.remove(name: "foo", purge: false).key, "foo")
    }
}

private extension PackageRecord {
    /// Neither `same` nor `foreign`, which is the common case.
    var isNeitherMultiArchFeature: Bool { !isMultiArchSame && !isMultiArchForeign }
}
