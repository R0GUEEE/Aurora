import XCTest
@testable import AuroraCore

/// ``DebianVersion`` has to agree with `dpkg --compare-versions` on everything a
/// repository can serve, so the bulk of this file replays the dpkg-derived vector
/// fixture. The rest checks the grammar bits dpkg does not answer for us.
final class DebianVersionTests: XCTestCase {

    // MARK: - dpkg ground truth

    /// Every line of `version-vectors.tsv` (fuzzed against dpkg 1.22.11) must come
    /// out the same way from ``DebianVersion/compare(_:_:)``.
    func testEveryVersionVectorAgreesWithDpkg() throws {
        let text = try Fixture.text(Fixture.versionVectors)
        var checked = 0
        var failures: [String] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.isEmpty || line.hasPrefix("#") { continue }

            let columns = line.components(separatedBy: "\t")
            guard columns.count == 3 else {
                failures.append("malformed vector line: \(line)")
                continue
            }
            let left = DebianVersion(columns[0])
            let right = DebianVersion(columns[2])
            let expected: Int
            switch columns[1] {
            case "<": expected = -1
            case ">": expected = 1
            case "==": expected = 0
            default:
                failures.append("unknown relation '\(columns[1])' in: \(line)")
                continue
            }

            checked += 1
            let order = DebianVersion.compare(left, right)
            if order != expected {
                failures.append("dpkg: \(columns[0]) \(columns[1]) \(columns[2]); "
                                + "AuroraCore: compare == \(order)")
            }
            // `<` must also be what `Comparable` uses.
            if (order < 0) != (left < right) {
                failures.append("Comparable disagrees with compare for \(columns[0]) / \(columns[2])")
            }
        }

