import XCTest
@testable import AuroraCore

/// Dependency fields are the one place where a parser bug silently installs the
/// wrong thing, so every form the resolver or `Provides` handling can meet is
/// checked here.
final class DependenciesTests: XCTestCase {

    private func stanza(_ fields: [String: String]) -> ControlStanza {
        ControlStanza(fields: fields.map { ControlField(name: $0.key, value: $0.value) })
    }

    // MARK: - DependencyList.parse

    func testParsesAlternatives() throws {
        let list = DependencyList.parse("a | b (>= 1.0)")
        XCTAssertEqual(list.clauses.count, 1)
        let clause = try XCTUnwrap(list.clauses.first)
        XCTAssertEqual(clause.alternatives.map(\.name), ["a", "b"])
        XCTAssertNil(clause.alternatives[0].constraint)
        XCTAssertEqual(clause.alternatives[1].constraint?.relation, .laterOrEqual)
        XCTAssertEqual(clause.alternatives[1].constraint?.version.raw, "1.0")
        XCTAssertEqual(clause.description, "a | b (>= 1.0)")
        XCTAssertEqual(list.description, "a | b (>= 1.0)")
        XCTAssertEqual(list.allTerms.map(\.name), ["a", "b"])
        XCTAssertFalse(list.isEmpty)
    }

    func testParsesAnAndOfClauses() {
        let list = DependencyList.parse("libfoo1 (>= 1.4), bash")
        XCTAssertEqual(list.clauses.count, 2)
        XCTAssertEqual(list.clauses[0].alternatives.map(\.name), ["libfoo1"])
        XCTAssertEqual(list.clauses[0].alternatives[0].constraint?.relation, .laterOrEqual)
        XCTAssertEqual(list.clauses[0].alternatives[0].constraint?.version.raw, "1.4")
        XCTAssertEqual(list.clauses[1].alternatives.map(\.name), ["bash"])
        XCTAssertNil(list.clauses[1].alternatives[0].constraint)
        XCTAssertEqual(list.description, "libfoo1 (>= 1.4), bash")
        XCTAssertEqual(list.allTerms.count, 2)
    }

    func testParsesEveryOperatorForm() throws {
        let cases: [(String, DebianVersionConstraint.Relation, String)] = [
            ("x (>= 2.0)", .laterOrEqual, "2.0"),
            ("x (<= 2.0)", .earlierOrEqual, "2.0"),
            ("x (<< 2.0)", .strictlyEarlier, "2.0"),
            ("x (>> 2.0)", .strictlyLater, "2.0"),
            ("x (= 2.0)", .equal, "2.0"),
            // Debian policy: < and > are deprecated synonyms of <= and >=, not
            // strict comparisons. Only << and >> are strict.
            ("x (< 2.0)", .earlierOrEqual, "2.0"),
            ("x (> 2.0)", .laterOrEqual, "2.0"),
            ("x (<= 2.0)", .earlierOrEqual, "2.0"),
            ("x (>= 2.0)", .laterOrEqual, "2.0"),
        ]
        for (text, relation, version) in cases {
            let list = DependencyList.parse(text)
            let term = try XCTUnwrap(list.clauses.first?.alternatives.first, "parsing \(text)")
            XCTAssertEqual(term.name, "x", "parsing \(text)")
            XCTAssertEqual(term.constraint?.relation, relation, "parsing \(text)")
            XCTAssertEqual(term.constraint?.version.raw, version, "parsing \(text)")
        }
    }

    func testParsesTheArchitectureAnyQualifier() throws {
        let list = DependencyList.parse("libfoo:any (>= 1.2) | libbar")
        let first = try XCTUnwrap(list.clauses.first?.alternatives.first)
        XCTAssertEqual(first.name, "libfoo")
        XCTAssertEqual(first.architectureQualifier, "any")
        XCTAssertTrue(first.isArchitectureAny)
        XCTAssertEqual(first.constraint?.version.raw, "1.2")
        XCTAssertEqual(first.description, "libfoo:any (>= 1.2)")

        let second = try XCTUnwrap(list.clauses.first?.alternatives.last)
        XCTAssertEqual(second.name, "libbar")
        XCTAssertNil(second.architectureQualifier)
        XCTAssertFalse(second.isArchitectureAny)

        let native = try XCTUnwrap(DependencyList.parse("libc:native").clauses.first?.alternatives.first)
        XCTAssertEqual(native.architectureQualifier, "native")
        XCTAssertFalse(native.isArchitectureAny)
    }

