import XCTest
@testable import AuroraCore

/// ``PackageIndex`` is what the resolver asks hundreds of times per transaction:
/// candidate lookup, `Provides` resolution, architecture filtering and browsing.
final class PackageIndexTests: XCTestCase {

    private func fixtureIndex() throws -> PackageIndex {
        PackageIndex(records: ControlParser.parse(try Fixture.text(Fixture.packagesIndex))
            .map { PackageRecord(stanza: $0) })
    }

    private func record(_ name: String, _ version: String, architecture: String = "iphoneos-arm64",
                        extra: [ControlField] = []) -> PackageRecord {
        var fields = [
            ControlField(name: "Package", value: name),
            ControlField(name: "Version", value: version),
            ControlField(name: "Architecture", value: architecture),
        ]
        fields.append(contentsOf: extra)
        return PackageRecord(stanza: ControlStanza(fields: fields))
    }

    // MARK: - Candidates

    func testCandidatesAreNewestFirst() throws {
        let index = try fixtureIndex()
        XCTAssertEqual(index.count, 16)
        XCTAssertFalse(index.isEmpty)
        XCTAssertEqual(index.candidates(named: "foo-app").map(\.version.raw), ["2.0.0-1", "1.9.0-1"])
        XCTAssertEqual(index.candidates(named: "plugin").map(\.version.raw), ["3.1-1", "3.0-1"])
        XCTAssertEqual(index.allVersions(of: "foo-app").map(\.raw), ["2.0.0-1", "1.9.0-1"])
        XCTAssertTrue(index.candidates(named: "nothing").isEmpty)
        XCTAssertTrue(index.allVersions(of: "nothing").isEmpty)
    }

    func testBestMatchPicksTheNewestVersion() throws {
        let index = try fixtureIndex()
        let newest = try XCTUnwrap(index.bestMatch(for: DependencyTerm(name: "foo-app"),
                                                   architecture: "iphoneos-arm64"))
        XCTAssertEqual(newest.version.raw, "2.0.0-1")
        XCTAssertEqual(newest.name, "foo-app")
        XCTAssertNil(index.bestMatch(for: DependencyTerm(name: "does-not-exist"),
                                     architecture: "iphoneos-arm64"))
    }

    func testBestMatchAppliesTheConstraint() throws {
        let index = try fixtureIndex()
        let atLeast19 = DependencyTerm(name: "foo-app",
                                       constraint: DebianVersionConstraint(relation: .laterOrEqual,
                                                                           version: DebianVersion("1.9")))
        XCTAssertEqual(index.bestMatch(for: atLeast19, architecture: "iphoneos-arm64")?.version.raw, "2.0.0-1")

        let olderThan20 = DependencyTerm(name: "foo-app",
                                         constraint: DebianVersionConstraint(relation: .strictlyEarlier,
                                                                             version: DebianVersion("2.0")))
        XCTAssertEqual(index.bestMatch(for: olderThan20, architecture: "iphoneos-arm64")?.version.raw, "1.9.0-1")

        let exactly = DependencyTerm(name: "foo-app",
                                     constraint: DebianVersionConstraint(relation: .equal,
                                                                         version: DebianVersion("1.9.0-1")))
        XCTAssertEqual(index.bestMatch(for: exactly, architecture: "iphoneos-arm64")?.version.raw, "1.9.0-1")

        let impossible = DependencyTerm(name: "foo-app",
                                        constraint: DebianVersionConstraint(relation: .strictlyLater,
                                                                            version: DebianVersion("2.0.0-1")))
        XCTAssertNil(index.bestMatch(for: impossible, architecture: "iphoneos-arm64"),
                     "nothing in the index satisfies >> 2.0.0-1")

        let exactMatch = DependencyTerm(name: "foo-app",
                                        constraint: DebianVersionConstraint(relation: .equal,
                                                                            version: DebianVersion("3.0")))
        XCTAssertNil(index.bestMatch(for: exactMatch, architecture: "iphoneos-arm64"))
    }

    // MARK: - Provides

    func testProvidersOfAVirtualName() throws {
        let index = try fixtureIndex()
        XCTAssertEqual(index.providers(of: "mail-transport-agent").map(\.name), ["mailserver"])
        XCTAssertEqual(index.providers(of: "mailserver").map(\.name), [],
                       "a real package is a candidate, not a provider")
        XCTAssertTrue(index.providers(of: "nothing-at-all").isEmpty)
    }

