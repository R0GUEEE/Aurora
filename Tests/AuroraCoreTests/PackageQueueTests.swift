import XCTest
@testable import AuroraCore

/// The staged queue: what the user has lined up, before the resolver has had a
/// chance to turn it into a plan.
final class PackageQueueTests: XCTestCase {

    private func record(_ name: String, _ version: String,
                        architecture: String = "iphoneos-arm64") -> PackageRecord {
        PackageRecord(stanza: ControlStanza(fields: [
            ControlField(name: "Package", value: name),
            ControlField(name: "Version", value: version),
            ControlField(name: "Architecture", value: architecture),
        ]))
    }

    private func installed(_ name: String, _ version: String,
                           architecture: String = "iphoneos-arm64") -> InstalledPackage {
        InstalledPackage(stanza: ControlStanza(fields: [
            ControlField(name: "Package", value: name),
            ControlField(name: "Status", value: "install ok installed"),
            ControlField(name: "Version", value: version),
            ControlField(name: "Architecture", value: architecture),
        ]))
    }

    // MARK: - Staging

    func testStagingTheSameNameTwiceReplacesTheFirstEntry() {
        var queue = PackageQueue()
        queue.stage(.install(record("foo", "1.0-1")))
        queue.stage(.install(record("bar", "1.0-1")))
        queue.stage(.upgrade(record("foo", "2.0-1")))

        XCTAssertEqual(queue.count, 2, "one entry per package name")
        XCTAssertEqual(queue.actions.map(\.name), ["bar", "foo"],
                       "the replacement moves the entry to the end")
        XCTAssertEqual(queue.action(for: "foo")?.kind, .upgrade)
        XCTAssertEqual(queue.action(for: "foo")?.record?.version.raw, "2.0-1")
        XCTAssertTrue(queue.isStaged("bar"))
        XCTAssertFalse(queue.isStaged("baz"))
        XCTAssertNil(queue.action(for: "baz"))
        XCTAssertFalse(queue.isEmpty)

        var purge = PackageQueue()
        purge.stage(.remove(name: "foo", purge: false))
        purge.stage(.remove(name: "foo", purge: true))
        XCTAssertEqual(purge.count, 1)
        XCTAssertEqual(purge.action(for: "foo")?.kind, .purge)
        XCTAssertNil(purge.action(for: "foo")?.record)

        var removalReplacesInstall = PackageQueue()
        removalReplacesInstall.stage(.install(record("foo", "1.0-1")))
        removalReplacesInstall.stage(.remove(name: "foo", purge: false))
        XCTAssertEqual(removalReplacesInstall.count, 1)
        XCTAssertEqual(removalReplacesInstall.action(for: "foo"), .remove(name: "foo", purge: false))
    }

    func testUnstage() {
        var queue = PackageQueue()
        queue.stage(.install(record("foo", "1.0-1")))
        queue.stage(.install(record("bar", "1.0-1")))
        queue.stage(.install(record("baz", "1.0-1")))

        queue.unstage(name: "bar")
        XCTAssertEqual(queue.actions.map(\.name), ["foo", "baz"])
        XCTAssertFalse(queue.isStaged("bar"))

        queue.unstage(name: "not-staged")
        XCTAssertEqual(queue.count, 2)

        queue.removeAll()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertEqual(queue.count, 0)
        XCTAssertTrue(queue.actions.isEmpty)
        XCTAssertTrue(queue.summary.isEmpty)
    }

    func testQueueInitialiserKeepsTheGivenOrder() {
        let queue = PackageQueue(actions: [.install(record("b", "1.0-1")),
                                           .install(record("a", "1.0-1"))])
        XCTAssertEqual(queue.actions.map(\.name), ["b", "a"])
        XCTAssertEqual(PackageQueue().count, 0)
    }

    // MARK: - Action properties

    func testActionNameAndRecord() {
        XCTAssertEqual(PackageAction.install(record("foo", "1.0-1")).name, "foo")
        XCTAssertEqual(PackageAction.reinstall(record("foo", "1.0-1")).name, "foo")
        XCTAssertEqual(PackageAction.upgrade(record("foo", "1.0-1")).name, "foo")
        XCTAssertEqual(PackageAction.downgrade(record("foo", "1.0-1")).name, "foo")
        XCTAssertEqual(PackageAction.remove(name: "foo", purge: false).name, "foo")
        XCTAssertEqual(PackageAction.remove(name: "foo", purge: true).name, "foo")

        XCTAssertNil(PackageAction.remove(name: "foo", purge: false).record)
        XCTAssertEqual(PackageAction.upgrade(record("foo", "1.0-1")).record?.name, "foo")

        XCTAssertEqual(PackageAction.install(record("foo", "1.0-1")).kind, .install)
        XCTAssertEqual(PackageAction.reinstall(record("foo", "1.0-1")).kind, .reinstall)
        XCTAssertEqual(PackageAction.upgrade(record("foo", "1.0-1")).kind, .upgrade)
        XCTAssertEqual(PackageAction.downgrade(record("foo", "1.0-1")).kind, .downgrade)
        XCTAssertEqual(PackageAction.remove(name: "foo", purge: false).kind, .remove)
        XCTAssertEqual(PackageAction.remove(name: "foo", purge: true).kind, .purge)
    }