    /// Architecture restrictions and build profiles are a build-time concept; a
    /// binary client has to tolerate them and ignore them.
    func testStripsArchitectureRestrictionsAndBuildProfiles() {
        let restriction = DependencyList.parse("foo [amd64] (>= 1)")
        XCTAssertEqual(restriction.clauses.count, 1)
        XCTAssertEqual(restriction.clauses[0].alternatives.map(\.name), ["foo"])
        XCTAssertEqual(restriction.clauses[0].alternatives[0].constraint?.version.raw, "1")

        let profile = DependencyList.parse("bar <!nocheck>")
        XCTAssertEqual(profile.clauses[0].alternatives.map(\.name), ["bar"])
        XCTAssertNil(profile.clauses[0].alternatives[0].constraint)

        let both = DependencyList.parse("baz [amd64 !arm64] <!nocheck !cross> (>= 2)")
        XCTAssertEqual(both.clauses.count, 1)
        XCTAssertEqual(both.clauses[0].alternatives.map(\.name), ["baz"])
        XCTAssertEqual(both.clauses[0].alternatives[0].constraint?.version.raw, "2")

        // A term that is *nothing but* a restriction has no name and is dropped.
        XCTAssertTrue(DependencyList.parse("[]").isEmpty)
    }

    func testEmptyAndMalformedInput() {
        XCTAssertTrue(DependencyList.parse("").isEmpty)
        XCTAssertTrue(DependencyList.parse("   ").isEmpty)
        XCTAssertTrue(DependencyList.parse(",").isEmpty)
        XCTAssertTrue(DependencyList.parse("|").isEmpty)
        XCTAssertEqual(DependencyList.parse("a,,b").clauses.count, 2)
        XCTAssertEqual(DependencyList.parse("a,").clauses.count, 1)

        // "(bogus)" has no operator, so the version relation is not understood and
        // the constraint is dropped rather than mis-parsed.
        let bogus = DependencyList.parse("a (bogus)")
        XCTAssertEqual(bogus.clauses[0].alternatives.map(\.name), ["a"])
        XCTAssertNil(bogus.clauses[0].alternatives[0].constraint)
    }

    // MARK: - PackageRelations

    func testRelationsComeFromTheRelationalFields() {
        let relations = PackageRelations(stanza: stanza([
            "Package": "example",
            "Pre-Depends": "dpkg (>= 1.0)",
            "Depends": "libfoo1 (>= 1.4), bash",
            "Recommends": "coreutils",
            "Suggests": "foo-extras",
            "Conflicts": "oldapp",
            "Breaks": "brokenapp (<< 2.0)",
            "Replaces": "oldapp",
        ]))
        XCTAssertEqual(relations.preDepends.clauses.count, 1)
        XCTAssertEqual(relations.preDepends.clauses[0].alternatives[0].name, "dpkg")
        XCTAssertEqual(relations.depends.clauses.count, 2)
        XCTAssertEqual(relations.recommends.clauses.map { $0.alternatives[0].name }, ["coreutils"])
        XCTAssertEqual(relations.suggests.clauses.map { $0.alternatives[0].name }, ["foo-extras"])
        XCTAssertEqual(relations.conflicts.clauses.map { $0.alternatives[0].name }, ["oldapp"])
        XCTAssertEqual(relations.breaks.clauses.map { $0.alternatives[0].name }, ["brokenapp"])
        XCTAssertEqual(relations.replaces.clauses.map { $0.alternatives[0].name }, ["oldapp"])
        XCTAssertTrue(relations.provides.isEmpty, "no Provides field, no provided names")
    }