    func testVersionedProvidesSatisfiesVersionedDependencies() throws {
        let index = try fixtureIndex()
        XCTAssertEqual(index.bestMatch(for: DependencyTerm(name: "mail-transport-agent"),
                                       architecture: "iphoneos-arm64")?.name,
                       "mailserver")

        let satisfied = DependencyTerm(name: "mail-transport-agent",
                                       constraint: DebianVersionConstraint(relation: .laterOrEqual,
                                                                           version: DebianVersion("7.0")))
        XCTAssertEqual(index.bestMatch(for: satisfied, architecture: "iphoneos-arm64")?.name, "mailserver")

        let tooNew = DependencyTerm(name: "mail-transport-agent",
                                    constraint: DebianVersionConstraint(relation: .laterOrEqual,
                                                                        version: DebianVersion("9.0")))
        XCTAssertNil(index.bestMatch(for: tooNew, architecture: "iphoneos-arm64"),
                     "mailserver provides 7.2, which is not >= 9.0")

        let exactVirtual = DependencyTerm(name: "mail-transport-agent",
                                          constraint: DebianVersionConstraint(relation: .equal,
                                                                              version: DebianVersion("7.2")))
        XCTAssertEqual(index.bestMatch(for: exactVirtual, architecture: "iphoneos-arm64")?.name, "mailserver")
    }

    func testUnversionedProvidesSatisfiesOnlyUnversionedDependencies() throws {
        // The fixture only ships the versioned form, so the unversioned case is
        // built here: it is the one that silently installs broken packages if the
        // resolver gets it wrong.
        var index = PackageIndex()
        index.append(record("unversioned-provider", "1.0-1",
                            extra: [ControlField(name: "Provides", value: "virtual-thing")]))

        XCTAssertEqual(index.bestMatch(for: DependencyTerm(name: "virtual-thing"),
                                       architecture: "iphoneos-arm64")?.name,
                       "unversioned-provider")

        let versioned = DependencyTerm(name: "virtual-thing",
                                       constraint: DebianVersionConstraint(relation: .laterOrEqual,
                                                                           version: DebianVersion("1.0")))
        XCTAssertNil(index.bestMatch(for: versioned, architecture: "iphoneos-arm64"),
                     "an unversioned Provides must not satisfy a versioned dependency")

        let equalAnyVersion = DependencyTerm(name: "virtual-thing",
                                             constraint: DebianVersionConstraint(relation: .equal,
                                                                                 version: DebianVersion("1.0")))
        XCTAssertNil(index.bestMatch(for: equalAnyVersion, architecture: "iphoneos-arm64"))

        // A real package of that name still wins over a provider.
        index.append(record("virtual-thing", "0.1-1"))
        XCTAssertEqual(index.bestMatch(for: DependencyTerm(name: "virtual-thing"),
                                       architecture: "iphoneos-arm64")?.version.raw,
                       "0.1-1")
    }

    // MARK: - Architecture

    func testArchitectureFiltering() throws {
        let index = try fixtureIndex()
        XCTAssertEqual(index.bestMatch(for: DependencyTerm(name: "arch-all-tool"),
                                       architecture: "iphoneos-arm64")?.name,
                       "arch-all-tool", "`all` matches any request")

        XCTAssertNil(index.bestMatch(for: DependencyTerm(name: "legacy-tweak"),
                                     architecture: "iphoneos-arm64"),
                     "iphoneos-arm is a different architecture")
        XCTAssertEqual(index.bestMatch(for: DependencyTerm(name: "legacy-tweak"),
                                       architecture: "iphoneos-arm64",
                                       allowedArchitectures: ["iphoneos-arm"])?.name,
                       "legacy-tweak", "unless the caller allows the foreign architecture")
        XCTAssertEqual(index.bestMatch(for: DependencyTerm(name: "legacy-tweak"),
                                       architecture: "iphoneos-arm")?.name,
                       "legacy-tweak")
        XCTAssertNil(index.bestMatch(for: DependencyTerm(name: "legacy-tweak"),
                                     architecture: "iphoneos-arm64",
                                     allowedArchitectures: ["amd64"]),
                     "a foreign architecture that the record does not have either")
    }

    // MARK: - Browsing

    func testSearchIsCaseInsensitiveAndCollapsesVersions() throws {
        let index = try fixtureIndex()
        XCTAssertEqual(index.search("mailcl").map(\.name), ["mailclient"])
        XCTAssertEqual(index.search("MAILCL").map(\.name), ["mailclient"])
        XCTAssertEqual(index.search("obsolete").map(\.name), ["oldapp"], "the synopsis is searched too")
        XCTAssertEqual(index.search("foo-app").map(\.name), ["foo-app", "plugin"],
                       "the exact name match comes first; plugin's synopsis mentions foo-app")
        XCTAssertEqual(index.search("foo-app").first?.version.raw, "2.0.0-1")
        XCTAssertEqual(index.search("foo-app").count, 2, "only the newest version of each name is listed")
        XCTAssertTrue(index.search("zzzz-nothing-matches-this").isEmpty)
    }

    func testSearchFiltersBySectionAndLimit() throws {
        let index = try fixtureIndex()
        XCTAssertEqual(index.search("", section: "utils").map(\.name),
                       ["coreutils", "foo-app", "arch-all-tool", "brokenapp", "cyc-a", "cyc-b",
                        "oldapp", "newapp"],
                       "newest first, then by name, one row per package name")
        XCTAssertEqual(index.search("", limit: 3).count, 3)
        XCTAssertEqual(index.search("", limit: 3).first?.name, "coreutils")
        XCTAssertEqual(index.search("", section: "tweaks").map(\.name), ["plugin", "legacy-tweak"])
        XCTAssertTrue(index.search("", section: "no-such-section").isEmpty)
    }