    func testKindLabelsAndCases() {
        XCTAssertEqual(PackageAction.Kind.allCases.count, 6)
        XCTAssertEqual(PackageAction.Kind.install.label, "Install")
        XCTAssertEqual(PackageAction.Kind.reinstall.label, "Reinstall")
        XCTAssertEqual(PackageAction.Kind.upgrade.label, "Upgrade")
        XCTAssertEqual(PackageAction.Kind.downgrade.label, "Downgrade")
        XCTAssertEqual(PackageAction.Kind.remove.label, "Remove")
        XCTAssertEqual(PackageAction.Kind.purge.label, "Remove with configuration files")
        XCTAssertEqual(Set(PackageAction.Kind.allCases).count, 6)
    }

    // MARK: - Summary

    func testSummaryCounts() {
        var queue = PackageQueue()
        queue.stage(.install(record("a", "1.0-1")))
        queue.stage(.install(record("b", "1.0-1")))
        queue.stage(.upgrade(record("c", "1.0-1")))
        queue.stage(.downgrade(record("d", "1.0-1")))
        queue.stage(.reinstall(record("e", "1.0-1")))
        queue.stage(.remove(name: "f", purge: false))
        queue.stage(.remove(name: "g", purge: true))

        XCTAssertEqual(queue.count, 7)
        XCTAssertEqual(queue.summary.map { $0.kind },
                       [.install, .reinstall, .upgrade, .downgrade, .remove, .purge],
                       "the summary follows `Kind.allCases` order")
        XCTAssertEqual(queue.summary.map { $0.count }, [2, 1, 1, 1, 1, 1])
        XCTAssertEqual(queue.summary.reduce(0) { $0 + $1.count }, queue.count)
        XCTAssertTrue(PackageQueue().summary.isEmpty)
    }

    // MARK: - Inverted actions

    func testInvertingActions() {
        let one = installed("foo", "1.0-1")
        let recordValue = record("foo", "1.0-1")

        XCTAssertEqual(PackageAction.remove(name: "foo", purge: true).inverted(installed: one),
                       .reinstall(one.record))
        XCTAssertEqual(PackageAction.remove(name: "foo", purge: false).inverted(installed: one),
                       .reinstall(one.record))
        XCTAssertNil(PackageAction.remove(name: "foo", purge: false).inverted(installed: nil),
                     "removing something that is not installed cannot be inverted")

        XCTAssertEqual(PackageAction.install(recordValue).inverted(installed: one), .reinstall(one.record))
        XCTAssertEqual(PackageAction.reinstall(recordValue).inverted(installed: one), .reinstall(one.record))
        XCTAssertEqual(PackageAction.upgrade(recordValue).inverted(installed: one), .reinstall(one.record))

        // Undoing a change to a *different* version hands back the installed
        // record, labelled with the direction the queue must move to get there.
        //
        // So undoing a staged "install 2.0-1" (with 1.0-1 installed) is a
        // *downgrade* back to 1.0-1, and undoing a staged "install 0.9-1" is an
        // *upgrade* back to 1.0-1. The label used to be the other way round, which
        // made the queue's reset button emit an action the resolver refuses.
        XCTAssertEqual(PackageAction.install(record("foo", "2.0-1")).inverted(installed: one),
                       .downgrade(one.record))
        XCTAssertEqual(PackageAction.downgrade(record("foo", "2.0-1")).inverted(installed: one),
                       .downgrade(one.record))
        XCTAssertEqual(PackageAction.install(record("foo", "0.9-1")).inverted(installed: one),
                       .upgrade(one.record))

        XCTAssertNil(PackageAction.install(record("foo", "2.0-1")).inverted(installed: nil),
                     "a package that is not installed has nothing to go back to")
        XCTAssertNil(PackageAction.upgrade(record("bar", "2.0-1")).inverted(installed: nil))

        // The returned action refers to the *installed* record, not the staged one.
        let inverted = PackageAction.install(record("foo", "2.0-1")).inverted(installed: one)
        XCTAssertEqual(inverted?.record?.version.raw, "1.0-1")
        XCTAssertEqual(inverted?.name, "foo")
    }

    func testInvertedActionsAreHashable() {
        let one = installed("foo", "1.0-1")
        XCTAssertEqual(Set([PackageAction.reinstall(one.record),
                            PackageAction.reinstall(one.record)]).count, 1)
        XCTAssertNotEqual(PackageAction.remove(name: "foo", purge: false),
                          PackageAction.remove(name: "foo", purge: true))
    }
}