    func testAbsentRelationFieldsAreEmpty() {
        let relations = PackageRelations(stanza: ["Package": "bare", "Version": "1.0"])
        XCTAssertTrue(relations.depends.isEmpty)
        XCTAssertTrue(relations.preDepends.isEmpty)
        XCTAssertTrue(relations.recommends.isEmpty)
        XCTAssertTrue(relations.suggests.isEmpty)
        XCTAssertTrue(relations.conflicts.isEmpty)
        XCTAssertTrue(relations.breaks.isEmpty)
        XCTAssertTrue(relations.replaces.isEmpty)
        XCTAssertTrue(relations.provides.isEmpty)
    }

    func testProvidesWithAndWithoutAVersion() {
        let versioned = PackageRelations(stanza: ["Package": "mailserver",
                                                  "Provides": "mail-transport-agent (= 7.2)"])
        XCTAssertEqual(versioned.provides.count, 1)
        XCTAssertEqual(versioned.provides[0].name, "mail-transport-agent")
        XCTAssertEqual(versioned.provides[0].version?.raw, "7.2")
        XCTAssertEqual(versioned.provides[0].description, "mail-transport-agent (= 7.2)")

        let unversioned = PackageRelations(stanza: ["Package": "tiny",
                                                    "Provides": "virtual-thing"])
        XCTAssertEqual(unversioned.provides.map(\.name), ["virtual-thing"])
        XCTAssertNil(unversioned.provides[0].version, "an unversioned Provides carries no version")
        XCTAssertEqual(unversioned.provides[0].description, "virtual-thing")

        let several = PackageRelations(stanza: ["Package": "many",
                                                "Provides": "one, two (= 2.0) , three"])
        XCTAssertEqual(several.provides.map(\.name), ["one", "two", "three"])
        XCTAssertNil(several.provides[0].version)
        XCTAssertEqual(several.provides[1].version?.raw, "2.0")
        XCTAssertNil(several.provides[2].version)

        // `Provides` may only carry `=`; a range is not a valid Provides and the
        // version is simply taken from it (the resolver only ever uses it for `=`).
        let ranged = PackageRelations(stanza: ["Package": "odd", "Provides": "thing (>= 1.0)"])
        XCTAssertEqual(ranged.provides.map(\.name), ["thing"])
        XCTAssertEqual(ranged.provides[0].version?.raw, "1.0")
    }

    func testProvidesCoversTheFixtureVirtualPackage() throws {
        let stanzas = ControlParser.parse(try Fixture.text(Fixture.packagesIndex))
        let mailserver = try XCTUnwrap(stanzas.first { $0["Package"] == "mailserver" })
        let relations = PackageRelations(stanza: mailserver)
        XCTAssertEqual(relations.provides.map(\.name), ["mail-transport-agent"])
        XCTAssertEqual(relations.provides[0].version?.raw, "7.2")

        let newappStanza = try XCTUnwrap(stanzas.first { $0["Package"] == "newapp" })
        // `relations` belongs to a record, not to the raw stanza.
        let newapp = PackageRecord(stanza: newappStanza)
        XCTAssertEqual(newapp.relations.depends.clauses.count, 1)
        XCTAssertEqual(newapp.relations.depends.clauses[0].alternatives.map(\.name), ["libfoo1", "libbar1"])
        XCTAssertNil(newapp.relations.depends.clauses[0].alternatives[1].constraint)
        XCTAssertEqual(newapp.relations.conflicts.clauses.map { $0.alternatives[0].name }, ["oldapp"])
        XCTAssertEqual(newapp.relations.replaces.clauses.map { $0.alternatives[0].name }, ["oldapp"])
    }

    func testDependencyTermEqualityIsStructural() {
        let constraint = DebianVersionConstraint(relation: .laterOrEqual, version: DebianVersion("1.0"))
        XCTAssertEqual(DependencyTerm(name: "a", constraint: constraint),
                       DependencyTerm(name: "a", constraint: constraint))
        XCTAssertNotEqual(DependencyTerm(name: "a", constraint: constraint),
                          DependencyTerm(name: "a"))
        XCTAssertNotEqual(DependencyTerm(name: "a", architectureQualifier: "any"),
                          DependencyTerm(name: "a"))
        XCTAssertEqual(Set([DependencyTerm(name: "a"), DependencyTerm(name: "a")]).count, 1)
    }
}