        XCTAssertGreaterThan(checked, 1300,
                             "the vector fixture should contain 1300+ pairs, only \(checked) were read")
        XCTAssertTrue(failures.isEmpty,
                      "\(failures.count) of \(checked) vectors disagree with dpkg:\n"
                      + failures.prefix(20).joined(separator: "\n"))
    }

    // MARK: - Parsing

    func testParsesEpochUpstreamAndRevision() {
        let version = DebianVersion("1:2.3-4")
        XCTAssertEqual(version.epoch, 1)
        XCTAssertEqual(version.upstream, "2.3")
        XCTAssertEqual(version.revision, "4")
        XCTAssertTrue(version.hasEpoch)
        XCTAssertTrue(version.hasRevision)
        XCTAssertEqual(version.raw, "1:2.3-4")
        XCTAssertEqual(version.description, "1:2.3-4")

        let noEpoch = DebianVersion("2.3-4")
        XCTAssertEqual(noEpoch.epoch, 0)
        XCTAssertFalse(noEpoch.hasEpoch)
        XCTAssertEqual(noEpoch.upstream, "2.3")
        XCTAssertEqual(noEpoch.revision, "4")
        XCTAssertTrue(noEpoch.hasRevision)

        let noRevision = DebianVersion("2.3")
        XCTAssertFalse(noRevision.hasEpoch)
        XCTAssertFalse(noRevision.hasRevision)
        XCTAssertEqual(noRevision.upstream, "2.3")
        XCTAssertEqual(noRevision.revision, "")

        let bareEpoch = DebianVersion("1:2.3")
        XCTAssertTrue(bareEpoch.hasEpoch)
        XCTAssertFalse(bareEpoch.hasRevision)
        XCTAssertEqual(bareEpoch.upstream, "2.3")
    }

    func testRevisionIsEverythingAfterTheLastDash() {
        let version = DebianVersion("1.0-1-2")
        XCTAssertEqual(version.upstream, "1.0-1")
        XCTAssertEqual(version.revision, "2")
        XCTAssertTrue(version.hasRevision)

        let bpo = DebianVersion("1.0-1~bpo1")
        XCTAssertEqual(bpo.upstream, "1.0")
        XCTAssertEqual(bpo.revision, "1~bpo1")
    }

    func testAColonThatIsNotAnEpochStaysInTheUpstreamVersion() {
        let leading = DebianVersion(":1.0")
        XCTAssertFalse(leading.hasEpoch)
        XCTAssertEqual(leading.epoch, 0)
        XCTAssertEqual(leading.upstream, ":1.0")

        let named = DebianVersion("abc:1.0")
        XCTAssertFalse(named.hasEpoch)
        XCTAssertEqual(named.epoch, 0)
        XCTAssertEqual(named.upstream, "abc:1.0")
        XCTAssertEqual(named.revision, "")

        let dashed = DebianVersion("1.0-1:2")
        XCTAssertFalse(dashed.hasEpoch)
        XCTAssertEqual(dashed.upstream, "1.0")
        XCTAssertEqual(dashed.revision, "1:2")
    }

    // MARK: - isWellFormed

    func testIsWellFormedAcceptsPolicyConformantVersions() {
        XCTAssertTrue(DebianVersion("0").isWellFormed)
        XCTAssertTrue(DebianVersion("1.0").isWellFormed)
        XCTAssertTrue(DebianVersion("1.0-1").isWellFormed)
        XCTAssertTrue(DebianVersion("1:1.0-1").isWellFormed)
        XCTAssertTrue(DebianVersion("1.0~rc1-1~bpo1").isWellFormed)
        XCTAssertTrue(DebianVersion("1.0+dfsg1-1").isWellFormed)
        XCTAssertTrue(DebianVersion("1.0-1-2").isWellFormed)
        XCTAssertTrue(DebianVersion("1.0-rc1").isWellFormed)
    }

    func testIsWellFormedRejectsMalformedVersions() {
        XCTAssertFalse(DebianVersion("").isWellFormed, "an empty upstream version")
        XCTAssertFalse(DebianVersion("abc").isWellFormed, "must start with a digit")
        XCTAssertFalse(DebianVersion("v1.0").isWellFormed)
        XCTAssertFalse(DebianVersion("~1.0").isWellFormed)
        XCTAssertFalse(DebianVersion("1.0_1").isWellFormed, "underscore is not allowed upstream")
        XCTAssertFalse(DebianVersion("1.0-1_2").isWellFormed, "underscore is not allowed in the revision")
        XCTAssertFalse(DebianVersion("1.0:2").isWellFormed, "only the epoch may carry a colon")
    }

    // MARK: - Ordering and hashing

    func testOrderingFollowsDpkgRules() {
        XCTAssertTrue(DebianVersion("1.0~rc1") < DebianVersion("1.0"), "~ sorts before everything")
        XCTAssertTrue(DebianVersion("1.0~~") < DebianVersion("1.0~"))
        XCTAssertTrue(DebianVersion("1.0") < DebianVersion("1.0-1"), "a revision sorts above none")
        XCTAssertTrue(DebianVersion("1.0-1") < DebianVersion("2.0"))
        XCTAssertTrue(DebianVersion("1.0a") > DebianVersion("1.0"), "letters sort above end-of-string")
        XCTAssertTrue(DebianVersion("2.0") < DebianVersion("1:1.0"), "the epoch wins over everything")
        XCTAssertTrue(DebianVersion("1:0.9") < DebianVersion("2:0.1"))
        XCTAssertEqual(DebianVersion.compare(DebianVersion("1.0"), DebianVersion("1:1.0")), 0)

        let shuffled = [DebianVersion("2.0"), DebianVersion("1:0.9"),
                        DebianVersion("1.0~rc1"), DebianVersion("1.0")]
        XCTAssertEqual(shuffled.sorted().map(\.raw), ["1.0~rc1", "1.0", "2.0", "1:0.9"])
    }

    func testEqualityAndHashingAreOverTheRawVersion() {
        XCTAssertEqual(DebianVersion("1.0"), DebianVersion("1.0"))
        XCTAssertEqual(DebianVersion("1.0").hashValue, DebianVersion("1.0").hashValue)
        XCTAssertNotEqual(DebianVersion("1.0"), DebianVersion("1.0-1"))
        XCTAssertNotEqual(DebianVersion("1.0"), DebianVersion("1:1.0"),
                          "equal under dpkg's ordering but not the same string")
        XCTAssertEqual(Set([DebianVersion("1.0"), DebianVersion("1.0"), DebianVersion("1:1.0")]).count, 2)
    }

    // MARK: - Constraints

    func testConstraintsForEveryRelation() {
        let one = DebianVersion("1.0")

        let equal = DebianVersionConstraint(relation: .equal, version: one)
        XCTAssertTrue(equal.isSatisfied(by: DebianVersion("1.0")))
        XCTAssertTrue(equal.isSatisfied(by: DebianVersion("1:1.0")))
        XCTAssertFalse(equal.isSatisfied(by: DebianVersion("1.0-1")))
        XCTAssertFalse(equal.isSatisfied(by: DebianVersion("0.9")))

        let strictlyEarlier = DebianVersionConstraint(relation: .strictlyEarlier, version: one)
        XCTAssertTrue(strictlyEarlier.isSatisfied(by: DebianVersion("1.0~rc1")))
        XCTAssertTrue(strictlyEarlier.isSatisfied(by: DebianVersion("0.9")))
        XCTAssertFalse(strictlyEarlier.isSatisfied(by: DebianVersion("1.0")))

        let earlierOrEqual = DebianVersionConstraint(relation: .earlierOrEqual, version: one)
        XCTAssertTrue(earlierOrEqual.isSatisfied(by: DebianVersion("1.0")))
        XCTAssertTrue(earlierOrEqual.isSatisfied(by: DebianVersion("1.0~rc1")))
        XCTAssertFalse(earlierOrEqual.isSatisfied(by: DebianVersion("1.0-1")))

        let laterOrEqual = DebianVersionConstraint(relation: .laterOrEqual, version: one)
        XCTAssertTrue(laterOrEqual.isSatisfied(by: DebianVersion("1.0")))
        XCTAssertTrue(laterOrEqual.isSatisfied(by: DebianVersion("2.0")))
        XCTAssertFalse(laterOrEqual.isSatisfied(by: DebianVersion("1.0~rc1")),
                       "1.0~rc1 is earlier than 1.0, so it cannot satisfy >= 1.0")

        let strictlyLater = DebianVersionConstraint(relation: .strictlyLater, version: one)
        XCTAssertTrue(strictlyLater.isSatisfied(by: DebianVersion("1.0-1")))
        XCTAssertFalse(strictlyLater.isSatisfied(by: DebianVersion("1.0")))
    }

    func testConstraintDescriptionAndRelationRawValues() {
        let constraint = DebianVersionConstraint(relation: .laterOrEqual, version: DebianVersion("1.2-3"))
        XCTAssertEqual(constraint.description, "(>= 1.2-3)")
        XCTAssertEqual(DebianVersionConstraint.Relation.allCases.count, 5)
        XCTAssertEqual(DebianVersionConstraint.Relation.equal.rawValue, "=")
        XCTAssertEqual(DebianVersionConstraint.Relation.strictlyEarlier.rawValue, "<<")
        XCTAssertEqual(DebianVersionConstraint.Relation.earlierOrEqual.rawValue, "<=")
        XCTAssertEqual(DebianVersionConstraint.Relation.laterOrEqual.rawValue, ">=")
        XCTAssertEqual(DebianVersionConstraint.Relation.strictlyLater.rawValue, ">>")
        XCTAssertEqual(Set(DebianVersionConstraint.Relation.allCases).count, 5)
    }
}