    func testSectionsCountsUniqueNamesAndSortsBySize() throws {
        let index = try fixtureIndex()
        let sections = index.sections()
        XCTAssertEqual(sections.map { $0.name }, ["utils", "tweaks", "mail", "shells", "libs"])
        XCTAssertEqual(sections.map { $0.count }, [8, 2, 2, 1, 1])
        XCTAssertEqual(sections.map { "\($0.name)=\($0.count)" }.joined(separator: ","),
                       "utils=8,tweaks=2,mail=2,shells=1,libs=1")

        var unnamed = PackageIndex()
        unnamed.append(record("no-section", "1.0-1"))
        XCTAssertEqual(unnamed.sections().map { $0.name }, ["Uncategorised"])
    }

    // MARK: - Mutation

    func testMergeAndRemoveAllFromARepository() throws {
        let origin = RepositoryID(url: "https://repo.example.com", suite: "stable", component: "main")
        let records = ControlParser.parse(try Fixture.text(Fixture.packagesIndex))
            .map { PackageRecord(stanza: $0, origin: origin) }
        let index = PackageIndex(records: records)
        XCTAssertEqual(index.count, 16)

        var merged = PackageIndex()
        merged.merge(index)
        XCTAssertEqual(merged.count, 16)
        XCTAssertEqual(merged.candidates(named: "bash").first?.origin?.url, "https://repo.example.com")

        merged.removeAll(from: origin)
        XCTAssertTrue(merged.isEmpty)
        XCTAssertEqual(merged.count, 0)

        var appended = PackageIndex()
        appended.append(record("only", "1.0-1"))
        XCTAssertEqual(appended.count, 1)
        XCTAssertEqual(appended.candidates(named: "only").first?.architecture, "iphoneos-arm64")

        var other = RepositoryID(url: "https://other.example.com", suite: "./", component: "")
        XCTAssertEqual(other.description, "https://other.example.com ./")
        other = RepositoryID(url: "https://other.example.com", suite: "stable", component: "main")
        XCTAssertEqual(other.description, "https://other.example.com stable/main")
    }

    func testEqualVersionsFallBackToTheStoredOrder() {
        var index = PackageIndex()
        index.append(record("twin", "1.0-1", extra: [ControlField(name: "Filename", value: "first.deb")]))
        index.append(record("twin", "1.0-1", extra: [ControlField(name: "Filename", value: "second.deb")]))

        let candidates = index.candidates(named: "twin")
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates.map { $0.version.raw }, ["1.0-1", "1.0-1"])
        // Repository priority is expressed by the order the records were read in,
        // so the first one matching the term is the one that wins.
        XCTAssertEqual(index.bestMatch(for: DependencyTerm(name: "twin"), architecture: "iphoneos-arm64")?
            .stanza["Filename"],
                       "first.deb")
    }

    // MARK: - Record helpers

    func testRecordAccessorsUsedByThePlanScreen() throws {
        let index = try fixtureIndex()
        let bash = try XCTUnwrap(index.candidates(named: "bash").first)
        XCTAssertEqual(bash.displayName, "bash")
        XCTAssertEqual(bash.qualifiedName, "bash:iphoneos-arm64")
        XCTAssertEqual(bash.section, "shells")
        XCTAssertEqual(bash.priority, "optional")
        XCTAssertEqual(bash.installedSize, 1580)
        XCTAssertEqual(bash.downloadSize, 478096)
        XCTAssertTrue(bash.isEssential)
        XCTAssertTrue(bash.isProtected, "essential packages are protected")
        XCTAssertEqual(bash.filename, "pool/main/b/bash_5.2.15-2_iphoneos-arm64.deb")
        XCTAssertEqual(bash.id, "bash:iphoneos-arm64=5.2.15-2")
        XCTAssertEqual(bash.synopsis, "The GNU Bourne Again SHell")
        XCTAssertEqual(bash.extendedDescription, " A shell that everything else assumes is present.")
        XCTAssertEqual(bash.bestDigest?.algorithm, .sha256)
        XCTAssertEqual(bash.bestDigest?.hex,
                       "98222bfb812a40cef6a71fd248574795ef439f9546a6426ebf34f2a585fa6c58")
        XCTAssertEqual(bash.description, "bash 5.2.15-2 [iphoneos-arm64]")

        let architectureAll = try XCTUnwrap(index.candidates(named: "arch-all-tool").first)
        XCTAssertEqual(architectureAll.qualifiedName, "arch-all-tool",
                       "`all` is not spelled out in a qualified name")
        XCTAssertFalse(architectureAll.isProtected)

        let required = record("required-tool", "1.0-1",
                              extra: [ControlField(name: "Priority", value: "required")])
        XCTAssertTrue(required.isRequiredPriority)
        XCTAssertTrue(required.isProtected)

        let multi = record("multi", "1.0-1", extra: [ControlField(name: "Multi-Arch", value: "same")])
        XCTAssertTrue(multi.isMultiArchSame)
        XCTAssertEqual(multi.tags, [])
    }
}
